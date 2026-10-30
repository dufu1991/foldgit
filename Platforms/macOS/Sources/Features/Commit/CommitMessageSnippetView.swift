import SwiftUI

struct CommitMessageSnippetView: View {
    @AppStorage(PreferenceKey.commitMessageSnippetEntries.rawValue)
    private var data = PreferenceDefaults.commitMessageSnippetEntries
    @State private var editingSnippet: CommitMessageSnippetEntry?
    @State private var error: Error?
    private var snippets: [CommitMessageSnippetEntry] { CommitMessageSnippetEntry.decode(data) }

    var body: some View {
        Form {
            Section {
                Text("Check frequently used snippets to show them below the commit message editor.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Commit Message Snippets") {
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
                            save(snippets.filter { $0.id != snippet.id })
                        }
                        .labelStyle(.iconOnly)
                        .help("Delete")
                    }
                }
                Button("Add", systemImage: "plus") {
                    editingSnippet = CommitMessageSnippetEntry(text: "", isFavorite: true)
                }
            }
        }
        .settingsForm()
        .sheet(item: $editingSnippet) { snippet in
            CommitMessageSnippetEditSheet(snippet: snippet, onSave: update)
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

    private func save(_ snippets: [CommitMessageSnippetEntry]) {
        do {
            data = try JSONEncoder().encode(snippets)
        } catch {
            self.error = error
        }
    }
}

private struct CommitMessageSnippetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var snippet: CommitMessageSnippetEntry
    var onSave: (CommitMessageSnippetEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Commit Message Snippets")
                .font(.headline)
            Text("Enter commit message snippet here")
                .foregroundStyle(.secondary)
            TextEditor(text: $snippet.text)
                .font(.body)
                .frame(height: 120)
                .border(.separator)
                .accessibilityLabel(Text("Enter commit message snippet here"))
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
