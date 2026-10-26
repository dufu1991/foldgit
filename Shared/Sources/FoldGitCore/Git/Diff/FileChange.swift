import Foundation

/// How one file changed, read from the extended header lines of its diff.
public struct FileChange: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case added, modified, deleted, renamed, copied, modeChanged, conflicted
    }

    public let kind: Kind
    /// Git's similarity index for renames and copies, from 0 to 100.
    public let similarity: Int?
    public let oldMode: String?
    public let newMode: String?
    public let isBinary: Bool

    public init(kind: Kind, similarity: Int? = nil, oldMode: String? = nil, newMode: String? = nil, isBinary: Bool = false) {
        self.kind = kind
        self.similarity = similarity
        self.oldMode = oldMode
        self.newMode = newMode
        self.isBinary = isBinary
    }

    init(header: String, extendedHeaderLines lines: [String], hasHunks: Bool) {
        func value(_ prefix: String) -> String? {
            lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        let isBinary = lines.contains { $0.hasPrefix("Binary files ") || $0 == "GIT binary patch" }
        let similarity = value("similarity index ").flatMap { Int($0.dropLast()) }
        let kind: Kind
        var oldMode = value("old mode ")
        var newMode = value("new mode ")
        if header.hasPrefix("diff --cc ") || header.hasPrefix("diff --combined ") {
            kind = .conflicted
        } else if let mode = value("new file mode ") {
            kind = .added
            newMode = mode
        } else if let mode = value("deleted file mode ") {
            kind = .deleted
            oldMode = mode
        } else if value("rename from ") != nil {
            kind = .renamed
        } else if value("copy from ") != nil {
            kind = .copied
        } else if oldMode != nil, newMode != nil, !hasHunks, !isBinary {
            kind = .modeChanged
        } else {
            kind = .modified
        }
        self.init(kind: kind, similarity: kind == .renamed || kind == .copied ? similarity : nil,
                  oldMode: oldMode, newMode: newMode, isBinary: isBinary)
    }
}
