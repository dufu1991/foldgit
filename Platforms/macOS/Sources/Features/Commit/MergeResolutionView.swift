import AppKit
import FoldGitCore
import SwiftUI

struct MergeResolutionSheet: View {
    let directory: URL
    @Environment(\.dismiss) private var dismiss
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MergeResolutionContent(directory: directory, onFinished: { dismiss() }, onAborted: { dismiss() }, onBusyChanged: { isBusy = $0 })
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isBusy)
            }
        }
        .padding(24).frame(width: 760).interactiveDismissDisabled(isBusy)
    }
}

struct MergeResolutionContent: View {
    let directory: URL
    let onFinished: () -> Void
    let onAborted: () -> Void
    let onBusyChanged: (Bool) -> Void
    @State private var model: MergeResolutionModel
    @State private var selectedPath: String?
    @State private var pendingResolution: FileResolutionRequest?
    @State private var showingAbort = false
    @State private var targetPreview = ""
    @State private var incomingPreview = ""
    @State private var previewError: String?
    @State private var isLoadingPreview = false

    init(directory: URL, onFinished: @escaping () -> Void, onAborted: @escaping () -> Void,
         onBusyChanged: @escaping (Bool) -> Void = { _ in }) {
        self.directory = directory
        self.onFinished = onFinished
        self.onAborted = onAborted
        self.onBusyChanged = onBusyChanged
        _model = State(initialValue: MergeResolutionModel(directory: directory))
    }

    private var conflict: GitMergeConflict? { model.state?.conflicts.first { $0.path == selectedPath } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Resolve Merge", systemImage: "arrow.trianglehead.merge").font(.headline)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .labelStyle(.iconOnly).disabled(model.isBusy)
            }
            Text(directory.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .truncationMode(.middle).textSelection(.enabled)
            if model.state?.isMerging == true {
                if model.state?.conflicts.isEmpty == false {
                    Text("Choose a file to compare both versions. Edit it externally or keep one version, then continue the merge.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    List(selection: $selectedPath) {
                        ForEach(model.state?.conflicts ?? []) { item in
                            Label(item.path, systemImage: "exclamationmark.triangle")
                                .lineLimit(1).truncationMode(.middle).help(item.path).tag(item.path)
                        }
                    }
                    .listStyle(.inset).frame(height: 110).disabled(model.isBusy)
                    if let conflict {
                        HStack(alignment: .top, spacing: 12) {
                            preview(title: "Target Branch Version", text: targetPreview)
                            preview(title: "Incoming Branch Version", text: incomingPreview)
                        }
                        .frame(height: 180)
                        if isLoadingPreview { ProgressView().controlSize(.small) }
                        if let previewError { Text(previewError).font(.caption).foregroundStyle(.red).lineLimit(3) }
                        ViewThatFits(in: .horizontal) {
                            HStack { resolutionActions(conflict) }
                            VStack(alignment: .leading, spacing: 8) { resolutionActions(conflict) }
                        }
                        .disabled(model.isBusy)
                    }
                } else {
                    Label("All Conflicts Resolved", systemImage: "checkmark.circle").foregroundStyle(.green)
                    if model.state?.hasUnstagedChanges == true {
                        Text("Stage remaining changes in the commit view before continuing.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Continue to create the merge commit, including when the resolved result has no file changes.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button("Abort Merge", role: .destructive) { showingAbort = true }
                    Spacer()
                    Button("Continue Merge") {
                        Task { if await model.continueMerge() { onFinished() } }
                    }
                    .buttonStyle(.borderedProminent).disabled(model.state?.canContinue != true || model.isBusy)
                }
                .disabled(model.isBusy)
            } else if model.state != nil {
                Label("No Merge in Progress", systemImage: "checkmark.circle")
                Button("Return to Workflow", action: onFinished)
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.refresh() }
        .onChange(of: model.isBusy, initial: true) { onBusyChanged(model.isBusy) }
        .onDisappear { onBusyChanged(false) }
        .onChange(of: model.state?.conflicts, initial: true) {
            if !(model.state?.conflicts.contains { $0.path == selectedPath } ?? false) {
                selectedPath = model.state?.conflicts.first?.path
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .task(id: selectedPath) { await loadPreview() }
        .confirmationDialog("Replace File Resolution?", isPresented: Binding(
            get: { pendingResolution != nil }, set: { if !$0 { pendingResolution = nil } }
        ), presenting: pendingResolution) { request in
            Button("Apply Resolution", role: .destructive) {
                Task { await model.resolve(request.path, choosing: request.resolution) }
            }
        } message: { request in
            Text("This replaces your current edits for \(request.path) with the selected version, or deletes the file if that version removed it.")
        }
        .confirmationDialog("Abort Merge?", isPresented: $showingAbort) {
            Button("Abort Merge", role: .destructive) {
                Task { if await model.abort() { onAborted() } }
            }
        } message: {
            Text("Git will return this worktree to its pre-merge state. Conflict-resolution edits will be discarded. Source branch commits are kept.")
        }
    }

    @ViewBuilder
    private func resolutionActions(_ conflict: GitMergeConflict) -> some View {
        Button("Open File", systemImage: "arrow.up.forward.app") {
            let file = directory.appendingPathComponent(conflict.path)
            if !NSWorkspace.shared.open(file) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
        Button("Mark Resolved", systemImage: "checkmark") {
            Task { await model.resolve(conflict.path, choosing: .edited) }
        }
        Menu("Keep Version") {
            Button("Use Target Version") { pendingResolution = FileResolutionRequest(path: conflict.path, resolution: .target) }
            Button("Use Incoming Version") { pendingResolution = FileResolutionRequest(path: conflict.path, resolution: .incoming) }
            Divider()
            Button("Delete File", role: .destructive) { pendingResolution = FileResolutionRequest(path: conflict.path, resolution: .delete) }
        }
    }

    private func preview(title: LocalizedStringKey, text: String) -> some View {
        GroupBox(title) {
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadPreview() async {
        guard let conflict else { return }
        let path = conflict.path
        isLoadingPreview = true
        targetPreview = ""
        incomingPreview = ""
        previewError = nil
        defer { isLoadingPreview = false }
        do {
            let target = try await readVersion(path: path, exists: conflict.targetExists, stage: 2)
            let incoming = try await readVersion(path: path, exists: conflict.incomingExists, stage: 3)
            guard !Task.isCancelled, selectedPath == path else { return }
            targetPreview = target
            incomingPreview = incoming
        } catch {
            guard !Task.isCancelled else { return }
            previewError = error.localizedDescription
        }
    }

    private func readVersion(path: String, exists: Bool, stage: Int) async throws -> String {
        guard exists else { return String(localized: "File Deleted in This Version") }
        guard let data = try await GitFileContent.read(at: directory, path: path, version: .blob(":\(stage):\(path)")) else { return "" }
        guard let text = String(data: data, encoding: .utf8), !data.contains(0) else { return String(localized: "Binary File — Open Externally") }
        return text.count > 32_000 ? String(text.prefix(32_000)) + "\n…" : text
    }
}

private struct FileResolutionRequest {
    let path: String
    let resolution: MergeResolution
}
