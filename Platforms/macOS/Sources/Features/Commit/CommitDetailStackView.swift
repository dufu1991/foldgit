import FoldGitCore
import SwiftUI

struct CommitDetailStackView: View {
    @State private var path: [String] = []
    var commit: Commit
    var folder: WorkspaceEntry

    var body: some View {
        NavigationStack(path: $path) {
            CommitDetailContentView(commit: commit, folder: folder)
                .navigationDestination(for: String.self) { commitHash in
                    CommitDetailView(commitHash: commitHash, folder: folder)
                }
        }
        .onChange(of: commit) { oldValue, newValue in
            path = []
        }
    }
}
