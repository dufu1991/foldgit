import FoldGitCore
import SwiftUI

struct CreateNewBranchSheet: View {
    var folder: WorkspaceEntry
    @Binding var showingCreateNewBranchFrom: Branch?
    var onCreate: (() -> Void)
    @State private var newBranchName = ""
    @State private var error: Error?
    @State private var isWorking = false

    /// A commit start point shows as an abbreviated hash, like everywhere else in the history.
    private var startPointName: String {
        guard let name = showingCreateNewBranchFrom?.name else { return "" }
        let isHash = name.count == 40 && name.allSatisfy(\.isHexDigit)
        return isHash ? String(name.prefix(12)) : name
    }

    var body: some View {
        VStack {
            Text("New Branch")
                .font(.headline)
            VStack(alignment: .leading) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("From:")
                            .gridColumnAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: startPointName)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("Name:")
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("New branch name", text: $newBranchName)
                            .disabled(isWorking)
                    }
                }
                HStack {
                    Button("Cancel") {
                        showingCreateNewBranchFrom = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                    Spacer()
                    if isWorking { ProgressView().controlSize(.small) }
                    Button("Create") {
                        guard !isWorking, let startPoint = showingCreateNewBranchFrom?.point else { return }
                        isWorking = true
                        Task {
                            defer { isWorking = false }
                            do {
                                try await GitRuntime.run(
                                    GitCheckoutB(directory: folder.url, newBranchName: newBranchName, startPoint: startPoint)
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
                    .disabled(newBranchName.isEmpty || isWorking)
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
        .errorSheet($error, operation: "New Branch")
    }
}

#Preview {
    @Previewable @State var isShowing: Branch? = Branch(name: "feature", isCurrent: false)
    CreateNewBranchSheet(folder: .init(url: .init(string: "file:///projects/")!), showingCreateNewBranchFrom: $isShowing) {}
}
