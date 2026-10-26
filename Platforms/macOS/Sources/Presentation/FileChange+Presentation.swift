import FoldGitCore
import SwiftUI

extension FileChange {
    /// The one-letter codes used by `git status` and most Git clients.
    var letter: String {
        switch kind {
        case .added: "A"
        case .modified, .modeChanged: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .conflicted: "U"
        }
    }

    var title: String {
        switch kind {
        case .added: String(localized: "Added")
        case .modified: String(localized: "Modified")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        case .copied: String(localized: "Copied")
        case .modeChanged: String(localized: "File Mode Changed")
        case .conflicted: String(localized: "Conflicted")
        }
    }

    var color: Color {
        switch kind {
        case .added: .green
        case .modified, .modeChanged: .orange
        case .deleted: .red
        case .renamed, .copied: .blue
        case .conflicted: .purple
        }
    }

    /// The title followed by details that the letter cannot show.
    var detail: String {
        var lines = [title]
        if let similarity {
            lines.append(String(localized: "Similarity: \((Double(similarity) / 100).formatted(.percent))"))
        }
        if let oldMode, let newMode, oldMode != newMode {
            lines.append(String(localized: "File Mode: \(oldMode) → \(newMode)"))
        }
        if isBinary { lines.append(String(localized: "Binary File")) }
        return lines.joined(separator: "\n")
    }
}

struct FileChangeBadge: View {
    let change: FileChange

    var body: some View {
        Text(verbatim: change.letter)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(change.color)
            .frame(width: 16, height: 16)
            .background(change.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            // Assistive technologies read the change type instead of the letter.
            .accessibilityRepresentation { Text(verbatim: change.title) }
            .help(change.detail)
    }
}
