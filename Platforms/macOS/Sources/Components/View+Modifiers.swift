import FoldGitCore
import SwiftUI

extension View {
    func errorSheet(_ error: Binding<Error?>) -> some View {
        sheet(isPresented: .constant(error.wrappedValue != nil)) {
            ErrorTextSheet(error: error)
        }
    }

    func commitContextMenu(
        folder: URL,
        commit: Commit,
        logStore: HistoryStore,
        isRefresh: Binding<Bool>,
        showing: Binding<RepositoryPresentation>,
        bindingError: Binding<Error?>
    ) -> some View {
        contextMenu{
            Button("Checkout") {
                Task {
                    do {
                        try await GitRuntime.run(GitCheckout(directory: folder, commitHash: commit.hash))
                        isRefresh.wrappedValue = true
                    } catch {
                        bindingError.wrappedValue = error
                    }
                }
            }
            Button(commit.parentHashes.count == 2
                   ? String(localized: "Revert using mainline \(String(commit.parentHashes[0].prefix(7)))")
                   : String(localized: "Revert")) {
                Task {
                    do {
                        if commit.parentHashes.count == 2 {
                            try await GitRuntime.run(GitRevert(directory: folder,  parentNumber: 1, commit: commit.hash))
                        } else {
                            try await GitRuntime.run(GitRevert(directory: folder, commit: commit.hash))
                        }
                        isRefresh.wrappedValue = true
                    } catch {
                        bindingError.wrappedValue = error
                    }
                }
            }
            if commit == logStore.commits.first {
                if let notCommitted = logStore.notCommitted {
                    if notCommitted.diffCached.isEmpty {
                        Button("Amend Commit with a New Message") {
                            showing.wrappedValue.amendCommitAt = commit
                        }
                    }
                } else {
                    Button("Amend Commit with a New Message") {
                        showing.wrappedValue.amendCommitAt = commit
                    }
                }
            }
            Button("Tag") {
                showing.wrappedValue.createNewTagAt = commit
            }
        }
    }

    func tapGesture(logID: String, selectionLogID: Binding<String?>, subSelectionLogID: Binding<String?>) -> some View {
        onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                // Command-click adds, promotes, or clears a comparison selection.
                if selectionLogID.wrappedValue != nil {
                    if selectionLogID.wrappedValue == logID && subSelectionLogID.wrappedValue == nil {
                        // The only selected row is deselected.
                        selectionLogID.wrappedValue = nil
                    } else if selectionLogID.wrappedValue == logID {
                        // The secondary selection becomes primary.
                        selectionLogID.wrappedValue = subSelectionLogID.wrappedValue
                        subSelectionLogID.wrappedValue = nil
                    } else if subSelectionLogID.wrappedValue == logID {
                        // The secondary selection is cleared.
                        subSelectionLogID.wrappedValue = nil
                    } else {
                        // Another row becomes the secondary selection.
                        subSelectionLogID.wrappedValue = logID
                    }
                } else {
                    // Without a primary selection, the row becomes primary.
                    selectionLogID.wrappedValue = logID
                }
            } else {
                // A plain click selects one row.
                selectionLogID.wrappedValue = logID
                subSelectionLogID.wrappedValue = nil
            }
        }
    }
}
