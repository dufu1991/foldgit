import FoldGitCore
import Foundation

enum ChangeFileLayout: String, CaseIterable {
    case list, tree

    var title: String {
        switch self {
        case .list: String(localized: "List")
        case .tree: String(localized: "Directory Tree")
        }
    }
}

/// A presentation index only. File identities still refer to the original diff bindings.
struct ChangeFileTree: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let id: String
        let path: String
    }

    struct Row: Identifiable, Equatable, Sendable {
        enum ID: Hashable, Sendable {
            case directory(String)
            case file(String)
        }

        let id: ID
        let path: String
        let name: String
        let depth: Int

        var fileID: String? {
            if case .file(let id) = id { return id }
            return nil
        }

        var isDirectory: Bool { fileID == nil }
    }

    let rows: [Row]
    let directoryPaths: Set<String>

    init(entries: [Entry] = []) {
        var children: [String: [Row]] = [:]
        var directories: Set<String> = []
        for entry in entries {
            let parts = entry.path.split(separator: "/").map(String.init)
            var parent = ""
            for (depth, name) in parts.dropLast().enumerated() {
                let path = parent.isEmpty ? name : parent + "/" + name
                if directories.insert(path).inserted {
                    children[parent, default: []].append(Row(id: .directory(path), path: path, name: name, depth: depth))
                }
                parent = path
            }
            children[parent, default: []].append(Row(id: .file(entry.id), path: entry.path,
                                                      name: parts.last ?? entry.path, depth: max(0, parts.count - 1)))
        }

        var flattened: [Row] = []
        func appendChildren(of path: String) {
            let sorted = children[path, default: []].sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
            }
            for row in sorted {
                flattened.append(row)
                if row.isDirectory { appendChildren(of: row.path) }
            }
        }
        appendChildren(of: "")
        rows = flattened
        directoryPaths = directories
    }

    init(fileDiffs: [FileDiff]) {
        self.init(entries: fileDiffs.map { Entry(id: $0.id, path: $0.changeTreePath) })
    }

    init(untrackedFiles: [String]) {
        self.init(entries: untrackedFiles.map { Entry(id: $0, path: $0) })
    }

    func visibleRows(collapsedDirectories: Set<String>) -> [Row] {
        var hiddenDepth: Int?
        return rows.filter { row in
            if let depth = hiddenDepth, row.depth > depth { return false }
            hiddenDepth = row.isDirectory && collapsedDirectories.contains(row.path) ? row.depth : nil
            return true
        }
    }
}

extension FileDiff {
    var changeTreePath: String {
        change.kind == .deleted ? fromFilePath : toFilePath
    }

    var changeTreeTitle: String {
        if fromFilePath != toFilePath {
            return fromFilePath + " → " + toFilePath
        }
        return (changeTreePath as NSString).lastPathComponent
    }
}

enum ChangeDirectoryStaging {
    static func selection(in directory: String, diff: Diff, untrackedFiles: [String] = [], staging: Bool) -> IndexSelection {
        let prefix = directory + "/"
        var selected = diff
        selected.fileDiffs = diff.fileDiffs.filter { $0.changeTreePath.hasPrefix(prefix) }
        var selection = selected.updateAll(stage: staging).indexSelection(staging: staging)
        // A rename is one whole-file operation, including its source outside the destination directory.
        let renameSources = selected.fileDiffs.filter { $0.change.kind == .renamed }.map(\.fromFilePath)
        let untracked = staging ? untrackedFiles.filter { $0.hasPrefix(prefix) } : []
        selection.paths = Array(Set(selection.paths + renameSources + untracked)).sorted()
        return selection
    }
}
