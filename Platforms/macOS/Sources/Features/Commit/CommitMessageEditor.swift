import AppKit
import FoldGitCore
import Observation
import SwiftUI

/// Commit message drafts for the session, keyed by repository so leaving the changes view keeps the text.
@MainActor
@Observable
final class CommitDraftStore {
    static let shared = CommitDraftStore()
    private var messages: [String: String] = [:]

    private static func key(for directory: URL) -> String { RepositoryLocation.canonical(directory).path }

    func message(for directory: URL) -> String { messages[Self.key(for: directory)] ?? "" }

    func setMessage(_ message: String, for directory: URL) {
        let key = Self.key(for: directory)
        if message.isEmpty { messages.removeValue(forKey: key) } else if messages[key] != message { messages[key] = message }
    }

    func clear(for directory: URL) { messages.removeValue(forKey: Self.key(for: directory)) }

    func binding(for directory: URL) -> Binding<String> {
        Binding(get: { self.message(for: directory) }, set: { self.setMessage($0, for: directory) })
    }
}

struct CommitMessageEditor: View {
    static let height: CGFloat = 96
    /// The conventional subject width. Longer subjects get a hint, never a block.
    static let subjectLengthLimit = 72

    @AppStorage(PreferenceKey.disableCommitOperations.rawValue) private var disableCommitOperations = false

    var folder: WorkspaceEntry
    @Binding var commitMessage: String
    @Binding var cachedDiffStat: DiffStat?
    @Binding var error: Error?
    @Binding var cachedDiffRaw: String
    @State private var focused = false
    @State private var snippetFocusRequest: UUID?
    @State private var isCommitting = false
    @State private var amend = false
    @State private var prefilledAmendMessage: String?
    @Environment(\.isEnabled) private var isEnabled
    var onCommit: () -> Void

    private var subjectLength: Int {
        commitMessage.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first?.count ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            MultilineTextEditor(text: $commitMessage, isFocused: $focused, drawsBackground: false,
                                placeholder: amend ? LocalizedStringKey("Amend Commit Message") : "Commit Message",
                                accessibilityIdentifier: "commitMessageEditor")
                .overlay(alignment: .topTrailing) {
                    if subjectLength > Self.subjectLengthLimit {
                        Text(verbatim: "\(subjectLength)/\(Self.subjectLengthLimit)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.bar, in: Capsule())
                            .padding(.top, 6)
                            .padding(.trailing, 14)
                            .help("The first line is longer than \(Self.subjectLengthLimit) characters. Many tools truncate longer subjects.")
                            .accessibilityLabel(Text("Subject is \(subjectLength) characters long"))
                            .accessibilityIdentifier("commitSubjectLengthHint")
                            .allowsHitTesting(true)
                    }
                }
            HStack(spacing: 12) {
                CommitMessageSnippetSuggestionView(onSelect: insertSnippet)
                    .font(.callout)
                diffStat
                Toggle("Amend", isOn: $amend)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(disableCommitOperations || isCommitting)
                    .help("Amend the last commit with the staged changes and this message")
                    .accessibilityIdentifier("amendCommitToggle")
                if isCommitting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(amend ? LocalizedStringKey("Amending…") : "Committing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("commitProgress")
                }
                Button(amend ? LocalizedStringKey("Amend") : "Commit", action: commitChanges)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canCommit)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
        }
        .focusedSceneValue(\.editorMenu, menuActions)
        .onChange(of: amend) { _, isOn in toggleAmend(isOn) }
        .onChange(of: disableCommitOperations) { _, disabled in if disabled { amend = false } }
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

    private var diffStat: some View {
        let files = cachedDiffStat?.files.count
        let insertions = cachedDiffStat?.insertionsTotal
        let deletions = cachedDiffStat?.deletionsTotal
        return HStack(spacing: 8) {
            Label(files?.formatted() ?? "-", systemImage: "doc")
                .help("Files Changed")
                .accessibilityLabel(Text("Files Changed"))
                .accessibilityValue(Text(verbatim: files?.formatted() ?? "-"))
            Label(insertions?.formatted() ?? "-", systemImage: "plus")
                .help("Insertions")
                .accessibilityLabel(Text("Insertions"))
                .accessibilityValue(Text(verbatim: insertions?.formatted() ?? "-"))
            Label(deletions?.formatted() ?? "-", systemImage: "minus")
                .help("Deletions")
                .accessibilityLabel(Text("Deletions"))
                .accessibilityValue(Text(verbatim: deletions?.formatted() ?? "-"))
        }
        .font(.caption)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Staged Changes"))
    }

    private var canCommit: Bool {
        !disableCommitOperations && isEnabled && !isCommitting && (amend || !cachedDiffRaw.isEmpty)
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var menuActions: MenuActions {
        var actions = MenuActions()
        actions.isEditingText = focused
        if canCommit { actions[.commit] = commitChanges }
        return actions
    }

    private func insertSnippet(_ snippet: String) {
        commitMessage = CommitMessageSnippet.applying(snippet, to: commitMessage)
        focused = false
        snippetFocusRequest = UUID()
    }

    private func toggleAmend(_ isOn: Bool) {
        if !isOn {
            // Only take back the message this toggle put in, never text the user typed.
            if let prefilled = prefilledAmendMessage, commitMessage == prefilled { commitMessage = "" }
            prefilledAmendMessage = nil
            return
        }
        guard commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            do {
                try CommitOperations.requireEnabled()
                let message = try await GitRuntime.run(GitHeadMessage(directory: folder.url))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard amend, commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                commitMessage = message
                prefilledAmendMessage = message
            } catch {
                amend = false
                self.error = OperationFailure("Amend Last Commit", error)
            }
        }
    }

    private func commitChanges() {
        guard canCommit else { return }
        isCommitting = true
        let isAmending = amend
        Task {
            defer { isCommitting = false }
            do {
                try CommitOperations.requireEnabled()
                try await GitRuntime.run(GitCommit(directory: folder.url, message: commitMessage, amend: isAmending))
                // The draft is cleared only once Git accepted it, so a failing hook keeps the text.
                commitMessage = ""
                CommitDraftStore.shared.clear(for: folder.url)
                prefilledAmendMessage = nil
                amend = false
                onCommit()
            } catch { self.error = OperationFailure(isAmending ? "Amend Last Commit" : "Commit", error) }
        }
    }
}
