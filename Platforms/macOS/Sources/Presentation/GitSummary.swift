import FoldGitCore
import Foundation

/// Formats Git's short statistics for display without changing the command output.
enum GitSummary {
    /// Already localized; do not pass the result to `shortStat`, which splits Git's English output at commas.
    static func describe(_ statistics: DiffStat) -> String {
        guard !statistics.files.isEmpty else { return "" }
        let count = statistics.files.count
        let insertions = statistics.insertionsTotal
        let deletions = statistics.deletionsTotal
        return [String(localized: "\(count) files changed"), String(localized: "\(insertions) insertions"),
                String(localized: "\(deletions) deletions")].formatted(.list(type: .and))
    }

    static func shortStat(_ output: String) -> String {
        output.split(separator: ",").map { component in
            let text = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = text.split(separator: " ").first, let count = Int(first) else {
                return text
            }
            if text.contains("file") {
                return String(localized: "\(count) files changed")
            }
            if text.contains("insertion") {
                return String(localized: "\(count) insertions")
            }
            if text.contains("deletion") {
                return String(localized: "\(count) deletions")
            }
            return text
        }.formatted(.list(type: .and))
    }
}
