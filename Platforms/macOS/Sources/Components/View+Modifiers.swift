import FoldGitCore
import SwiftUI

extension View {
    func errorSheet(_ error: Binding<Error?>, operation: LocalizedStringResource) -> some View {
        sheet(isPresented: Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )) {
            ErrorTextSheet(error: error, operation: operation)
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
        contextMenu {
            CommitContextMenu(folder: folder, commit: commit, logStore: logStore, isRefresh: isRefresh,
                              showing: showing, bindingError: bindingError)
        }
    }

    func tapGesture(logID: String, selectionLogID: Binding<String?>, subSelectionLogID: Binding<String?>, history: HistoryStore? = nil) -> some View {
        onTapGesture {
            if let history {
                history.select(logID, extending: NSEvent.modifierFlags.contains(.shift), comparing: NSEvent.modifierFlags.contains(.command))
                let ordered = history.logs().filter { history.selectedHashes.contains($0.id) }
                selectionLogID.wrappedValue = ordered.first?.id
                subSelectionLogID.wrappedValue = ordered.count > 1 ? ordered.last?.id : nil
                return
            }
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

/// A view rather than plain menu content, so the items follow the commit-operations setting as it changes.
private struct CommitContextMenu: View {
    @AppStorage(PreferenceKey.disableCommitOperations.rawValue) private var disableCommitOperations = false
    let folder: URL
    let commit: Commit
    let logStore: HistoryStore
    @Binding var isRefresh: Bool
    @Binding var showing: RepositoryPresentation
    @Binding var bindingError: Error?

    var body: some View {
        Button("Checkout") { showing.commitOperation = .checkout(commit) }
        Button("New Branch from Here") {
            showing.createNewBranchFrom = Branch(name: commit.hash, isCurrent: false)
        }
        Button("New Tag") { showing.createNewTagAt = commit }
        Divider()
        Button("Copy Commit Hash") { copy(commit.hash) }
        Button("Copy Commit Message") { copy(commit.rawBody) }
        if !disableCommitOperations {
            Divider()
            Button("Cherry-Pick Commit") { showing.commitOperation = .cherryPick(commit) }
            Button(commit.revertMainline != nil
                   ? String(localized: "Revert using mainline \(String(commit.parentHashes[0].prefix(7)))")
                   : String(localized: "Revert")) {
                showing.commitOperation = .revert(commit)
            }
            Menu("Reset Current Branch to Here") {
                Button("Soft") { showing.commitOperation = .reset(commit, .soft) }
                Button("Mixed") { showing.commitOperation = .reset(commit, .mixed) }
                Button("Hard") { showing.commitOperation = .reset(commit, .hard) }
            }
            // Amending always rewrites HEAD, so only the HEAD row offers it, and only without staged changes.
            if commit.hash == logStore.snapshot?.headHash, logStore.notCommitted?.diffCached.isEmpty != false {
                Button("Amend Commit with a New Message") { showing.amendCommitAt = commit }
            }
            if logStore.selectedHashes.contains(commit.hash), logStore.selectedHashes.count >= 2 {
                Button("Squash Commits") { showing.squashCommits = true }
                    .disabled(logStore.squashSelectionError != nil)
                    .help(logStore.squashSelectionError.map { NSLocalizedString($0, comment: "Squash selection") } ?? "")
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
