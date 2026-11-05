import FoldGitCore
import SwiftUI

struct StashChangedContentView: View {
    @AppStorage(PreferenceKey.diffFileExpansion.rawValue) private var fileExpansion = AppPreferences.defaultDiffFileExpansion
    
    var folder: WorkspaceEntry
    @Binding var showingStashChanged: Bool
    var stashList: [StashListEntry]?
    var onTapDropButton: ((StashListEntry) -> Void)?
    @State private var selectionStashID: Int?
    @State private var fileDiffs: [ExpandableModel<FileDiff>] = []
    @State private var isLoadingDiff = false
    @State private var isWorking = false
    @State private var droppingStash: StashListEntry?
    @State private var error: Error?
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectionStashID) {
                Text("Stashed Changes")
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(2)
                if let stashList {
                    if stashList.isEmpty {
                        Text("No Content")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        ForEach(stashList) { stash in
                            StashRow(stash: stash)
                                .tag(stash.index)
                                .contextMenu {
                                    Button("Apply") { run(.apply, stash.index) }
                                    Button("Pop") { run(.pop, stash.index) }
                                    Divider()
                                    Button("Drop", role: .destructive) { droppingStash = stash }
                                }
                                .disabled(isWorking)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            Group {
                if selectionStashID != nil && isLoadingDiff && fileDiffs.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if selectionStashID != nil {
                    ScrollView {
                        VStack(spacing: 0) {
                            StashChangedDetailContentView(fileDiffs: $fileDiffs)
                                .environment(\.folder, folder.url)
                                .environment(\.imageDiffContext, selectionStashID.map {
                                    ImageDiffContext(old: .revision("stash@{\($0)}^1"), new: .revision("stash@{\($0)}"))
                                })
                            Spacer(minLength: 0)
                        }
                    }
                    .scrollEdgeEffectStyle(.hard, for: .vertical)
                } else {
                    Text("No Selection")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaBar(edge: .bottom, content: {
                VStack (spacing: 0) {
                    PixelDivider()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            displayControls
                            Spacer(minLength: 12)
                            stashActions
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 10) {
                            displayControls
                            HStack {
                                Spacer()
                                stashActions
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding()
                }
            })
        }
        .background(Color(NSColor.textBackgroundColor))
        .task(id: selectionStashID, {
            await updateDiff()
        })
        .presentationSizing(.fitted)
        .frame(
            minWidth: 650,
            idealWidth: 800,
            maxWidth: .infinity,
            minHeight: 500,
            idealHeight: 700,
            maxHeight: .infinity
        )
        .confirmationDialog("Drop Stash?", isPresented: Binding(
            get: { droppingStash != nil }, set: { if !$0 { droppingStash = nil } }
        ), titleVisibility: .visible, presenting: droppingStash) { stash in
            Button("Drop Stash", role: .destructive) {
                onTapDropButton?(stash)
                if selectionStashID == stash.index { selectionStashID = nil }
            }
            Button("Cancel", role: .cancel) { }
        } message: { stash in
            Text("The stashed changes “\(stash.message)” will be permanently removed.")
        }
        .errorSheet($error, operation: "Load Stash Changes")
    }

    private var displayControls: some View {
        DiffDisplayControls(onExpandAll: {
            fileDiffs = fileDiffs.settingExpansion(true)
        }, onCollapseAll: {
            fileDiffs = fileDiffs.settingExpansion(false)
        })
    }

    private var stashActions: some View {
        HStack(spacing: 8) {
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { showingStashChanged = false }
                .keyboardShortcut(.cancelAction)
            Button("Drop") {
                droppingStash = stashList?.first { $0.index == selectionStashID }
            }
            .disabled(selectionStashID == nil || isWorking)
            Button("Pop") {
                if let index = selectionStashID { run(.pop, index) }
            }
            .help("Apply the stash and remove it from the stash list")
            .disabled(selectionStashID == nil || isWorking)
            Button("Apply") {
                if let index = selectionStashID { run(.apply, index) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.init(.defaultAction))
            .help("Apply the stash and keep it in the stash list")
            .disabled(selectionStashID == nil || isWorking)
        }
        .fixedSize()
    }

    private enum StashOperation { case apply, pop }

    /// Applies or pops once; the busy state blocks repeated submits while Git runs.
    private func run(_ operation: StashOperation, _ index: Int) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                switch operation {
                case .apply: try await GitRuntime.run(GitStashApply(directory: folder.url, index: index))
                case .pop: try await GitRuntime.run(GitStashPop(directory: folder.url, index: index))
                }
                showingStashChanged = false
            } catch {
                self.error = operation == .apply
                    ? OperationFailure("Apply Stash", error) : OperationFailure("Pop Stash", error)
            }
        }
    }

    private func updateDiff() async {
        guard let index = selectionStashID else {
            fileDiffs = []
            return
        }
        isLoadingDiff = true
        fileDiffs = []
        defer { isLoadingDiff = false }
        do {
            let raw = try await GitRuntime.run(GitStashShowDiff(directory: folder.url, index: index))
            let diffs = try await DiffLoading.expandableFileDiffs(raw: raw, preference: fileExpansion)
            try Task.checkCancellation()
            fileDiffs = diffs
        } catch {
            guard !Task.isCancelled else { return }
            self.error = OperationFailure("Load Stash Changes", error)
        }
    }
    

}

private struct StashRow: View {
    var stash: StashListEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: stash.message.isEmpty ? "stash@{\(stash.index)}" : stash.message)
                .lineLimit(3)
            HStack(spacing: 6) {
                if let branch = stash.branch {
                    Label { Text(verbatim: branch) } icon: { Image(systemName: "arrow.triangle.branch") }
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let date = stash.date {
                    Text(date, format: .relative(presentation: .named))
                        .lineLimit(1)
                        .help(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    @Previewable @State var showingStashChanged = false
    return StashChangedContentView(folder: .init(url: URL(string: "file:///tmp/FoldGit/")!), showingStashChanged: $showingStashChanged)
}
