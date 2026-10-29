import FoldGitCore
import SwiftUI

struct CommitDetailHeaderView: View {
    @Environment(\.worktreeVisibility) private var worktreeVisibility
    private var visibleBranches: [String] { worktreeVisibility.decorations(commit.branches) }
    var commit: Commit
    @Binding var mergedIn: Commit?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                Text(commit.hash.prefix(5))
                    .textSelection(.disabled)
                    .help("Commit Hash: \(commit.hash)")
                    .contextMenu {
                        Button("Copy \(commit.hash)") {
                            let pasteboard = NSPasteboard.general
                            pasteboard.declareTypes([.string], owner: nil)
                            pasteboard.setString(commit.hash, forType: .string)
                        }
                    }
                Image(systemName: "arrow.right")
                HStack(spacing: 0) {
                    ForEach(commit.parentHashes, id: \.self) { hash in
                        if hash == commit.parentHashes.first {
                            NavigationLink(commit.parentHashes[0].prefix(5), value: commit.parentHashes[0])
                                .foregroundColor(.accentColor)
                        } else {
                            Text(",")
                                .padding(.trailing, 2)
                            NavigationLink(commit.parentHashes[1].prefix(5), value: commit.parentHashes[1])
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .textSelection(.disabled)
                if let mergedIn {
                    Divider()
                        .frame(height: 10)
                    HStack {
                        Image(systemName: "arrow.trianglehead.pull")
                        NavigationLink(mergedIn.hash.prefix(5), value: mergedIn.hash)
                            .foregroundColor(.accentColor)
                    }
                    .help("Merged in \(mergedIn.hash.prefix(5))")
                }
                if !commit.tags.isEmpty {
                    Divider()
                        .frame(height: 10)
                    HStack(spacing: 14) {
                        ForEach(commit.tags, id: \.self) { tag in
                            Label(tag, systemImage: "tag")
                        }
                    }
                }
                if !visibleBranches.isEmpty {
                    Divider()
                        .frame(height: 10)
                    HStack(spacing: 14) {
                        ForEach(visibleBranches, id: \.self) { branch in
                            Label(branch, image: "git.branch")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .foregroundColor(.secondary)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.top, 14)
        .padding(.horizontal)
    }
}
