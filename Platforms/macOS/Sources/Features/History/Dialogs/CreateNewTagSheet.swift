import FoldGitCore
import SwiftUI

struct CreateNewTagSheet: View {
    var folder: WorkspaceEntry
    @Binding var showingCreateNewTagAt: Commit?
    var onCreate: (() -> Void)
    @State private var newTagname = ""
    @State private var isLoading = false
    @State private var error: Error?

    var body: some View {
        VStack {
            Text("New Tag")
                .font(.headline)
            VStack(alignment: .leading) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Commit:")
                            .gridColumnAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(showingCreateNewTagAt?.hash ?? "")
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("Tag Name:")
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("New tag name", text: $newTagname)
                            .disabled(isLoading)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        tagActions
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .trailing, spacing: 10) {
                        tagActions
                    }
                }
                .padding(.top)
            }
            .frame(minWidth: 440, idealWidth: 500, maxWidth: 640)
            .padding()
        }
        .padding()
        .cornerRadius(8)
        .fixedSize(horizontal: false, vertical: true)
        .errorSheet($error)
    }

    @ViewBuilder
    private var tagActions: some View {
        Button("Cancel") {
            showingCreateNewTagAt = nil
        }
        Button("Create") {
            Task {
                do {
                    try await GitRuntime.run(
                        GitTagCreate(
                            directory: folder.url,
                            tagname: newTagname,
                            object: showingCreateNewTagAt!.hash
                        )
                    )
                    onCreate()
                    showingCreateNewTagAt = nil
                } catch {
                    self.error = error
                }
            }
        }
        .disabled(newTagname.isEmpty)
        if isLoading {
            ProgressView()
                .scaleEffect(0.4)
                .frame(minWidth: 24, minHeight: 17)
        } else {
            Button("Create & Push") {
                Task {
                    isLoading = true
                    defer { isLoading = false }
                    do {
                        let currentBranch = try await GitRuntime.run(GitBranch(directory: folder.url)).current
                        guard let currentBranch, let remote = try await TrackingBranch.inspect(in: folder.url, branch: currentBranch.name)?.remote else {
                            throw GitExecutionError(description: String(localized: "No remote repository is configured."))
                        }
                        try await GitRuntime.run(
                            GitTagCreate(
                                directory: folder.url,
                                tagname: newTagname,
                                object: showingCreateNewTagAt!.hash
                            )
                        )
                        try await GitRuntime.run(
                            GitPush(directory: folder.url, refspec: "refs/tags/\(newTagname)", remote: remote)
                        )
                        onCreate()
                        showingCreateNewTagAt = nil
                    } catch {
                        isLoading = false
                        self.error = error
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.init(.defaultAction))
            .disabled(newTagname.isEmpty)
        }
    }
}
