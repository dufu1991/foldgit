import FoldGitCore
import SwiftUI

struct DiffCommitListView: View {
    var commits: [Commit]
    private var authorEmailAndNames: [(String, String)] {
        commits.map { ($0.authorEmail, $0.author) }
            .reduce(into: []) { result, item in
                if !result.contains(where: { $0.0 == item.0 }) {
                    result.append(item)
                }
            }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            DiffCommitListContentView(commits: commits)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    if commits.count > 1 {
                        Text("\(commits.count) commits")
                        Text(commits.first!.authorDateDisplayShort)
                        Image(systemName: "arrow.right")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                        Text(commits.last!.authorDateDisplayShort)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]) {
                            ForEach(authorEmailAndNames, id: \.0) { element in
                                Icon(size: .medium, authorEmail: element.0, authorInitial: String(element.1.initial.prefix(2)))
                                    .help(element.1)
                            }
                        }
                        .padding(.vertical, 8)
                    } else {
                        EmptyView()
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 120)
        }
    }
}

#Preview {
    DiffCommitListView(commits: [
        Commit(hash: "a", parentHashes: ["b"], author: "m a", authorEmail: "dummy@aoyama.dev", authorDate: "", title: "Hi", body: "", branches: [], tags: []),
        Commit(hash: "b", parentHashes: ["c"], author: "m b", authorEmail: "dummy2@aoyama.dev", authorDate: "", title: "Hi", body: "", branches: [], tags: []),
        Commit(hash: "d", parentHashes: ["e"], author: "m a", authorEmail: "dummy@aoyama.dev", authorDate: "", title: "Hi", body: "", branches: [], tags: [])
    ])
}
