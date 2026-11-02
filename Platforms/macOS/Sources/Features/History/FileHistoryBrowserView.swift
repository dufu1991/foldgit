import FoldGitCore
import SwiftUI

struct RepositoryFileTreeView: View {
    @Bindable var store: FileHistoryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NativeSearchField(text: $searchText, placeholder: String(localized: "Search Files"),
                                  accessibilityIdentifier: "fileHistorySearch") { text, composing in
                    if !composing { store.search(text) }
                }
                .frame(height: 26)
                Button("Collapse All Folders", systemImage: "rectangle.compress.vertical", action: store.collapseDirectories)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Collapse All Folders")
                    .accessibilityIdentifier("collapseHistoryDirectories")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            List(selection: Binding(get: { store.selectedPath }, set: { path in
                if let path, store.rows.contains(where: { $0.path == path && !$0.isDirectory }) { store.selectFile(path) }
            })) {
                ForEach(store.rows) { row in
                    if row.isDirectory {
                        Button {
                            store.toggleDirectory(row.path)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: store.isDirectoryCollapsed(row.path) ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold)).frame(width: 12)
                                Label { Text(verbatim: row.name) } icon: {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, CGFloat(row.depth) * 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("historyDirectory-" + row.path)
                        .accessibilityValue(store.isDirectoryCollapsed(row.path) ? Text("Collapsed") : Text("Expanded"))
                    } else {
                        HStack(spacing: 6) {
                            Image(nsImage: FileIconTheme.bundled.image(filePath: row.path, isDark: colorScheme == .dark))
                                .resizable().scaledToFit().frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                            Text(verbatim: row.name).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.leading, CGFloat(row.depth) * 16 + 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(row.path)
                        .help(row.path)
                        .accessibilityIdentifier("historyFile-" + row.path)
                    }
                }
            }
            .overlay {
                if store.rows.isEmpty {
                    if store.isLoadingFiles { ProgressView().controlSize(.small) }
                    else { Text(store.searchText.isEmpty ? String(localized: "No Files") : String(localized: "No Results")).foregroundStyle(.secondary) }
                }
            }
            HStack {
                if store.isLoadingFiles { ProgressView().controlSize(.small) }
                Spacer()
                Text("Files: \(store.fileCount.formatted(.number))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Total files in this worktree, including tracked and non-ignored untracked files. Excludes folders and does not change when searching.")
                    .accessibilityIdentifier("repositoryFileCount")
                Spacer()
            }
            .font(.callout)
            .frame(height: 40)
            .background(.bar)
        }
        .onAppear { searchText = store.searchText }
        .onChange(of: store.searchText) { _, value in
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines) != value { searchText = value }
        }
    }
}

struct FileHistoryDetailView: View {
    @Bindable var store: FileHistoryStore
    @State private var showingHistory = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let path = store.selectedPath {
                    HStack {
                        Text(verbatim: path).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(path)
                        Spacer()
                        Button("Commit History", systemImage: "clock.arrow.circlepath") {
                            store.selectDetailMode(.history)
                            showingHistory = true
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("showFileCommitHistory")
                    }
                }
            }
            .padding(12).background(.bar)
            if let path = store.selectedPath {
                FileContentView(store: store.content, path: path)
            } else {
                ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Select a file to view its complete content."))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { store.selectDetailMode(.content) }
        .sheet(isPresented: $showingHistory, onDismiss: { store.selectDetailMode(.content) }) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File History").font(.headline)
                        if let path = store.selectedPath { Text(verbatim: path).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Done") { showingHistory = false }.keyboardShortcut(.cancelAction)
                }
                .padding(12)
                Divider()
                FileHistoryRecordsView(store: store)
            }
            .frame(minWidth: 800, minHeight: 560)
        }
    }
}

private struct FileHistoryRecordsView: View {
    @Bindable var store: FileHistoryStore

    var body: some View {
        Group {
            if store.selectedPath != nil {
                VSplitView {
                    VStack(spacing: 0) {
                        List(selection: Binding(get: { store.selectedEntry?.id }, set: { id in
                            if let entry = store.entries.first(where: { $0.id == id }) { store.selectCommit(entry) }
                        })) {
                            ForEach(store.entries) { entry in
                                CommitSummaryView(commit: entry.commit, isSelected: store.selectedEntry?.id == entry.id)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .accessibilityElement(children: .combine)
                                    .tag(entry.id)
                                    .accessibilityIdentifier("fileHistoryCommit-" + entry.id)
                            }
                            if store.canLoadMore {
                                Button("Load More", action: store.loadMore)
                                    .disabled(store.isLoadingHistory)
                                    .accessibilityIdentifier("fileHistoryLoadMore")
                            }
                        }
                        .overlay {
                            if store.entries.isEmpty && !store.isLoadingHistory {
                                Text("No Commit History").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(minHeight: 130, idealHeight: 230)

                    FileHistoryPatchView(store: store)
                        .frame(minHeight: 180, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Select a file to view its commit history."))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .errorSheet($store.error, operation: "File History")
    }
}

private struct FileHistoryPatchView: View {
    var store: FileHistoryStore
    @State private var files: [ExpandableModel<FileDiff>] = []

    var body: some View {
        VStack(spacing: 0) {
            if let entry = store.selectedEntry {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: entry.commit.title).font(.headline).textSelection(.enabled)
                    if !entry.commit.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(verbatim: entry.commit.body.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    }
                    CommitMetadataView(commit: entry.commit)
                        .font(.caption)
                    if entry.commit.parentHashes.count > 1 {
                        Text("Compared with the first parent").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.bar)
            }
            if store.isLoadingDiff {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let patch = store.diff, let entry = store.selectedEntry {
                ScrollView {
                    if patch.fileDiffs.isEmpty { Text("No Changes").foregroundStyle(.secondary).padding() }
                    FileDiffsView(expandableFileDiffs: $files)
                        .padding(.horizontal, 12)
                        .environment(\.imageDiffContext, ImageDiffContext(
                            old: entry.commit.parentHashes.first.map { .revision($0) } ?? .absent,
                            new: .revision(entry.commit.hash)))
                }
                .scrollEdgeEffectStyle(.hard, for: .vertical)
                HStack {
                    DiffDisplayControls(onExpandAll: { files = files.settingExpansion(true) },
                                        onCollapseAll: { files = files.settingExpansion(false) })
                    Spacer()
                    Text(GitSummary.describe(DiffStat(diff: patch))).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).frame(minHeight: 40).background(.bar)
            } else {
                Text("No Selection").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: store.diff, initial: true) { _, patch in
            files = patch?.fileDiffs.map { ExpandableModel(isExpanded: true, model: $0) } ?? []
        }
    }
}
