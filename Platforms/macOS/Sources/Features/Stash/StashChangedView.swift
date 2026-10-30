import FoldGitCore
import SwiftUI

struct StashChangedView: View {
    var folder: WorkspaceEntry
    @Binding var showingStashChanged: Bool
    @State private var stashList: [Stash]?
    @State private var error: Error?

    var body: some View {
        StashChangedContentView(folder: folder, showingStashChanged: $showingStashChanged, stashList: stashList, onTapDropButton: { stash in
            Task {
                do {
                    try await GitRuntime.run(GitStashDrop(directory: folder.url, index: stash.index))
                    stashList = try await GitRuntime.run(GitStashList(directory: folder.url))
                } catch {
                    self.error = OperationFailure("Drop Stash", error)
                }
            }
        })
        .task {
            do {
               stashList = try await GitRuntime.run(GitStashList(directory: folder.url))
            } catch {
                self.error = OperationFailure("Load Stashes", error)
            }
        }
        .errorSheet($error, operation: "Load Stashes")
    }
}
