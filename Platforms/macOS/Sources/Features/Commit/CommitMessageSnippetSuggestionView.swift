import SwiftUI

struct CommitMessageSnippetSuggestionView: View {
    @AppStorage(PreferenceKey.commitMessageSnippetEntries.rawValue)
    private var data = PreferenceDefaults.commitMessageSnippetEntries
    private var favorites: [CommitMessageSnippetEntry] {
        CommitMessageSnippetEntry.decode(data).filter(\.isFavorite)
    }
    /// Inserts into the editor that owns this row only, so other windows keep their drafts.
    var onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack {
                ForEach(favorites) { snippet in
                    Button {
                        onSelect(snippet.text)
                    } label: {
                        Text(verbatim: snippet.text.replacingOccurrences(of: "\n", with: " "))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 220)
                    }
                    .help(snippet.text)
                    .accessibilityLabel(Text(verbatim: snippet.text))
                }
                Button {
                    SettingsWindowController.show(tab: .snippets)
                } label: {
                    Label("Commit Message Snippets", systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                }
                .help("Commit Message Snippets")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(height: 28)
    }
}

#Preview {
    CommitMessageSnippetSuggestionView(onSelect: { _ in })
}
