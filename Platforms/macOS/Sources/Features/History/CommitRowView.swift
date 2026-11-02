import FoldGitCore
import SwiftUI

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
                CommitSyncBadge(incoming: incoming, outgoing: outgoing)
                Text(verbatim: String(commit.hash.prefix(7)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(commit.hash)
                Text(verbatim: commit.author)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: "\(commit.author) <\(commit.authorEmail)>"))
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(verbatim: commit.authorDateRelative)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help(commit.authorDateDisplay)
                }
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
            HStack {
                Icon(size: .small, authorEmail: commit.authorEmail, authorInitial: String(commit.author.initial.prefix(1)))
                Text(commit.author)
                Spacer()
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(commit.authorDateRelative)
                }
            }
            .lineLimit(1)
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(commit.title))
        .accessibilityValue(Text("\(commit.author), \(commit.authorDateRelative)"))
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
