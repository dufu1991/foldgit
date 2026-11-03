import AppKit
import FoldGitCore
import SwiftUI

struct CommitMessageEditor: View {
    static let height: CGFloat = 72

    var folder: WorkspaceEntry
    @Binding var commitMessage: String
    @Binding var cachedDiffStat: DiffStat?
    @Binding var error: Error?
    @Binding var cachedDiffRaw: String
    @FocusState private var focused: Bool
    @State private var snippetFocusRequest: UUID?
    @State private var isCommitting = false
    @Environment(\.isEnabled) private var isEnabled
    var onCommit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ZStack(alignment: .topLeading) {
                TextEditor(text: $commitMessage)
                    .focused($focused)
                    .accessibilityIdentifier("commitMessageEditor")
                    .scrollContentBackground(.hidden)
                    .padding(.top, 16)
                    .padding(.horizontal, 12)
                    .font(.body)
                if commitMessage.isEmpty && !focused {
                    Text("Commit Message")
                        .foregroundColor(.secondary)
                        .allowsHitTesting(false)
                        .padding(.top, 16)
                        .padding(.horizontal, 17)
                }
            }
            HStack(spacing: 12) {
                CommitMessageSnippetSuggestionView()
                    .font(.callout)
                HStack(spacing: 8) {
                    Label(cachedDiffStat?.files.count.formatted() ?? "-", systemImage: "doc")
                    Label(cachedDiffStat?.insertionsTotal.formatted() ?? "-", systemImage: "plus")
                    Label(cachedDiffStat?.deletionsTotal.formatted() ?? "-", systemImage: "minus")
                }
                .font(.caption)
                .fixedSize()
                Button("Commit", action: commitChanges)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canCommit)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
        }
        .focusedSceneValue(\.editorMenu, menuActions)
        .onReceive(NotificationCenter.default.publisher(for: .didSelectCommitMessageSnippetNotification), perform: { notification in
            if let snippet = notification.object as? String {
                commitMessage = CommitMessageSnippet.applying(snippet, to: commitMessage)
                focused = false
                snippetFocusRequest = UUID()
            }
        })
        .task(id: snippetFocusRequest) {
            guard snippetFocusRequest != nil else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = true
            await Task.yield()
            guard !Task.isCancelled,
                  let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                  editor.string == commitMessage else { return }
            let insertionPoint = NSRange(location: editor.string.utf16.count, length: 0)
            editor.setSelectedRange(insertionPoint)
            editor.scrollRangeToVisible(insertionPoint)
        }
    }

    private var canCommit: Bool {
        isEnabled && !isCommitting && !cachedDiffRaw.isEmpty
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var menuActions: MenuActions {
        var actions = MenuActions()
        actions.isEditingText = focused
        if canCommit { actions[.commit] = commitChanges }
        return actions
    }

    private func commitChanges() {
        guard canCommit else { return }
        isCommitting = true
        Task {
            defer { isCommitting = false }
            do {
                try await GitRuntime.run(GitCommit(directory: folder.url, message: commitMessage))
                onCommit()
            } catch { self.error = OperationFailure("Commit", error) }
        }
    }
}
