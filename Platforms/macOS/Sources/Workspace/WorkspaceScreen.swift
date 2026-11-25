import AppKit
import FoldGitCore
import QuartzCore
import SwiftUI

struct WorkspaceScreen: View {
    private static let sidebarWidth: CGFloat = 260
    private static let historyColumnWidth: CGFloat = 400
    @AppStorage(PreferenceKey.folder.rawValue) var folders: Data?
    @Environment(\.appearsActive) private var appearsActive
    @State private var folderCache = DecodedPreference<[WorkspaceEntry]> { data in
        data.flatMap { try? JSONDecoder().decode([WorkspaceEntry].self, from: $0) } ?? []
    }
    @State private var worktreePreferencesCache = DecodedPreference { RepositoryWorktreePreferences.decode($0 ?? Data()) }
    private var decodedFolders: [WorkspaceEntry] { folderCache.value(for: folders) }
    @State private var selectionFolderURL: URL?
    @State private var repositoryTabs = WorkspaceRepositoryTabs()
    @State private var didRestoreWorkspace = false
    @State private var worktrees = WorktreeStore()
    @AppStorage(PreferenceKey.showWorktreeInformation.rawValue)
    private var showWorktreeInformation = PreferenceDefaults.showWorktreeInformation
    @AppStorage(PreferenceKey.repositoryWorktreeVisibility.rawValue)
    private var worktreePreferencesData = PreferenceDefaults.repositoryWorktreeVisibility
    @SceneStorage("selectedRepositoryPath") private var sceneRepositoryPath = ""
    @SceneStorage("repositoryTabs") private var savedTabLayouts: Data?
    @AppStorage(PreferenceKey.lastSelectedRepository.rawValue) private var lastRepositoryPath = ""
    @AppStorage(PreferenceKey.restoreSession.rawValue) private var restoreSession = true
    @AppStorage(PreferenceKey.appAppearance.rawValue) private var appearance = AppAppearance.automatic
    private var selectionFolder: WorkspaceEntry? {
        guard let selectionFolderURL = selectionFolderURL else { return nil}
        let repositories = decodedFolders.flatMap(\.repositories)
        if let saved = repositories.first(where: { $0.url == selectionFolderURL }) { return saved }
        let identity = RepositoryLocation.canonical(selectionFolderURL)
        let isRelated = repositories.contains { entry in worktrees.list(for: entry.url).contains { $0.id == identity } }
        return isRelated ? WorkspaceEntry(url: selectionFolderURL) : nil
    }
    private var selectedTabs: RepositoryTabs? { selectionFolder.flatMap { repositoryTabs.tabs(for: $0.identity.path) } }
    private var repositoryHeaderHeight: CGFloat { selectedTabs == nil ? 0 : RepositoryTabBar.height }
    @State private var error: Error?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var expandAllFiles: UUID?
    @State private var collapseAllFiles: UUID?
    @State private var showCommandLog = false
    @State private var sidebarRequest: SidebarRequest?
    @State private var commandLogSelection: UUID?
    @AppStorage(PreferenceKey.sidebarDates.rawValue) private var sidebarDatesData = PreferenceDefaults.sidebarDates
    @State private var sidebarDatesCache = DecodedPreference { SidebarDates.decode($0 ?? Data()) }

    private var workspaceSplitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebarView(folders: Binding(get: { decodedFolders }, set: persistFolders),
                               selection: Binding(get: { selectionFolderURL }, set: { selectRepository($0) }),
                               onError: { error = $0 }, request: $sidebarRequest)
            .frame(width: Self.sidebarWidth)
            .navigationSplitViewColumnWidth(min: Self.sidebarWidth, ideal: Self.sidebarWidth, max: Self.sidebarWidth)
            .toolbar(removing: .title)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItem(id: "workspaceSidebar", placement: .automatic) {
                    Button("Sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                    .immediateHelp(columnVisibility == .all ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar"))
                }
            }
        } content: {
            Group {
                if let folder = selectionFolder, let tabs = selectedTabs {
                    @Bindable var tab = tabs.selected
                    RepositoryScreen(
                        folder: folder,
                        selectionLog: $tab.selectionLog,
                        subSelectionLogID: $tab.subSelectionLogID,
                        isRefresh: $tab.isRefresh,
                        browseMode: $tab.mode,
                        fileHistory: tab.fileHistory,
                        onBranchChange: { tabs.branch = $0 },
                        session: tab.session
                    )
                    .id(tab.id)
                } else {
                    ContentUnavailableView {
                        Label("No Repository Selected", systemImage: "folder")
                    } description: {
                        Text(decodedFolders.isEmpty
                             ? LocalizedStringKey("Add a Git repository or a folder containing multiple repositories.")
                             : "Select a repository in the sidebar.")
                    } actions: {
                        Button("Open Repository") { sidebarRequest = SidebarRequest(kind: .open) }
                            .accessibilityIdentifier("emptyStateOpenRepository")
                        Button("Clone Remote Repository") { sidebarRequest = SidebarRequest(kind: .clone) }
                            .accessibilityIdentifier("emptyStateCloneRepository")
                    }
                }
            }
            .padding(.top, repositoryHeaderHeight)
            .background(WorkspaceColumnConfiguration(historyWidth: Self.historyColumnWidth, sidebarWidth: Self.sidebarWidth))
            .navigationSplitViewColumnWidth(min: 320, ideal: Self.historyColumnWidth, max: 640)
        } detail: {
            Group {
                if let folder = selectionFolder, let tab = selectedTabs?.selected {
                    repositoryDetail(folder, tab: tab).id(tab.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                Divider().allowsHitTesting(false)
            }
            .padding(.top, repositoryHeaderHeight)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .title)
    }

    var body: some View {
        workspaceSplitView.overlay(alignment: .top) {
            if let tabs = selectedTabs {
                RepositoryTabBar(tabs: tabs)
                    .padding(.leading, columnVisibility == .all ? Self.sidebarWidth : 0)
            }
        }
        .overlay {
            if let folder = selectionFolder {
                CommandLogOverlay(directory: folder.url, isPresented: $showCommandLog, selectedID: $commandLogSelection)
                    .id(folder.url)
            }
        }
        .frame(minWidth: 900, minHeight: 420)
        .onAppear {
            AppDelegate.applyAppearance()
            restoreWorkspace()
        }
        .onChange(of: appearance) { AppDelegate.applyAppearance() }
        .onChange(of: selectionFolderURL) {
            showCommandLog = false
            commandLogSelection = nil
            rememberActiveRepository()
        }
        .onChange(of: repositoryTabs.layouts) { _, layouts in
            if restoreSession { savedTabLayouts = try? JSONEncoder().encode(layouts) }
        }
        .onChange(of: appearsActive) { if appearsActive { rememberActiveRepository() } }
        .onChange(of: restoreSession) {
            if !restoreSession {
                sceneRepositoryPath = ""
                savedTabLayouts = nil
                lastRepositoryPath = ""
            } else {
                savedTabLayouts = try? JSONEncoder().encode(repositoryTabs.layouts)
                rememberActiveRepository()
            }
        }
        .onChange(of: decodedFolders) { old, new in
            // Forget the tabs of repositories removed from the sidebar so saved layouts do not accumulate.
            let remaining = Set(new.flatMap(\.repositories).map(\.identity.path))
            repositoryTabs.remove(Set(old.flatMap(\.repositories).map(\.identity.path)).subtracting(remaining))
            if selectionFolder == nil { selectionFolderURL = nil }
        }
        .errorSheet($error, operation: "Save Workspace")
        .environment(worktrees)
        .environment(\.worktreeVisibility, worktrees.visibility(for: selectionFolderURL, showInformation: worktrees.showsInformation(for: selectionFolderURL, global: showWorktreeInformation,
                preferences: worktreePreferencesCache.value(for: worktreePreferencesData))))
        .environment(\.openWorktree, OpenWorktreeAction { url in selectRepository(RepositoryLocation.canonical(url)) })
        .environment(\.folder, selectionFolder?.url)
        .environment(\.openWorkspaceFile, openWorkspaceFile)
        .environment(\.expandAllFiles, expandAllFiles)
        .environment(\.collapseAllFiles, collapseAllFiles)
        .environment(\.toggleCommandLog, ToggleCommandLogAction {
            commandLogSelection = nil
            showCommandLog.toggle()
        })
        .environment(\.openCommandLog, selectionFolder == nil ? nil : OpenCommandLogAction { id in
            commandLogSelection = id
            showCommandLog = true
        })
        .focusedSceneValue(\.workspaceMenu, menuContext)
    }

    @ViewBuilder private func repositoryDetail(_ folder: WorkspaceEntry, tab: RepositoryTab) -> some View {
        @Bindable var tab = tab
        if tab.mode == .files {
            FileHistoryDetailView(store: tab.fileHistory)
        } else if let selectionLog = tab.selectionLog, let subSelectionLogID = tab.subSelectionLogID {
            CommitDiffView(selectionLogID: selectionLog.id, subSelectionLogID: subSelectionLogID)
        } else {
            switch tab.selectionLog {
            case .notCommitted:
                CommitCreateView(folder: folder, isRefresh: $tab.isRefresh, onCommit: {
                    tab.selectionLog = nil
                    tab.isRefresh = true
                }, onStash: { tab.isRefresh = true })
            case .committed(let commit):
                CommitDetailStackView(commit: commit, folder: folder)
            case nil:
                ContentUnavailableView {
                    Label("Select a Commit", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Choose a commit or the working changes in the history list to see its details.")
                }
            }
        }
    }

    private func restoreWorkspace() {
        guard !didRestoreWorkspace else { return }
        didRestoreWorkspace = true
        guard restoreSession, selectionFolderURL == nil else { return }
        if let savedTabLayouts, let layouts = try? JSONDecoder().decode([String: RepositoryTabs.Layout].self, from: savedTabLayouts) {
            repositoryTabs.restore(layouts)
        }
        let path = sceneRepositoryPath.isEmpty ? lastRepositoryPath : sceneRepositoryPath
        guard !path.isEmpty else { return }
        let repositories = decodedFolders.flatMap(\.repositories)
        if let repository = repositories.first(where: { $0.url.path == path }) {
            selectRepository(repository.url)
        } else {
            let url = URL(fileURLWithPath: path)
            Task { @MainActor in
                await worktrees.refreshRepositories(repositories.map(\.url))
                if restoreSession, selectionFolderURL == nil, worktrees.contains(url) {
                    selectRepository(url)
                }
            }
        }
    }

    private func selectRepository(_ url: URL?) {
        if let url { repositoryTabs.open(RepositoryLocation.key(for: url), mode: AppPreferences.initialRepositoryView()) }
        selectionFolderURL = url
    }

    private func rememberActiveRepository() {
        guard restoreSession else { return }
        sceneRepositoryPath = selectionFolderURL?.path ?? ""
        if appearsActive, let selectionFolderURL { lastRepositoryPath = selectionFolderURL.path }
    }

    private var openWorkspaceFile: OpenWorkspaceFileAction? {
        guard let folder = selectionFolder, let tab = selectedTabs?.selected else { return nil }
        return OpenWorkspaceFileAction(directory: folder.url) { path in
            tab.mode = .files
            tab.fileHistory.activate(in: folder.url)
            tab.fileHistory.selectDetailMode(.content)
            tab.fileHistory.revealFile(path)
        }
    }

    private var menuContext: WorkspaceMenuContext {
        var actions = MenuActions()
        actions[.toggleSidebar] = toggleSidebar
        if let tabs = selectedTabs {
            actions[.newTab] = { tabs.add(mode: AppPreferences.initialRepositoryView()) }
            if tabs.canClose {
                actions[.closeTab] = { tabs.closeSelected() }
                actions[.previousTab] = { tabs.move(by: -1) }
                actions[.nextTab] = { tabs.move(by: 1) }
            }
            actions[.toggleCommandLog] = { showCommandLog.toggle() }
            actions[.expandAll] = { expandAllFiles = UUID() }
            actions[.collapseAll] = { collapseAllFiles = UUID() }
        }
        let dates = sidebarDatesCache.value(for: sidebarDatesData)
        let recent = decodedFolders.flatMap(\.repositories)
            .filter { dates.opened[$0.identity.path] != nil }
            .sorted { (dates.opened[$0.identity.path] ?? .distantPast) > (dates.opened[$1.identity.path] ?? .distantPast) }
        return WorkspaceMenuContext(actions: actions, recentRepositories: Array(recent.prefix(10)),
                                    openRecent: { selectRepository($0) })
    }

    private func toggleSidebar() {
        columnVisibility = columnVisibility == .all ? .doubleColumn : .all
    }

    private func persistFolders(_ folders: [WorkspaceEntry]) {
        do {
            try self.folders = JSONEncoder().encode(folders)
            AutoFetchScheduler.shared.reload()
        } catch {
            self.error = error
        }
    }
}

@MainActor @Observable final class WorkspaceRepositoryTabs {
    /// Repositories whose loaded history and file state stay in memory. Older ones keep only their tab layout.
    static let loadedRepositoryLimit = 3
    /// Repositories whose tab layout is remembered.
    static let layoutLimit = 50

    private var groups: [String: RepositoryTabs] = [:]
    /// Most recently opened first.
    @ObservationIgnored private var recent: [String] = []

    var layouts: [String: RepositoryTabs.Layout] { groups.mapValues(\.layout) }

    func tabs(for repository: String) -> RepositoryTabs? { groups[repository] }

    /// Opens a repository with Commit View and Directory View tabs, selecting the given view the first time.
    func open(_ repository: String, mode: RepositoryBrowseMode) {
        if groups[repository] == nil {
            groups[repository] = RepositoryTabs(layout: .init(modes: [.commits, .files], selectedIndex: mode == .files ? 1 : 0))
        }
        recent.removeAll { $0 == repository }
        recent.insert(repository, at: 0)
        for key in recent.dropFirst(Self.layoutLimit) { groups[key] = nil }
        recent = Array(recent.prefix(Self.layoutLimit))
        for key in recent.dropFirst(Self.loadedRepositoryLimit) {
            if let tabs = groups[key], tabs.isLoaded { groups[key] = RepositoryTabs(layout: tabs.layout) }
        }
    }

    func restore(_ layouts: [String: RepositoryTabs.Layout]) {
        let kept = layouts.keys.sorted().prefix(Self.layoutLimit)
        groups = Dictionary(uniqueKeysWithValues: kept.map { ($0, RepositoryTabs(layout: layouts[$0]!)) })
        recent = Array(kept)
    }

    func remove(_ repositories: Set<String>) {
        guard !repositories.isEmpty else { return }
        for key in repositories { groups[key] = nil }
        recent.removeAll(where: repositories.contains)
    }
}

@MainActor @Observable final class RepositoryTabs {
    struct Layout: Codable, Equatable {
        var modes: [RepositoryBrowseMode]
        var selectedIndex: Int
    }

    private(set) var items: [RepositoryTab]
    private(set) var selectedIndex: Int
    var branch: Branch?
    var selected: RepositoryTab { items[selectedIndex] }
    var canClose: Bool { items.count > 1 }
    var layout: Layout { Layout(modes: items.map(\.mode), selectedIndex: selectedIndex) }
    /// Whether any tab has created its repository state.
    var isLoaded: Bool { items.contains(where: \.isLoaded) }

    init(layout: Layout) {
        let modes = layout.modes.isEmpty ? [.commits, .files] : layout.modes
        items = modes.map { RepositoryTab(mode: $0) }
        selectedIndex = min(max(layout.selectedIndex, 0), modes.count - 1)
    }

    func title(for tab: RepositoryTab) -> String {
        guard let branch else { return tab.mode.title }
        let branchName = branch.isDetached ? "\(String(localized: "Detached HEAD")) \(branch.point)" : branch.name
        return "\(branchName) · \(tab.mode.title)"
    }

    func select(_ tab: RepositoryTab) {
        if let index = items.firstIndex(where: { $0.id == tab.id }) { selectedIndex = index }
    }

    func add(mode: RepositoryBrowseMode) {
        items.append(RepositoryTab(mode: mode))
        selectedIndex = items.count - 1
    }

    func close(_ tab: RepositoryTab) {
        guard canClose, let index = items.firstIndex(where: { $0.id == tab.id }) else { return }
        let selectedID = selected.id
        items.remove(at: index)
        selectedIndex = items.firstIndex(where: { $0.id == selectedID }) ?? min(index, items.count - 1)
    }

    @discardableResult func closeSelected() -> Bool {
        guard canClose else { return false }
        close(selected)
        return true
    }

    func move(by offset: Int) {
        selectedIndex = (selectedIndex + offset % items.count + items.count) % items.count
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        let commands: [MenuCommand] = [.newTab, .closeTab, .previousTab, .nextTab]
        switch commands.first(where: { $0.shortcut?.matches(event) == true }) {
        case .newTab:
            if !event.isARepeat { add(mode: AppPreferences.initialRepositoryView()) }
            return true
        case .closeTab:
            return event.isARepeat || closeSelected()
        case .previousTab where canClose:
            move(by: -1)
            return true
        case .nextTab where canClose:
            move(by: 1)
            return true
        default:
            return false
        }
    }
}

@MainActor @Observable final class RepositoryTab: Identifiable {
    let id = UUID()
    var mode: RepositoryBrowseMode
    var selectionLog: Log?
    var subSelectionLogID: String?
    var isRefresh = false
    @ObservationIgnored private var loadedFileHistory: FileHistoryStore?
    @ObservationIgnored private var loadedSession: RepositorySession?
    var isLoaded: Bool { loadedFileHistory != nil || loadedSession != nil }

    var fileHistory: FileHistoryStore {
        if let loadedFileHistory { return loadedFileHistory }
        let store = FileHistoryStore()
        loadedFileHistory = store
        return store
    }

    var session: RepositorySession {
        if let loadedSession { return loadedSession }
        let session = RepositorySession()
        loadedSession = session
        return session
    }

    init(mode: RepositoryBrowseMode) { self.mode = mode }
}

private struct RepositoryTabBar: View {
    static let height: CGFloat = 36
    let tabs: RepositoryTabs
    @State private var hoveredTab: UUID?
    private let tabSpacing: CGFloat = 4

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: tabSpacing) {
                        ForEach(tabs.items) { tab in
                            tabButton(tab)
                                .containerRelativeFrame(.horizontal) { width, _ in
                                    let gaps = CGFloat(tabs.items.count - 1) * tabSpacing
                                    return max(148, (width - gaps) / CGFloat(tabs.items.count))
                                }
                                .id(tab.id)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: tabs.selected.id, initial: true) { _, id in proxy.scrollTo(id) }
            }
            Button { tabs.add(mode: AppPreferences.initialRepositoryView()) } label: {
                Image(systemName: "plus")
                    .font(.callout.weight(.medium))
                    .frame(width: 28, height: 28)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: Circle())
                    .overlay { Circle().strokeBorder(.quaternary, lineWidth: 1).allowsHitTesting(false) }
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("New Tab"))
            .accessibilityIdentifier("newRepositoryTab")
            .help(Text("New Tab"))
        }
        .padding(.horizontal, 9)
        .frame(height: Self.height)
        .background(.bar, ignoresSafeAreaEdges: [])
        .background(RepositoryTabShortcuts(tabs: tabs))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tabs"))
        .accessibilityIdentifier("repositoryTabBar")
    }

    private func tabButton(_ tab: RepositoryTab) -> some View {
        let isSelected = tab.id == tabs.selected.id
        let isHovered = hoveredTab == tab.id
        let title = tabs.title(for: tab)
        return ZStack(alignment: .leading) {
            Button { tabs.select(tab) } label: {
                Text(verbatim: title)
                    .font(.callout.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, tabs.canClose ? 27 : 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityIdentifier("repositoryTab")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(Text(verbatim: title))
            if tabs.canClose && (isSelected || isHovered) {
                Button { tabs.close(tab) } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 22)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .padding(.leading, 5)
                .accessibilityLabel(Text("Close Tab"))
                .help(Text("Close Tab"))
            }
        }
        .background {
            Capsule().fill(isSelected ? Color(nsColor: .controlBackgroundColor).opacity(0.85)
                           : Color.primary.opacity(isHovered ? 0.05 : 0))
        }
        .overlay {
            if isSelected {
                Capsule().strokeBorder(.quaternary, lineWidth: 1).allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            if hovering { hoveredTab = tab.id }
            else if hoveredTab == tab.id { hoveredTab = nil }
        }
    }
}

/// Route repository tab shortcuts before AppKit handles window closing or focus traversal.
private struct RepositoryTabShortcuts: NSViewRepresentable {
    let tabs: RepositoryTabs

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.tabs = tabs }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stopMonitoring() }

    final class MonitorView: NSView {
        var tabs: RepositoryTabs?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window, (event.window ?? NSApp.keyWindow) === window,
                      window.attachedSheet == nil, tabs?.handleShortcut(event) == true else { return event }
                return nil
            }
        }

        func stopMonitoring() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

private struct WorkspaceColumnConfiguration: NSViewRepresentable {
    var historyWidth: CGFloat
    var sidebarWidth: CGFloat

    func makeNSView(context: Context) -> WorkspaceColumnLayoutView {
        let view = WorkspaceColumnLayoutView()
        view.defaultWidth = historyWidth
        view.sidebarWidth = sidebarWidth
        return view
    }

    func updateNSView(_ view: WorkspaceColumnLayoutView, context: Context) {
        view.defaultWidth = historyWidth
        view.sidebarWidth = sidebarWidth
        view.lockSidebarWidth()
    }

    static func dismantleNSView(_ view: WorkspaceColumnLayoutView, coordinator: ()) {
        view.stopMonitoring()
    }
}

private final class WorkspaceColumnLayoutView: NSView {
    var defaultWidth: CGFloat = 400
    var sidebarWidth: CGFloat = 260
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        lockSidebarWidth()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.resetWidth(for: event) else { return event }
            return nil
        }
    }

    override func layout() {
        super.layout()
        lockSidebarWidth()
    }

    func lockSidebarWidth() {
        var child: NSView = self
        while let parent = child.superview {
            if let splitView = parent as? NSSplitView,
               let controller = splitView.delegate as? NSSplitViewController,
               let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) {
                if sidebar.minimumThickness != sidebarWidth {
                    sidebar.minimumThickness = sidebarWidth
                }
                if sidebar.maximumThickness != sidebarWidth {
                    sidebar.maximumThickness = sidebarWidth
                }
                sidebar.canCollapse = false
                clipToolbarDivider(in: splitView, column: child)
                return
            }
            child = parent
        }
    }

    private func clipToolbarDivider(in splitView: NSSplitView, column: NSView) {
        guard let window, splitView.isVertical,
              let index = splitView.arrangedSubviews.firstIndex(of: column),
              index < splitView.arrangedSubviews.count - 1 else { return }
        let dividerRect = NSRect(x: column.frame.maxX, y: splitView.bounds.minY,
                                 width: splitView.dividerThickness, height: splitView.bounds.height)
        // Full-height split dividers can draw behind the toolbar on macOS 26.
        for divider in splitView.subviews where !splitView.arrangedSubviews.contains(divider)
            && divider.frame.width <= splitView.dividerThickness + 4
            && divider.frame.intersects(dividerRect) {
            let contentRect = divider.convert(window.contentLayoutRect, from: nil).intersection(divider.bounds)
            divider.wantsLayer = true
            let mask = CAShapeLayer()
            mask.frame = divider.bounds
            mask.path = CGPath(rect: contentRect, transform: nil)
            divider.layer?.mask = mask
        }
    }

    func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func resetWidth(for event: NSEvent) -> Bool {
        guard event.clickCount == 2, let window, event.window === window else { return false }
        var child: NSView = self
        while let parent = child.superview {
            if let splitView = parent as? NSSplitView, splitView.isVertical,
               let index = splitView.arrangedSubviews.firstIndex(of: child), index < splitView.arrangedSubviews.count - 1,
               !splitView.isSubviewCollapsed(child) {
                let divider = NSRect(x: child.frame.maxX, y: splitView.bounds.minY,
                                     width: splitView.dividerThickness, height: splitView.bounds.height)
                let location = splitView.convert(event.locationInWindow, from: nil)
                if divider.insetBy(dx: -3, dy: 0).contains(location) {
                    // The pane wrapper can extend under the sidebar; measure the visible column.
                    let position = convert(bounds, to: splitView).minX + defaultWidth
                    let minimum = splitView.minPossiblePositionOfDivider(at: index)
                    let maximum = splitView.maxPossiblePositionOfDivider(at: index)
                    splitView.setPosition(min(max(position, minimum), maximum), ofDividerAt: index)
                    return true
                }
            }
            child = parent
        }
        return false
    }
}

#Preview {
    WorkspaceScreen()
}
