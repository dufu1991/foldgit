import SwiftUI

struct CommitMessageSnippetSuggestionView: View {
    @AppStorage(PreferenceKey.commitMessageSnippetEntries.rawValue)
    private var data = PreferenceDefaults.commitMessageSnippetEntries
    private var favorites: [CommitMessageSnippetEntry] {
        CommitMessageSnippetEntry.decode(data).filter(\.isFavorite)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack {
                ForEach(favorites) { snippet in
                    Button(snippet.text) {
                        NotificationCenter.default.post(name: .didSelectCommitMessageSnippetNotification, object: snippet.text)
                    }
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
    CommitMessageSnippetSuggestionView()
}
