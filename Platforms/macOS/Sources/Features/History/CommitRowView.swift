import FoldGitCore
import SwiftUI

/// The same single-line metadata order is used in every commit presentation.
struct CommitMetadataView: View {
    let commit: Commit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: String(commit.hash.prefix(7)))
                .monospaced()
                .fixedSize()
                .help(commit.hash)
                .contextMenu {
                    Button("Copy \(commit.hash)") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(commit.hash, forType: .string)
                    }
                }
            Text(verbatim: commit.author)
                .truncationMode(.middle)
                .help(Text(verbatim: "\(commit.author) <\(commit.authorEmail)>"))
            CommitTimeView(commit: commit)
        }
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }
}

/// Shared text layout for the commit graph and the file history list.
struct CommitSummaryView: View {
    let commit: Commit
    var isSelected = false
    var outsideCurrentBranch = false
    var incoming = false
    var outgoing = false
    var branchName: String?
    var branchColor: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: commit.title)
                .font(.callout)
                .fontWeight(isSelected ? .medium : .regular)
                .foregroundStyle(outsideCurrentBranch && !isSelected ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                CommitMetadataView(commit: commit)
                    .font(.system(size: 10))
                    .layoutPriority(1)
                CommitSyncBadge(incoming: incoming, outgoing: outgoing)
                if let branchName {
                    Label(branchName, image: "git.branch")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(branchColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
            }
        }
        .help(commit.title)
    }
}

struct CommitRowView: View {
    var commit: Commit
    var outsideCurrentBranch = false
    var isSelected = false
    var incoming = false
    var outgoing = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline) {
                Text(commit.title)
                    .foregroundStyle(outsideCurrentBranch && !isSelected ? .secondary : .primary)
                Spacer()
                CommitSyncBadge(incoming: incoming, outgoing: outgoing)
                if !commit.tags.isEmpty {
                    Image(systemName: "tag")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
            }
            CommitMetadataView(commit: commit)
                .font(.system(size: 10))
        }
        .modifier(CommitAccessibilityModifier(commit: commit))
    }
}

struct CommitSyncBadge: View {
    var incoming = false
    var outgoing = false

    var body: some View {
        if incoming || outgoing {
            Label(incoming ? String(localized: "To Pull") : String(localized: "To Push"), systemImage: incoming ? "arrow.down" : "arrow.up")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(incoming ? Color.secondary : Color.accentColor)
                .fixedSize()
                .accessibilityIdentifier(incoming ? "incomingCommitBadge" : "outgoingCommitBadge")
        }
    }
}
