import FoldGitCore
import SwiftUI

struct CommitRowView: View {
    @AppStorage(PreferenceKey.commitGraphDensity.rawValue) private var density = CommitGraphDensity.comfortable
    var commit: Commit
    var outsideCurrentBranch = false
    var isSelected = false
    var incoming = false
    var outgoing = false

    var body: some View {
        Group {
            if density == .singleLine {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    title.lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 6)
                    CommitSyncBadge(incoming: incoming, outgoing: outgoing)
                    tagMark
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { authorText; dateText }.fixedSize()
                        dateText
                    }
                    .foregroundStyle(.tertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: density == .compact ? 1 : nil) {
                    HStack(alignment: .firstTextBaseline) {
                        title.lineLimit(density == .compact ? 1 : nil)
                        Spacer()
                        CommitSyncBadge(incoming: incoming, outgoing: outgoing)
                        tagMark
                    }
                    HStack {
                        if density == .comfortable {
                            Icon(size: .small, authorEmail: commit.authorEmail, authorInitial: String(commit.author.initial.prefix(1)))
                        }
                        authorText
                        Spacer()
                        dateText
                    }
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(commit.title))
        .accessibilityValue(Text("\(commit.author), \(commit.authorDateRelative)"))
    }

    private var title: some View {
        Text(commit.title)
            .foregroundStyle(outsideCurrentBranch && !isSelected ? .secondary : .primary)
    }

    @ViewBuilder private var tagMark: some View {
        if !commit.tags.isEmpty {
            Image(systemName: "tag")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
    }

    private var authorText: some View { Text(commit.author).lineLimit(1) }

    private var dateText: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text(commit.authorDateRelative)
        }
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
