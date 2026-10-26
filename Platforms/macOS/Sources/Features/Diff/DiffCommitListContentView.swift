import FoldGitCore
import SwiftUI

struct DiffCommitListContentView: View {
    var commits: [Commit]

    var body: some View {
        LazyVStack(spacing: 4) {
            ForEach(commits) { commit in
                NavigationLink(value: commit.hash) {
                    VStack (alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(commit.title)
                                if !commit.body.isEmpty {
                                    Text(commit.body.trimmingCharacters(in: .whitespacesAndNewlines))
                                        .foregroundStyle(.secondary)
                                        .font(.callout)
                                }
                            }
                            Spacer()
                            Text(commit.hash.prefix(5))
                                .foregroundStyle(.tertiary)
                        }
                        HStack {
                            Icon(size: .small, authorEmail: commit.authorEmail, authorInitial: String(commit.author.initial.prefix(1)))
                            Text(commit.author)
                            Spacer()
                            Text(commit.authorDateRelative)
                        }
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(Text(commit.title))
                .accessibilityValue(Text("\(commit.author), \(commit.authorDateRelative)"))
                if commits.last != commit {
                    Divider()
                }
            }
            .accentColor(.primary)
        }
    }
}
