import FoldGitCore
import SwiftUI

struct AmendCommitSheet: View {
    @AppStorage(PreferenceKey.disableCommitOperations.rawValue) private var disableCommitOperations = false
    var folder: WorkspaceEntry
    @Binding var showingAmendCommitAt: Commit?
    var onCreate: (() -> Void)
    @State private var message = ""
    @State private var error: Error?
    @State private var isWorking = false

    var body: some View {
        VStack {
            Text("Amend Commit with a New Message")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading) {
                HStack {
                    MultilineTextEditor(text: $message, bordered: true)
                        .frame(height: 100)
                        .disabled(isWorking)
                }
                HStack {
                    Button("Cancel") {
                        showingAmendCommitAt = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                    Spacer()
                    if isWorking { ProgressView().controlSize(.small) }
                    Button("Amend") {
                        guard !isWorking else { return }
                        isWorking = true
                        Task {
                            defer { isWorking = false }
                            do {
                                try CommitOperations.requireEnabled()
                                try await GitRuntime.run(
                                    GitCommit(directory: folder.url, message: message, amend: true)
                                )
                                onCreate()
                                showingAmendCommitAt = nil
                            } catch {
                                self.error = error
                            }
                        }
                    }
                    .disabled(message.isEmpty || disableCommitOperations || isWorking)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.init(.return))
                }
                .padding(.top)
            }
            .frame(minWidth: 440, idealWidth: 520, maxWidth: 680)
            .padding()
        }
        .padding()
        .cornerRadius(8)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            message = showingAmendCommitAt?.rawBody ?? ""
        }
        .errorSheet($error, operation: "Amend Last Commit")
    }
}

struct SquashCommitSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PreferenceKey.disableCommitOperations.rawValue) private var disabled = false
    let directory: URL
    let hashes: Set<String>
    var onComplete: (String) -> Void
    @State private var plan: SquashPlan?
    @State private var message = ""
    @State private var diagnostic: String?
    /// Preparing only reads and fetches, so it can be cancelled by closing the sheet; executing cannot.
    @State private var preparing = false
    @State private var executing = false
    @State private var confirmingSquash = false

    private var busy: Bool { preparing || executing }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Squash Commits").font(.headline)
            if let plan {
                Text(verbatim: plan.branch).font(.subheadline).foregroundStyle(.secondary)
                Text("The selected commits will become one commit.")
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.commits) { commit in
                            Text(verbatim: String(commit.hash.prefix(7)) + "  " + commit.title)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120)
                if plan.followingCount > 0 {
                    Text("Later commits will be recreated with new hashes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Commit Message").font(.subheadline)
                MultilineTextEditor(text: $message, bordered: true, accessibilityIdentifier: "squashCommitMessage")
                    .frame(height: 220)
                    .disabled(busy)
            }
            if busy { ProgressView() }
            if let diagnostic { Text(verbatim: diagnostic).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(executing)
                Spacer()
                Button("Squash") { confirmingSquash = true }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(busy || disabled || plan == nil || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(executing)
        .confirmationDialog("Squash the selected commits?", isPresented: $confirmingSquash, titleVisibility: .visible) {
            Button("Squash", role: .destructive) { Task { await execute() } }
                .disabled(disabled || busy || plan == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This rewrites local commit history. The selected commits will be replaced by one commit.")
        }
        .task {
            preparing = true
            defer { preparing = false }
            do {
                try CommitOperations.requireEnabled()
                let prepared = try await GitSquash.prepare(in: directory, hashes: hashes)
                plan = prepared; message = prepared.message
            } catch is CancellationError {
            } catch { diagnostic = error.localizedDescription }
        }
        .onChange(of: disabled) { _, value in if value && !executing { confirmingSquash = false; dismiss() } }
    }

    private func execute() async {
        guard let plan, !busy else { return }
        executing = true; diagnostic = nil
        defer { executing = false }
        do {
            try CommitOperations.requireEnabled()
            let hash = try await GitSquash.execute(plan, message: message, in: directory)
            onComplete(hash); dismiss()
        } catch { diagnostic = error.localizedDescription; self.plan = nil }
    }
}
