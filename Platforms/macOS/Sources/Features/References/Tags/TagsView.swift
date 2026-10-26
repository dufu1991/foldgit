import FoldGitCore
import SwiftUI

struct TagsView: View {
    var folder: WorkspaceEntry
    @Binding var showingTags: Bool
    @State private var tags: [String]?
    @State private var error: Error?

    var body: some View {
        TagsContentView(folder: folder, showingTags: $showingTags, tags: $tags)
            .frame(width: 300, height: 660)
            .task {
                do {
                    tags = try await GitRuntime.run(GitTag(directory: folder.url))
                } catch {
                    self.error = error
                }
            }
            .errorSheet($error)
    }
}
