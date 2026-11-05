import SwiftUI

struct CommitMessageSnippetView: View {
    @AppStorage(PreferenceKey.commitMessageSnippetEntries.rawValue)
    private var data = PreferenceDefaults.commitMessageSnippetEntries
    @State private var editingSnippet: CommitMessageSnippetEntry?
    @State private var error: Error?
    @Environment(\.undoManager) private var undoManager
    private var snippets: [CommitMessageSnippetEntry] { CommitMessageSnippetEntry.decode(data) }

    var body: some View {
        Form {
            Section {
                if snippets.isEmpty {
                    Text("No Commit Message Snippets")
                        .foregroundStyle(.secondary)
                }
                ForEach(snippets) { snippet in
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { snippet.isFavorite },
                            set: { isFavorite in
                                var updated = snippet
                                updated.isFavorite = isFavorite
                                update(updated)
                            }
                        )) {
                            Text(verbatim: snippet.text)
                                .lineLimit(2)
                                .help(snippet.text)
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 0)
                        Button("Edit", systemImage: "pencil") { editingSnippet = snippet }
                            .labelStyle(.iconOnly)
                            .help("Edit")
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            delete(snippet)
                        }
                        .labelStyle(.iconOnly)
                        .help("Delete")
                    }
                }
                .onMove { source, destination in
                    var reordered = snippets
                    reordered.move(fromOffsets: source, toOffset: destination)
                    replaceUndoably(with: reordered, actionName: String(localized: "Move Snippet"))
                }
                Button("Add Snippet", systemImage: "plus") {
                    editingSnippet = CommitMessageSnippetEntry(text: "", isFavorite: true)
                }
            } header: {
                Text("Commit Message Snippets")
            } footer: {
                Text("Checked snippets appear below the commit message editor. Drag snippets to change their order.")
            }
        }
        .settingsForm()
        .sheet(item: $editingSnippet) { snippet in
            CommitMessageSnippetEditSheet(snippet: snippet, isNew: !snippets.contains { $0.id == snippet.id }, onSave: update)
        }
        .errorSheet($error, operation: "Save Commit Message Snippets")
    }

    private func update(_ snippet: CommitMessageSnippetEntry) {
        var updated = snippets
        if let index = updated.firstIndex(where: { $0.id == snippet.id }) {
            updated[index] = snippet
        } else {
            updated.append(snippet)
        }
        save(updated)
    }

    private func delete(_ snippet: CommitMessageSnippetEntry) {
        replaceUndoably(with: snippets.filter { $0.id != snippet.id }, actionName: String(localized: "Delete Snippet"))
    }

    /// Registers the previous list with the window's undo manager, so Command-Z brings a deleted or moved snippet back.
    private func replaceUndoably(with updated: [CommitMessageSnippetEntry], actionName: String) {
        let previous = data
        let manager = undoManager
        save(updated)
        manager?.registerUndo(withTarget: SnippetUndoTarget.shared) { _ in
            MainActor.assumeIsolated {
                UserDefaults.standard.set(previous, forKey: PreferenceKey.commitMessageSnippetEntries.rawValue)
            }
        }
        manager?.setActionName(actionName)
    }

    private func save(_ snippets: [CommitMessageSnippetEntry]) {
        do {
            data = try JSONEncoder().encode(snippets)
        } catch {
            self.error = error
        }
    }
}

/// Undo registration needs a reference target; the snippet list itself lives in user defaults.
private final class SnippetUndoTarget {
    nonisolated(unsafe) static let shared = SnippetUndoTarget()
}

private struct CommitMessageSnippetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var snippet: CommitMessageSnippetEntry
    var isNew = false
    var onSave: (CommitMessageSnippetEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Snippet" : "Edit Snippet")
                .font(.headline)
            MultilineTextEditor(text: $snippet.text, bordered: true,
                                accessibilityLabel: String(localized: "Enter commit message snippet here"))
                .frame(height: 120)
            Toggle("Show in Quick Input", isOn: $snippet.isFavorite)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(snippet)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

#Preview {
    CommitMessageSnippetView()
}
