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
                    List(filteredTags, id: \.self, selection: $selection) { tag in
                        Label(tag, systemImage: "tag")
                            .contextMenu {
                                Button("Delete") {
                                    Task {
                                        do {
                                            try await GitRuntime.run(GitTagDelete(directory: folder.url, tagname: tag))
                                            tags = tags?.filter{ $0 != tag}
                                        } catch {
                                            self.error = OperationFailure("Delete Tag", error)
                                        }
                                    }
                                }
                            }
                    }
                    .onChange(of: selection ?? "", { _, newValue in
                        Task {
                            do {
                                try await GitRuntime.run(GitCheckout(directory: folder.url, commitHash: newValue))
                                showingTags = false
                            } catch {
                                self.error = OperationFailure("Checkout", error)
                            }
                        }
                    })
                }
            }
        }
        .scrollContentBackground(.hidden)
        .errorSheet($error, operation: "Load Tags")
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
