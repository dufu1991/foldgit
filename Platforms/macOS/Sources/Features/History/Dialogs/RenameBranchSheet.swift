import FoldGitCore
import SwiftUI

struct RenameBranchSheet: View {
    var folder: WorkspaceEntry
    @Binding var showingRenameBranch: Branch?
    @State private var newBranchName = ""
    @State private var error: Error?

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
                    }
                }
                HStack {
                    Button("Cancel") {
                        showingRenameBranch = nil
                    }
                    Spacer()
                    Button("Rename") {
                        Task {
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
                    .disabled(newBranchName.isEmpty)
                }
                .padding(.top)
            }
            .frame(minWidth: 440, idealWidth: 500, maxWidth: 640)
            .padding()
        }
        .padding()
        .cornerRadius(8)
        .fixedSize(horizontal: false, vertical: true)
        .errorSheet($error, operation: "Rename Branch")
    }
}
