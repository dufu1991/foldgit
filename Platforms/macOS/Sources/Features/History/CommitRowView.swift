import FoldGitCore
import SwiftUI

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
