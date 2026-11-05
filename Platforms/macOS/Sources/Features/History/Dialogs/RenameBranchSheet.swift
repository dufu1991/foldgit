import FoldGitCore
import SwiftUI

struct RenameBranchSheet: View {
    var folder: WorkspaceEntry
    @Binding var showingRenameBranch: Branch?
    @State private var newBranchName = ""
    @State private var error: Error?
    @State private var isWorking = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack {
            Text("Rename Branch")
                .font(.headline)
            VStack(alignment: .leading) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Old:")
                            .gridColumnAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(showingRenameBranch?.name ?? "")
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("New:")
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("New branch name", text: $newBranchName)
                            .focused($nameFocused)
                            .disabled(isWorking)
                    }
                }
                HStack {
                    Button("Cancel") {
                        showingRenameBranch = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                    Spacer()
                    if isWorking { ProgressView().controlSize(.small) }
                    Button("Rename") {
                        guard !isWorking else { return }
                        isWorking = true
                        Task {
                            defer { isWorking = false }
                            do {
                                try await GitRuntime.run(
                                    GitBranchRename(directory: folder.url, oldBranchName: showingRenameBranch?.name ?? "", newBranchName: newBranchName)
                                )
                                showingRenameBranch = nil
                            } catch {
                                self.error = error
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.init(.defaultAction))
                    .disabled(newBranchName.isEmpty || newBranchName == showingRenameBranch?.name || isWorking)
                }
                .padding(.top)
            }
            .frame(minWidth: 440, idealWidth: 500, maxWidth: 640)
            .padding()
        }
        .padding()
        .cornerRadius(8)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(isWorking)
        .task {
            // Start from the current name, selected, so typing replaces it and small edits stay easy.
            newBranchName = showingRenameBranch?.name ?? ""
            nameFocused = true
            await Task.yield()
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
        .errorSheet($error, operation: "Rename Branch")
    }
}
