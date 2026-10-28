import AppKit
import FoldGitCore
import SwiftUI

struct CommitMessageEditor: View {
    var folder: WorkspaceEntry
    @Binding var commitMessage: String
    @Binding var cachedDiffStat: DiffStat?
    @Binding var isAmend: Bool
    @Binding var error: Error?
    @Binding var cachedDiffRaw: String
    @Binding var amendCommit: Commit?
    @FocusState private var focused: Bool
    @State private var snippetFocusRequest: UUID?
    @State private var isCommitting = false
    @Environment(\.isEnabled) private var isEnabled
    var onCommit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 0) {
                VStack(spacing: 0) {
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
                    CommitMessageSnippetSuggestionView()
                        .padding(.trailing)
                        .font(.callout)
                }
                Divider()
                VStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(cachedDiffStat?.files.count.formatted() ?? "-" , systemImage: "doc")
                        Label(cachedDiffStat?.insertionsTotal.formatted() ?? "-", systemImage: "plus")
                        Label(cachedDiffStat?.deletionsTotal.formatted() ?? "-", systemImage: "minus")
                    }
                    .font(.caption)
                    Button("Commit", action: commitChanges)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCommit)
                    Toggle("Amend", isOn: $isAmend)
                        .disabled(isCommitting)
                        .font(.caption)
                        .padding(.trailing, 6)
                }
                .onChange(of: isAmend) {
                    if isAmend {
                        commitMessage = amendCommit?.rawBody ?? ""
                    } else {
                        commitMessage = ""
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
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
        if isEnabled && !isCommitting && amendCommit != nil {
            actions[.amendCommit] = { isAmend = true; focused = true }
        }
        return actions
    }

    private func commitChanges() {
        guard canCommit else { return }
        isCommitting = true
        Task {
            defer { isCommitting = false }
            do {
                try await GitRuntime.run(GitCommit(directory: folder.url, message: commitMessage, amend: isAmend))
                onCommit()
            } catch { self.error = error }
        }
    }
}
