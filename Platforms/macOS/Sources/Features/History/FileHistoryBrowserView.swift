import FoldGitCore
import SwiftUI

struct RepositoryFileTreeView: View {
    @Bindable var store: FileHistoryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var scrolledRevealRequest: UUID?
    /// Folders can be selected for keyboard navigation; only files drive the detail pane.
    @State private var selectedDirectory: String?
    @State private var openError: Error?

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
            ScrollViewReader { proxy in
                List(selection: treeSelection) {
                    ForEach(store.rows) { row in
                        if row.isDirectory {
                            HStack(spacing: 6) {
                                Button {
                                    store.toggleDirectory(row.path)
                                } label: {
                                    Image(systemName: store.isDirectoryCollapsed(row.path) ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold)).frame(width: 12)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(store.isDirectoryCollapsed(row.path) ? "Expand" : "Collapse")
                                .accessibilityLabel(store.isDirectoryCollapsed(row.path) ? Text("Expand") : Text("Collapse"))
                                Label { Text(verbatim: row.name) } icon: {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, CGFloat(row.depth) * 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .tag(row.id)
                            .help(row.path)
                            .accessibilityElement(children: .combine)
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
                            .tag(row.id)
                            .help(row.path)
                            .accessibilityIdentifier("historyFile-" + row.path)
                        }
                    }
                }
                .contextMenu(forSelectionType: ChangeFileTree.Row.ID.self) { ids in
                    if ids.count == 1, let row = row(for: ids.first) {
                        if !row.isDirectory {
                            Button("Open") { open(row) }
                            Divider()
                        }
                        Button("Show in Finder") { revealInFinder(row) }
                        Divider()
                        Button("Copy Path") { copy(row.path) }
                        Button("Copy Full Path") { if let url = url(for: row) { copy(url.path) } }
                    }
                } primaryAction: { ids in
                    // Double-click or Return: folders expand or collapse, files open in their default app.
                    guard ids.count == 1, let row = row(for: ids.first) else { return }
                    if row.isDirectory { store.toggleDirectory(row.path) } else { open(row) }
                }
                .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                    handleArrow(press.key == .rightArrow) ? .handled : .ignored
                }
                .accessibilityIdentifier("repositoryFileTree")
                .overlay {
                    if store.rows.isEmpty {
                        if store.isLoadingFiles { ProgressView().controlSize(.small) }
                        else { Text(store.searchText.isEmpty ? String(localized: "No Files") : String(localized: "No Results")).foregroundStyle(.secondary) }
                    }
                }
                .onAppear { scrollToRevealedFile(using: proxy) }
                .onChange(of: store.revealRequest) { scrollToRevealedFile(using: proxy) }
                .onChange(of: store.rows) { scrollToRevealedFile(using: proxy) }
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
        .errorSheet($openError, operation: "Open File")
        .onAppear { searchText = store.searchText }
        .onChange(of: store.searchText) { _, value in
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines) != value { searchText = value }
        }
    }

    private var treeSelection: Binding<ChangeFileTree.Row.ID?> {
        Binding {
            if let selectedDirectory, store.rows.contains(where: { $0.id == .directory(selectedDirectory) }) {
                return .directory(selectedDirectory)
            }
            guard let path = store.selectedPath else { return nil }
            return store.rows.first { !$0.isDirectory && $0.path == path }?.id
        } set: { id in
            guard let row = row(for: id) else { return }
            if row.isDirectory {
                selectedDirectory = row.path
            } else {
                selectedDirectory = nil
                store.selectFile(row.path)
            }
        }
    }

    private func row(for id: ChangeFileTree.Row.ID?) -> ChangeFileTree.Row? {
        guard let id else { return nil }
        return store.rows.first { $0.id == id }
    }

    /// Right expands a folder or steps into it; Left collapses a folder or steps out to the parent.
    private func handleArrow(_ isRight: Bool) -> Bool {
        guard let current = row(for: treeSelection.wrappedValue),
              let offset = store.rows.firstIndex(where: { $0.id == current.id }) else { return false }
        let collapsed = current.isDirectory && store.isDirectoryCollapsed(current.path)
        if isRight {
            guard current.isDirectory else { return false }
            if collapsed {
                store.toggleDirectory(current.path)
            } else if store.rows.indices.contains(offset + 1), store.rows[offset + 1].depth > current.depth {
                treeSelection.wrappedValue = store.rows[offset + 1].id
            }
            return true
        }
        if current.isDirectory && !collapsed {
            store.toggleDirectory(current.path)
            return true
        }
        let parent = (current.path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, store.rows.contains(where: { $0.id == .directory(parent) }) else { return false }
        treeSelection.wrappedValue = .directory(parent)
        return true
    }

    private func url(for row: ChangeFileTree.Row) -> URL? {
        store.directory?.appending(path: row.path, directoryHint: row.isDirectory ? .isDirectory : .notDirectory)
    }

    private func open(_ row: ChangeFileTree.Row) {
        guard let url = url(for: row) else { return }
        openError = FileOpening.open(url, using: NSWorkspace.shared.open)
    }

    private func revealInFinder(_ row: ChangeFileTree.Row) {
        guard let url = url(for: row) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func scrollToRevealedFile(using proxy: ScrollViewProxy) {
        guard let request = store.revealRequest, request != scrolledRevealRequest,
              let path = store.selectedPath,
              let row = store.rows.first(where: { $0.path == path && !$0.isDirectory }) else { return }
        proxy.scrollTo(row.id, anchor: .center)
        scrolledRevealRequest = request
    }
}

struct FileHistoryDetailView: View {
    @Bindable var store: FileHistoryStore
    @State private var findRequest: UUID?

    var body: some View {
        Group {
            if let path = store.selectedPath {
                VStack(spacing: 0) {
                    HStack {
                        Picker("File View", selection: Binding(get: { store.detailMode }, set: store.selectDetailMode)) {
                            Text("Commit History").tag(RepositoryFileDetailMode.history)
                            Text("File Content").tag(RepositoryFileDetailMode.content)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("fileDetailModePicker")
                        Spacer()
                        if store.detailMode == .content {
                            Button("Find in File", systemImage: "magnifyingglass") { findRequest = UUID() }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .disabled(!hasText)
                                .help("Find in File")
                            if let metadata = store.content.metadata {
                                Text(verbatim: ByteCountFormatter.string(fromByteCount: metadata.size, countStyle: .file))
                                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            }
                            OpenFileButton(filePath: path)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(.bar)
                    switch store.detailMode {
                    case .history:
                        FileHistoryRecordsView(store: store)
                    case .content:
                        FileContentView(store: store.content, path: path, findRequest: findRequest)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass",
                                       description: store.detailMode == .history
                                           ? Text("Select a file to view its commit history.")
                                           : Text("Select a file to view its complete content."))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusedSceneValue(\.fileMenu, fileMenu)
    }

    private var hasText: Bool {
        if case .text(let document) = store.content.state { return !document.text.isEmpty }
        return false
    }

    private var fileMenu: MenuActions? {
        guard store.detailMode == .content, hasText else { return nil }
        var actions = MenuActions()
        actions[.findInFile] = { findRequest = UUID() }
        return actions
    }
}

private struct FileHistoryRecordsView: View {
    @Bindable var store: FileHistoryStore

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

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
                                    .contextMenu {
                                        Button("Copy Commit Hash") { Self.copy(entry.commit.hash) }
                                        Button("Copy Commit Message") { Self.copy(entry.commit.rawBody) }
                                    }
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
    @AppStorage(PreferenceKey.diffFileExpansion.rawValue) private var fileExpansion = AppPreferences.defaultDiffFileExpansion
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
                        .environment(\.diffFileContext, DiffFileContext(
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
            // Follows the expansion preference like commit and stash diffs; large or generated files start collapsed.
            files = patch.map {
                DiffLoading.expandable($0.fileDiffs, rawLineCount: DiffLoading.lineCount($0.raw),
                                       prefersExpanded: fileExpansion.isExpanded)
            } ?? []
        }
    }
}
