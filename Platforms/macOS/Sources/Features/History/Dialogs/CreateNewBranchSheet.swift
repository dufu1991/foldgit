import FoldGitCore
import SwiftUI

struct CreateNewBranchSheet: View {
    var folder: WorkspaceEntry
    @Binding var showingCreateNewBranchFrom: Branch?
    var onCreate: (() -> Void)
    @State private var newBranchName = ""
    @State private var error: Error?

    var body: some View {
        VStack {
            Text("Create New Branch")
                .font(.headline)
            VStack(alignment: .leading) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("from:")
                            .gridColumnAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(showingCreateNewBranchFrom?.name ?? "")
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("to:")
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("New branch name", text: $newBranchName)
                    }
                }
                HStack {
                    Button("Cancel") {
                        showingCreateNewBranchFrom = nil
                    }
                    Spacer()
                    Button("Create") {
                        Task {
                            do {
                                try await GitRuntime.run(
                                    GitCheckoutB(directory: folder.url, newBranchName: newBranchName, startPoint: showingCreateNewBranchFrom!.point)
                                )
                                showingCreateNewBranchFrom = nil
                                onCreate()
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
        .errorSheet($error)
    }
}

#Preview {
    @Previewable @State var isShowing: Branch? = Branch(name: "feature", isCurrent: false)
    CreateNewBranchSheet(folder: .init(url: .init(string: "file:///projects/")!), showingCreateNewBranchFrom: $isShowing) {}
}
