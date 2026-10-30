import FoldGitCore
import SwiftUI

struct AmendCommitSheet: View {
    var folder: WorkspaceEntry
    @Binding var showingAmendCommitAt: Commit?
    var onCreate: (() -> Void)
    @State private var message = ""
    @State private var error: Error?

    var body: some View {
        VStack {
            Text("Amend Commit with a New Message")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading) {
                HStack {
                    TextEditor(text: $message)
                        .scrollContentBackground(.hidden)
                        .frame(height: 100)
                     // .contentMargins(8, for: .scrollContent)
                     // `contentMargins` not work on macOS. Xcode26.0  and macOS26
                }
                HStack {
                    Button("Cancel") {
                        showingAmendCommitAt = nil
                    }
                    Spacer()
                    Button("Amend") {
                        Task {
                            do {
                                try await GitRuntime.run(
                                    GitCommit(directory: folder.url, message: message, amend: true)
                                )
                                onCreate()
                                showingAmendCommitAt = nil
                            } catch {
                                self.error = error
                            }
                        }
                    }
                    .disabled(message.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.init(.return))
                }
                .padding(.top)
            }
            .frame(minWidth: 440, idealWidth: 520, maxWidth: 680)
            .padding()
        }
        .padding()
        .cornerRadius(8)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            message = showingAmendCommitAt?.rawBody ?? ""
        }
        .errorSheet($error, operation: "Amend Last Commit")
    }
}
