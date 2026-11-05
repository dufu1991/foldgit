import FoldGitCore
import SwiftUI

struct TagsContentView: View {
    var folder: WorkspaceEntry
    @Binding var showingTags: Bool
    @Binding var tags: [String]?
    private var filteredTags: [String]? {
        guard !filterText.isEmpty else { return tags }
        return tags?.filter { $0.lowercased().contains(filterText.lowercased()) }
    }
    @State private var filterText: String = ""
    @State private var selection: String?
    @State private var error: Error?
    @State private var isFetching = false
    @State private var deletingTag: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                TextField(text: $filterText) {
                    Text("Filter")
                }
                if isFetching {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 29, height: 17)
                        .padding(.leading)
                } else {
                    Button {
                        isFetching = true
                        Task {
                            defer { isFetching = false }
                            do {
                                try await RemoteUpdateService.shared.execute(
                                    GitFetch(directory: folder.url, tags: true)
                                )
                                AutoFetchScheduler.shared.recordFetchSuccess(for: folder.url)
                                tags = try await GitRuntime.run(GitTag(directory: folder.url))
                            } catch {
                                self.error = OperationFailure("Fetch Tags", error)
                            }
                        }
                    } label: {
                        Label("Fetch Tags", systemImage: "arrow.down")
                            .labelStyle(.iconOnly)
                    }
                    .padding(.leading)
                    .help("Fetch Tags")
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding()
            Divider()
            if let filteredTags {
                if filteredTags.isEmpty {
                    ScrollView {
                            Text("No Content")
                                .foregroundStyle(.secondary)
                                .padding()
                                .padding(.top, 220)
                    }
                } else {
                    // Selecting a tag only highlights it; Return, a double-click or the context menu checks it out.
                    List(filteredTags, id: \.self, selection: $selection) { tag in
                        Label(tag, systemImage: "tag")
                    }
                    .contextMenu(forSelectionType: String.self) { items in
                        if let tag = items.first, items.count == 1 {
                            Button("Checkout") { checkout(tag) }
                            Divider()
                            Button("Delete Tag", role: .destructive) { deletingTag = tag }
                        }
                    } primaryAction: { items in
                        if let tag = items.first, items.count == 1 { checkout(tag) }
                    }
                    .accessibilityIdentifier("tagsList")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog("Delete Tag?", isPresented: Binding(
            get: { deletingTag != nil }, set: { if !$0 { deletingTag = nil } }
        ), titleVisibility: .visible, presenting: deletingTag) { tag in
            Button("Delete Tag", role: .destructive) { delete(tag) }
            Button("Cancel", role: .cancel) { }
        } message: { tag in
            Text("This deletes only the local tag “\(tag)”. Copies already pushed to remotes are not affected.")
        }
        .errorSheet($error, operation: "Load Tags")
    }

    private func checkout(_ tag: String) {
        Task {
            do {
                try await GitRuntime.run(GitCheckout(directory: folder.url, commitHash: tag))
                showingTags = false
            } catch {
                self.error = OperationFailure("Checkout", error)
            }
        }
    }

    private func delete(_ tag: String) {
        Task {
            do {
                try await GitRuntime.run(GitTagDelete(directory: folder.url, tagname: tag))
                tags = tags?.filter { $0 != tag }
                if selection == tag { selection = nil }
            } catch {
                self.error = OperationFailure("Delete Tag", error)
            }
        }
    }
}

#Preview {
    @Previewable @State var showingTags = false
    @Previewable @State var tags: [String]? = ["v1.0.0", "v1.1.0", "v2.0.0"]

    TagsContentView(folder: .init(url: URL(string: "file:///tmp/FoldGit/")!), showingTags: $showingTags, tags: $tags)
        .frame(width: 300, height: 660)
}

#Preview("No Content") {
    @Previewable @State var showingTags = false
    @Previewable @State var tags: [String]? = []

    TagsContentView(folder: .init(url: URL(string: "file:///tmp/FoldGit/")!), showingTags: $showingTags, tags: $tags)
        .frame(width: 300, height: 660)
}
