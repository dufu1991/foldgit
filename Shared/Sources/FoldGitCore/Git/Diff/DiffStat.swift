import Foundation

public struct DiffStat: Sendable {
    public init(files: [String], insertions: [Int], deletions: [Int]) {
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
    }

    /// Counts the parsed hunks, so a snapshot needs no separate `--numstat` processes. Binary files count as zero.
    public init(diff: Diff) {
        var insertions: [Int] = []
        var deletions: [Int] = []
        for fileDiff in diff.fileDiffs {
            // Combined diffs prefix each line with one marker column per parent.
            let markers = fileDiff.header.hasPrefix("diff --cc ") || fileDiff.header.hasPrefix("diff --combined ") ? 2 : 1
            var added = 0
            var removed = 0
            for line in fileDiff.chunks.flatMap(\.lines) where line.kind != .header {
                let prefix = line.raw.prefix(markers)
                if prefix.contains("+") { added += 1 } else if prefix.contains("-") { removed += 1 }
            }
            insertions.append(added)
            deletions.append(removed)
        }
        self.init(files: diff.fileDiffs.map(\.toFilePath), insertions: insertions, deletions: deletions)
    }

    public var files: [String]
    public var insertions: [Int]
    public var insertionsTotal: Int { insertions.reduce(0, +) }
    public var deletions: [Int]
    public var deletionsTotal: Int { deletions.reduce(0, +) }
}
