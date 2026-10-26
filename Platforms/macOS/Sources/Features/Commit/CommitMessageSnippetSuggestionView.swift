import SwiftUI

struct CommitMessageSnippetSuggestionView: View {
    @AppStorage(PreferenceKey.commitMessageSnippetEntries.rawValue)
    private var data = PreferenceDefaults.commitMessageSnippetEntries
    private var favorites: [CommitMessageSnippetEntry] {
        CommitMessageSnippetEntry.decode(data).filter(\.isFavorite)
    }

    var body: some View {
        HStack {
            ScrollView(.horizontal) {
                LazyHStack {
                    ForEach(favorites) { snippet in
                        Button(snippet.text) {
                            NotificationCenter.default.post(name: .didSelectCommitMessageSnippetNotification, object: snippet.text)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.leading)
            }
            .frame(height: 40)
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
}

#Preview {
    CommitMessageSnippetSuggestionView()
}
