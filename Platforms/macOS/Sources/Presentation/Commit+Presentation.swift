import FoldGitCore
import Foundation

extension Commit {
    var authorDateDisplay: String {
        date.map { DateFormatter.localizedString(from: $0, dateStyle: .long, timeStyle: .medium) } ?? ""
    }
    var authorTimeZoneDisplay: String {
        date?.formatted(.dateTime.timeZone(.localizedGMT(.short))) ?? ""
    }
    var authorDateDisplayShort: String {
        date.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? ""
    }
    var authorDateRelative: String {
        date?.formatted(.relative(presentation: .named)) ?? ""
    }
    /// Merge commits, including octopus merges, revert against their first parent.
    var revertMainline: Int? { parentHashes.count > 1 ? 1 : nil }
}
