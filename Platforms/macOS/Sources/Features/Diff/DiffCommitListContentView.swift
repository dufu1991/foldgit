import FoldGitCore
import SwiftUI

struct DiffCommitListContentView: View {
    var commits: [Commit]

    var body: some View {
        LazyVStack(spacing: 4) {
            ForEach(commits) { commit in
                let listBody = commit.listBody
                NavigationLink(value: commit.hash) {
                    VStack (alignment: .leading, spacing: 6) {
                        Text(verbatim: commit.title)
                        if !listBody.isEmpty {
                            Text(verbatim: listBody)
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                        CommitMetadataView(commit: commit)
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .modifier(CommitAccessibilityModifier(commit: commit))
            }
            .accentColor(.primary)
        }
    }
}
