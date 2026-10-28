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
    @State private var worktrees = WorktreeStore()
    @AppStorage(PreferenceKey.showWorktreeInformation.rawValue)
    private var showWorktreeInformation = PreferenceDefaults.showWorktreeInformation
    @AppStorage(PreferenceKey.repositoryWorktreeVisibility.rawValue)
    private var worktreePreferencesData = PreferenceDefaults.repositoryWorktreeVisibility
    @SceneStorage("selectedRepositoryPath") private var sceneRepositoryPath = ""
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
    @State private var selectionLog: Log?
    @State private var subSelectionLogID: String?
    @State private var folderIsRefresh = false
    @State private var error: Error?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var expandAllFiles: UUID?
    @State private var collapseAllFiles: UUID?
    @AppStorage(PreferenceKey.sidebarDates.rawValue) private var sidebarDatesData = PreferenceDefaults.sidebarDates
    @State private var sidebarDatesCache = DecodedPreference { SidebarDates.decode($0 ?? Data()) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebarView(folders: Binding(get: { decodedFolders }, set: persistFolders),
                               selection: $selectionFolderURL, onError: { error = $0 })
            .frame(width: Self.sidebarWidth)
            .navigationSplitViewColumnWidth(min: Self.sidebarWidth, ideal: Self.sidebarWidth, max: Self.sidebarWidth)
            .toolbar(removing: .title)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItem(id: "workspaceSidebar", placement: .automatic) {
                    Button("Sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                    .help(columnVisibility == .all ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar"))
                }
            }
        } content: {
            Group {
                if let folder = selectionFolder {
                    RepositoryScreen(
                        folder: folder,
                        selectionLog: $selectionLog,
                        subSelectionLogID: $subSelectionLogID,
                        isRefresh: $folderIsRefresh
                    )
                    .id(folder)
                } else {
                    Text("No Folder Selection")
                        .foregroundColor(.secondary)
                }
            }
            .background(WorkspaceColumnConfiguration(historyWidth: Self.historyColumnWidth, sidebarWidth: Self.sidebarWidth))
            .navigationSplitViewColumnWidth(min: 320, ideal: Self.historyColumnWidth, max: 640)
        } detail: {
            if let selectionLog, let subSelectionLogID {
                CommitDiffView(selectionLogID: selectionLog.id, subSelectionLogID: subSelectionLogID)
            } else if let selectionFolder {
                switch selectionLog {
                case .notCommitted:
                    CommitCreateView(
                        folder: selectionFolder,
                        isRefresh: $folderIsRefresh,
                        onCommit: {
                            self.selectionLog = nil
                            folderIsRefresh = true
                        },
                        onStash: {
                            self.selectionLog = nil
                            folderIsRefresh = true
                        }
                    )
                case .committed(let commit):
                    CommitDetailStackView(commit: commit, folder: selectionFolder)
                case nil:
                    Text("No Selection")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .title)
        .frame(minWidth: 900, minHeight: 420)
        .onAppear {
            AppDelegate.applyAppearance()
            guard restoreSession, selectionFolderURL == nil else { return }
            let path = sceneRepositoryPath.isEmpty ? lastRepositoryPath : sceneRepositoryPath
            let url = URL(fileURLWithPath: path)
            selectionFolderURL = decodedFolders.flatMap(\.repositories).first { $0.url.path == path }?.url
            if selectionFolderURL == nil, !path.isEmpty {
                Task {
                    await worktrees.refreshRepositories(decodedFolders.flatMap(\.repositories).map(\.url))
                    if selectionFolderURL == nil, worktrees.contains(url) { selectionFolderURL = url }
                }
            }
        }
        .onChange(of: appearance) { AppDelegate.applyAppearance() }
        .onChange(of: selectionFolderURL) {
            guard restoreSession else { return }
            sceneRepositoryPath = selectionFolderURL?.path ?? ""
            lastRepositoryPath = sceneRepositoryPath
        }
        .onChange(of: restoreSession) {
            if !restoreSession {
                sceneRepositoryPath = ""
                lastRepositoryPath = ""
            }
        }
        .onChange(of: decodedFolders) {
            if selectionFolder == nil { selectionFolderURL = nil }
        }
        .onChange(of: selectionFolder, {
            selectionLog = nil
        })
        .errorSheet($error)
        .environment(worktrees)
        .environment(\.worktreeVisibility, worktrees.visibility(for: selectionFolderURL, showInformation: worktrees.showsInformation(for: selectionFolderURL, global: showWorktreeInformation,
                preferences: worktreePreferencesCache.value(for: worktreePreferencesData))))
        .environment(\.openWorktree, OpenWorktreeAction { url in selectionFolderURL = url.standardizedFileURL.resolvingSymlinksInPath() })
        .environment(\.folder, selectionFolder?.url)
        .environment(\.expandAllFiles, expandAllFiles)
        .environment(\.collapseAllFiles, collapseAllFiles)
        .focusedSceneValue(\.workspaceMenu, menuContext)
    }

    private var menuContext: WorkspaceMenuContext {
        var actions = MenuActions()
        actions[.toggleSidebar] = toggleSidebar
        if selectionFolder != nil {
            actions[.expandAll] = { expandAllFiles = UUID() }
            actions[.collapseAll] = { collapseAllFiles = UUID() }
        }
        let dates = sidebarDatesCache.value(for: sidebarDatesData)
        let recent = decodedFolders.flatMap(\.repositories)
            .filter { dates.opened[$0.identity.path] != nil }
            .sorted { (dates.opened[$0.identity.path] ?? .distantPast) > (dates.opened[$1.identity.path] ?? .distantPast) }
        return WorkspaceMenuContext(actions: actions, recentRepositories: Array(recent.prefix(10)),
                                    openRecent: { selectionFolderURL = $0 })
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
