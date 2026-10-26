import FoldGitCore
import Foundation

enum SidebarSort: String, CaseIterable, Identifiable {
    case manual, name, recentlyOpened, recentlyModified, recentlyAdded
    var id: Self { self }
    var title: String {
        switch self {
        case .manual: String(localized: "Manual Order")
        case .name: String(localized: "Name")
        case .recentlyOpened: String(localized: "Recently Opened")
        case .recentlyModified: String(localized: "Recently Modified")
        case .recentlyAdded: String(localized: "Recently Added")
        }
    }
}

struct SidebarDates: Codable, Equatable {
    var added: [String: Date] = [:]
    var opened: [String: Date] = [:]

    mutating func register(_ entries: [WorkspaceEntry], now: Date = .now) {
        for entry in entries.flatMap(\.repositories) where added[entry.identity.path] == nil {
            added[entry.identity.path] = now
        }
    }

    static func decode(_ data: Data) -> Self {
        (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }
}

/// A projection keeps filtering and automatic sorting separate from the saved manual order.
struct SidebarOrganization {
    let folders: [WorkspaceEntry]
    let names: RepositoryDisplayNames
    var query = ""
    var sort: SidebarSort = .manual
    var ascending = true
    var dates = SidebarDates()
    var modified: [String: Date] = [:]
    var worktrees: [URL: [GitWorktree]] = [:]

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canMove: Bool { sort == .manual && !isSearching }

    var entries: [WorkspaceEntry] {
        sorted(folders.compactMap { folder in
            guard isSearching else { return folder }
            if matches(folder) { return folder }
            guard let children = folder.children else { return nil }
            let matching = children.filter(matches)
            guard !matching.isEmpty else { return nil }
            var filtered = folder
            filtered.children = matching
            return filtered
        })
    }

    func sorted(_ entries: [WorkspaceEntry]) -> [WorkspaceEntry] {
        guard sort != .manual else { return entries }
        return entries.enumerated().sorted { left, right in
            let comparison: ComparisonResult
            if sort == .name {
                comparison = title(left.element).localizedStandardCompare(title(right.element))
            } else {
                let lhs = date(left.element)
                let rhs = date(right.element)
                // Unknown dates remain last in both directions.
                if lhs == nil || rhs == nil {
                    if lhs == nil && rhs == nil { return left.offset < right.offset }
                    return lhs != nil
                }
                comparison = lhs!.compare(rhs!)
            }
            if comparison == .orderedSame { return left.offset < right.offset }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }.map(\.element)
    }

    private func title(_ entry: WorkspaceEntry) -> String {
        entry.isRepository ? names.displayName(for: entry) : entry.displayName
    }

    private func matches(_ entry: WorkspaceEntry) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entry.displayName.localizedStandardContains(query)
            || (entry.isRepository && names.displayName(for: entry).localizedStandardContains(query))
            || (entry.isRepository && (worktrees[entry.identity] ?? []).contains { tree in
                tree.url.path.localizedStandardContains(query)
                    || tree.branch?.localizedStandardContains(query) == true
                    || names.displayName(for: WorkspaceEntry(url: tree.url)).localizedStandardContains(query)
            })
    }

    private func date(_ entry: WorkspaceEntry) -> Date? {
        let values: [String: Date]
        switch sort {
        case .recentlyOpened: values = dates.opened
        case .recentlyModified: values = modified
        case .recentlyAdded: values = dates.added
        default: return nil
        }
        return entry.repositories.compactMap { values[$0.identity.path] }.max()
    }

    static func moving(_ visible: [WorkspaceEntry], in original: [WorkspaceEntry], from source: IndexSet, to destination: Int) -> [WorkspaceEntry] {
        let moved = visible.movingElements(at: Set(source), to: destination)
        let visibleIDs = Set(visible.map(\.identity))
        var iterator = moved.makeIterator()
        return original.map { visibleIDs.contains($0.identity) ? iterator.next()! : $0 }
    }

    static func adding(_ entry: WorkspaceEntry, to folders: [WorkspaceEntry]) -> [WorkspaceEntry] {
        WorkspaceGroups.addingRepositories(entry.repositories, to: folders)
    }
}
