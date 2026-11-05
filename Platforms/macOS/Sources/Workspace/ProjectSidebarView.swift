import FoldGitCore
import SwiftUI

struct ProjectSidebarView: View {
    @AppStorage(PreferenceKey.disableCommitOperations.rawValue) private var disableCommitOperations = false
    @AppStorage(PreferenceKey.repositoryDisplayNames.rawValue)
    private var displayNamesData = PreferenceDefaults.repositoryDisplayNames
    @AppStorage(PreferenceKey.sidebarSort.rawValue) private var sort = SidebarSort.manual
    @AppStorage(PreferenceKey.sidebarSortAscending.rawValue) private var ascending = true
    @AppStorage(PreferenceKey.sidebarDates.rawValue) private var datesData = PreferenceDefaults.sidebarDates
    @AppStorage(PreferenceKey.showWorktreeInformation.rawValue)
    private var globalShowWorktreeInformation = PreferenceDefaults.showWorktreeInformation
    @AppStorage(PreferenceKey.repositoryWorktreeVisibility.rawValue)
    private var worktreePreferencesData = PreferenceDefaults.repositoryWorktreeVisibility
    @AppStorage(PreferenceKey.showWorktreeStatus.rawValue) private var showWorktreeStatus = PreferenceDefaults.showWorktreeStatus
    @AppStorage(PreferenceKey.showRepositoryBranch.rawValue)
    private var showRepositoryBranch = PreferenceDefaults.showRepositoryBranch
    @Binding var folders: [WorkspaceEntry]
    @Binding var selection: URL?
    let onError: (Error) -> Void
    /// Lets the window's empty state ask the sidebar to add or clone a repository.
    var request: Binding<SidebarRequest?> = .constant(nil)
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(WorktreeStore.self) private var worktrees
    @State private var finishingWorktree: WorktreeSheetTarget?
    @State private var creatingWorktree: WorktreeSheetTarget?
    @State private var managingWorktrees: WorktreeSheetTarget?
    @State private var cleaningWorktrees: WorktreeSheetTarget?
    @State private var collapsedWorktrees: Set<URL> = []
    @State private var collapsedGroups: Set<URL> = []
    @State private var expandedInfrequentGroups: Set<URL> = []
    @State private var isAdding = false
    @State private var repositoryToName: RepositoryNamingTarget?
    @State private var search = ""
    @State private var cloneParent: CloneParent?
    @State private var groupDraft: RepositoryGroupDraft?
    @State private var groupToRename: GroupNamingTarget?
    @State private var selectedRepositories: Set<URL> = []
    @State private var modificationDates: [String: Date] = [:]
    @State private var changedRepositories: Set<String> = []
    @State private var missingRepositories: Set<URL> = []
    @State private var pendingRemoval: [WorkspaceEntry] = []
    @State private var displayNamesCache = DecodedPreference { RepositoryDisplayNames.decode($0 ?? Data()) }
    @State private var datesCache = DecodedPreference { SidebarDates.decode($0 ?? Data()) }
    @State private var worktreePreferencesCache = DecodedPreference { RepositoryWorktreePreferences.decode($0 ?? Data()) }
    private let activity = RepositoryActivity()
    private let discovery = MacRepositoryDiscovery.make()
    private var refreshEnabled: Bool { appearsActive && scenePhase == .active }

    private var organization: SidebarOrganization {
        SidebarOrganization(folders: folders, names: displayNames, query: search, sort: sort,
                            ascending: ascending, dates: sidebarDates, modified: modificationDates, worktrees: worktrees.families.filter { showsWorktreeInformation(for: $0.key) })
    }

    private var worktreePreferences: RepositoryWorktreePreferences {
        worktreePreferencesCache.value(for: worktreePreferencesData)
    }

    private var sidebarDates: SidebarDates { datesCache.value(for: datesData) }

    private func showsWorktreeInformation(for url: URL) -> Bool {
        worktrees.showsInformation(for: url, global: globalShowWorktreeInformation, preferences: worktreePreferences)
    }

    private var displayNames: RepositoryDisplayNames {
        displayNamesCache.value(for: displayNamesData)
    }

    var body: some View {
        sidebarContent
        .focusedSceneValue(\.sidebarMenu, menuActions)
        .sheet(item: $finishingWorktree) { target in
            WorktreeCompletionSheet(source: target.url) { source, destination in
                relocateWorktree(source, nil, fallback: destination)
            }
        }
        .sheet(item: $creatingWorktree) { target in
            WorktreeCreateSheet(repository: target.url)
        }
        .sheet(item: $managingWorktrees) { target in
            WorktreeManagementSheet(repository: target.url) { old, destination in
                relocateWorktree(old, destination, fallback: target.url)
            }
        }
        .sheet(item: $cleaningWorktrees) { target in
            WorktreeCleanupSheet(repository: target.url) { removed in
                relocateWorktree(removed, nil, fallback: target.url)
            }
        }
        .sheet(item: $repositoryToName) { target in
            RepositoryDisplayNameSheet(
                repository: target.repository,
                name: displayNames.displayName(for: target.repository)
            ) { name in
                saveDisplayName(name, for: target.repository)
            }
        }
        .sheet(item: $cloneParent) { parent in
            RepositoryCloneSheet(parent: parent.url) { url in
                let repository = WorkspaceEntry(url: url)
                addEntry(repository)
                search = ""
                selection = repository.url
            }
        }
        .sheet(item: $groupDraft) { draft in
            RepositoryGroupEditor(draft: draft, folders: folders, names: displayNames) { name, members in
                folders = WorkspaceGroups.savingGroup(id: draft.groupID, name: name, repositories: members, in: folders)
                if let group = folders.first(where: { !$0.isRepository && $0.displayName == name.trimmingCharacters(in: .whitespacesAndNewlines) && (draft.groupID == nil || $0.identity == draft.groupID) }) {
                    collapsedGroups.remove(group.identity)
                }
                search = ""
                groupDraft = nil
            }
        }
        .sheet(item: $groupToRename) { target in
            RepositoryGroupNameSheet(name: target.group.displayName) { name in
                folders = WorkspaceGroups.renamingGroup(target.group.identity, to: name, in: folders)
                groupToRename = nil
            }
        }
        .onAppear {
            recordAddedDates()
            if let selection { selectedRepositories = [selection] }
        }
        .onChange(of: folders) {
            recordAddedDates()
            let available = Set(folders.flatMap(\.repositories).map(\.url))
            selectedRepositories.formIntersection(available.union(worktrees.families.keys))
        }
        .onChange(of: selection) {
            guard let selection else { return }
            if !selectedRepositories.contains(selection) { selectedRepositories = [selection] }
            for tree in worktrees.list(for: selection) { collapsedWorktrees.remove(tree.id) }
            var dates = sidebarDates
            dates.opened[WorkspaceEntry(url: selection).identity.path] = .now
            saveDates(dates)
        }
        .task(id: WorktreeRefreshID(paths: folders.flatMap(\.repositories).map(\.identity), enabled: refreshEnabled)) {
            guard refreshEnabled else {
                await worktrees.refreshRepositories(folders.flatMap(\.repositories).map(\.url).filter { worktrees.list(for: $0).isEmpty })
                return
            }
            await worktrees.refreshRepositories(folders.flatMap(\.repositories).map(\.url))
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await worktrees.refreshRepositories(folders.flatMap(\.repositories).map(\.url))
                await refreshWorktreeStatuses()
            }
        }
        .task(id: WorktreeStatusMonitorID(paths: statusFamilies.flatMap { $0.map(\.url.path) },
                                          enabled: refreshEnabled && showWorktreeStatus)) {
            guard refreshEnabled && showWorktreeStatus else { return }
            await worktrees.monitorStatuses(statusFamilies)
        }
        .task(id: WorktreeStatusMonitorID(paths: branchFamilies.flatMap { $0.map(\.url.path) },
                                          enabled: refreshEnabled && showRepositoryBranch)) {
            guard refreshEnabled && showRepositoryBranch else { return }
            await worktrees.monitorBranches(branchFamilies)
        }
        .onChange(of: sort) { ascending = sort == .name || sort == .manual }
        .onChange(of: request.wrappedValue) { _, value in
            guard let value else { return }
            request.wrappedValue = nil
            switch value.kind {
            case .open: chooseDirectory()
            case .clone: chooseCloneDirectory()
            }
        }
        // File checks run when the list or window activity changes, never while rendering rows.
        .task(id: WorktreeRefreshID(paths: folders.flatMap(\.repositories).map(\.identity), enabled: refreshEnabled)) {
            refreshMissingRepositories()
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { !pendingRemoval.isEmpty },
                                                               set: { if !$0 { pendingRemoval = [] } }),
                            titleVisibility: .visible) {
            Button("Remove from Sidebar", role: .destructive) {
                removeFromSidebar(pendingRemoval)
                pendingRemoval = []
            }
            Button("Cancel", role: .cancel) { pendingRemoval = [] }
        } message: {
            Text("The folders stay on disk. You can undo this with Edit > Undo.")
        }
        .task(id: ModificationRefreshID(paths: folders.flatMap(\.repositories).map(\.identity),
                                       enabled: appearsActive && sort == .recentlyModified)) {
            guard appearsActive && sort == .recentlyModified else { return }
            let repositories = folders.flatMap(\.repositories)
            // Every repository is scanned once; afterwards only repositories with file events are rescanned.
            changedRepositories = Set(repositories.map(\.identity.path))
            let changes = RepositoryChangeMonitor.changes(in: Array(changedRepositories))
            let listener = Task { for await paths in changes { changedRepositories.formUnion(paths) } }
            defer { listener.cancel() }
            while !Task.isCancelled {
                let due = repositories.filter { changedRepositories.contains($0.identity.path) }
                changedRepositories.subtract(due.map(\.identity.path))
                for repository in due {
                    guard !Task.isCancelled else { return }
                    await activity.invalidate(repository.url)
                    let date = try? await activity.modificationDate(at: repository.url)
                    guard !Task.isCancelled else { return }
                    modificationDates[repository.identity.path] = date
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Worktree families of repositories with worktrees enabled, each listed once.
    private var statusFamilies: [[GitWorktree]] {
        var seen: Set<URL> = []
        return folders.flatMap(\.repositories).compactMap { repository in
            guard showsWorktreeInformation(for: repository.url) else { return nil }
            let trees = worktrees.list(for: repository.url)
            guard let first = trees.first, seen.insert(first.id).inserted else { return nil }
            return trees
        }
    }

    private func refreshWorktreeStatuses() async {
        guard showWorktreeStatus else { return }
        await worktrees.statuses.refresh(statusFamilies)
    }

    private var branchFamilies: [[GitWorktree]] {
        var seen: Set<URL> = []
        return folders.flatMap(\.repositories).compactMap { repository in
            guard !showsWorktreeInformation(for: repository.url) else { return nil }
            let trees = worktrees.list(for: repository.url)
            guard let first = trees.first, seen.insert(first.id).inserted else { return nil }
            return trees
        }
    }

    private var sidebarContent: some View {
        // Rows share one projection per update instead of rebuilding it for each repository.
        let context = SidebarRowContext(organization: organization, saved: folders.flatMap(\.repositories))
        let entries = context.organization.entries
        return List(selection: sidebarSelection) {
            ForEach(entries, id: \.url.absoluteString) { folder in
                if let children = folder.children {
                    groupRow(folder, children: children, context: context)
                } else {
                    repositoryRow(folder, context: context)
                }
            }
            .onMove { source, destination in
                moveFolders(from: source, to: destination)
            }
            .moveDisabled(!context.organization.canMove)
        }
        .listStyle(.sidebar)
        .onDeleteCommand { requestRemoval(actionRepositories()) }
        .scrollEdgeEffectHidden(true, for: .top)
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
        .overlay {
            if folders.isEmpty {
                ContentUnavailableView {
                    Label("No Project Folder Added", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a Git repository or a folder containing multiple repositories.")
                }
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Directories or Repositories", systemImage: "magnifyingglass")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            NativeSearchField(text: $search, placeholder: String(localized: "Search Repositories"),
                              accessibilityIdentifier: "sidebarSearchField")
                .frame(height: 26)
                .immediateHelp(String(localized: "Search Repositories"))
            Menu {
                Picker("Sort Repositories", selection: $sort) {
                    ForEach(SidebarSort.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                if sort != .manual {
                    Divider()
                    Picker("Sort Direction", selection: $ascending) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").frame(width: 24, height: 26)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .immediateHelp(String(localized: "Sort Repositories"))
            .accessibilityLabel(Text("Sort Repositories"))
            Menu {
                Button("New Group", systemImage: "folder.badge.plus") {
                    beginNewGroup(with: [])
                }
                Divider()
                Button("Add Local Repository or Directory", systemImage: "folder.badge.plus", action: chooseDirectory)
                Button("Clone Remote Repository", systemImage: "square.and.arrow.down", action: chooseCloneDirectory)
                if let selection, showsWorktreeInformation(for: selection) {
                    Divider()
                    Button("New Worktree", systemImage: "square.stack.3d.up") {
                        creatingWorktree = WorktreeSheetTarget(url: selection)
                    }
                    Button("Manage Worktrees", systemImage: "square.stack.3d.up") {
                        managingWorktrees = WorktreeSheetTarget(url: worktrees.source(for: selection))
                    }
                }
            } label: {
                if isAdding {
                    ProgressView().controlSize(.small).frame(width: 24, height: 26)
                } else {
                    Image(systemName: "plus").frame(width: 24, height: 26)
                }
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isAdding)
            .immediateHelp(String(localized: "Add Repository or Folder"))
            .accessibilityLabel(Text("Add Repository or Folder"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func groupRow(_ folder: WorkspaceEntry, children: [WorkspaceEntry], context: SidebarRowContext) -> some View {
        let organization = context.organization
        let frequent = organization.sorted(folder.frequentRepositories)
        let infrequent = organization.sorted(folder.infrequentRepositories)
        let isExpanded = expansion(for: folder, isSearching: organization.isSearching)
        return DisclosureGroup(isExpanded: isExpanded) {
            if children.isEmpty {
                Text("No Repositories").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(frequent, id: \.url.absoluteString) { repository in
                repositoryRow(repository, context: context, groupURL: folder.url)
            }
            .onMove(perform: organization.canMove ? { source, destination in
                moveRepositories(frequent, in: folder, from: source, to: destination)
            } : nil)
            if !infrequent.isEmpty {
                let isInfrequentExpanded = infrequentExpansion(for: folder, isSearching: organization.isSearching)
                DisclosureGroup(isExpanded: isInfrequentExpanded) {
                    ForEach(infrequent, id: \.url.absoluteString) { repository in
                        repositoryRow(repository, context: context, groupURL: folder.url, isInfrequent: true)
                    }
                    .onMove(perform: organization.canMove ? { source, destination in
                        moveRepositories(infrequent, in: folder, from: source, to: destination)
                    } : nil)
                } label: {
                    Button {
                        isInfrequentExpanded.wrappedValue.toggle()
                    } label: {
                        HStack {
                            Label {
                                Text("Inactive")
                            } icon: {
                                Image(systemName: "archivebox").foregroundStyle(.tint)
                            }
                            .labelStyle(SidebarEntryLabelStyle())
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Inactive"))
                    .accessibilityValue(isInfrequentExpanded.wrappedValue ? Text("Expanded") : Text("Collapsed"))
                    .accessibilityIdentifier("sidebarInactiveDisclosure-" + folder.identity.absoluteString)
                }
            }
        } label: {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack {
                    Label {
                        Text(folder.displayName)
                    } icon: {
                        Image(systemName: folder.symbol).foregroundStyle(.tint)
                    }
                    .labelStyle(SidebarEntryLabelStyle())
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: folder.displayName))
            .accessibilityValue(isExpanded.wrappedValue ? Text("Expanded") : Text("Collapsed"))
            .accessibilityIdentifier("sidebarGroupDisclosure-" + folder.identity.absoluteString)
            .contextMenu {
                Button("Rename Group", systemImage: "pencil") { groupToRename = GroupNamingTarget(group: folder) }
                Button("Manage Repositories", systemImage: "folder.badge.gearshape") {
                    // Use the complete saved membership even when the sidebar is filtered.
                    guard let group = folders.first(where: { $0.identity == folder.identity }) else { return }
                    groupDraft = RepositoryGroupDraft(groupID: group.identity, name: group.displayName, selected: group.repositories)
                }
                Divider()
                Button("Dissolve Group", systemImage: "folder.badge.minus") {
                    updateFoldersUndoably(WorkspaceGroups.dissolvingGroup(folder.identity, in: folders),
                                          actionName: String(localized: "Dissolve Group"))
                }
                .help("Repositories remain in the sidebar and their folders stay unchanged.")
            }
        }
    }

    private func moveFolders(from source: IndexSet, to destination: Int) {
        guard organization.canMove else { return }
        folders = SidebarOrganization.moving(organization.entries, in: folders, from: source, to: destination)
    }

    private func moveRepositories(_ visible: [WorkspaceEntry], in group: WorkspaceEntry, from source: IndexSet, to destination: Int) {
        guard organization.canMove else { return }
        var updated = folders
        guard let index = updated.firstIndex(where: { $0.identity == group.identity }),
              let original = updated[index].children else { return }
        updated[index].children = SidebarOrganization.moving(visible, in: original, from: source, to: destination)
        folders = updated
    }

    private func recordAddedDates() {
        var dates = sidebarDates
        let original = dates
        dates.register(folders)
        if dates != original { saveDates(dates) }
    }

    private func saveDates(_ dates: SidebarDates) {
        do { datesData = try JSONEncoder().encode(dates) }
        catch { onError(OperationFailure("Save Sidebar Activity", error)) }
    }

    private func addEntry(_ entry: WorkspaceEntry) {
        folders = SidebarOrganization.adding(entry, to: folders)
    }

    private func chooseCloneDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Choose Clone Location")
        panel.message = String(localized: "Choose the parent directory for the cloned repository.")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            cloneParent = CloneParent(url: url)
        }
    }

    @ViewBuilder
    private func repositoryRow(_ folder: WorkspaceEntry, context: SidebarRowContext, groupURL: URL? = nil, isInfrequent: Bool = false) -> some View {
        let showWorktreeInformation = showsWorktreeInformation(for: folder.url)
        let related = worktrees.sidebarChildren(for: folder.url, saved: context.saved)
        let selectedIdentity = selection.map(RepositoryLocation.canonical)
        let children = showWorktreeInformation ? related : related.filter { $0.id == selectedIdentity }
        let isSearching = context.organization.isSearching
        if children.isEmpty {
            repositoryContent(folder, context: context, groupURL: groupURL, isInfrequent: isInfrequent)
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { isSearching || !collapsedWorktrees.contains(folder.identity) },
                set: { expanded in
                    if expanded { collapsedWorktrees.remove(folder.identity) }
                    else { collapsedWorktrees.insert(folder.identity) }
                }
            )) {
                ForEach(children) { tree in
                    repositoryContent(WorkspaceEntry(url: tree.url), context: context, isInfrequent: isInfrequent)
                }
            } label: {
                repositoryContent(folder, context: context, groupURL: groupURL, isInfrequent: isInfrequent)
            }
            .tag(folder.url)
        }
    }

    private func repositoryContent(_ folder: WorkspaceEntry, context: SidebarRowContext, groupURL: URL? = nil, isInfrequent: Bool = false) -> some View {
        let showWorktreeInformation = showsWorktreeInformation(for: folder.url)
        let tree = worktrees.worktree(at: folder.url)
        let isLinked = tree.map { !$0.isMain && !$0.isBare } == true
        let isSelected = selectedRepositories.contains(folder.url)
        let isSaved = context.savedIdentities.contains(folder.identity)
        let autoFetch = AutoFetchScheduler.shared
        let interval = autoFetch.interval(for: folder)
        let fetchError = autoFetch.errors[AutoFetchScheduler.key(for: folder.url)]
        return HStack {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayNames.displayName(for: folder))
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(isInfrequent ? .secondary : .primary)
                        .help(displayNames.displayName(for: folder) + "\n" + folder.url.path)
                    if let branch = worktrees.sidebarBranch(for: folder.url, showInformation: showWorktreeInformation,
                                                            showRepositoryBranch: showRepositoryBranch) {
                        HStack(spacing: 4) {
                            if !showWorktreeInformation {
                                Image.gitBranch
                                    .font(.system(size: 10, weight: .regular))
                                    .frame(width: 12)
                                    .accessibilityHidden(true)
                            }
                            Text(verbatim: branch)
                                .font(.system(size: 11, weight: .regular))
                                .fontWeight(.regular)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        }
                        // Keep the user's text preference without the sidebar's selected-row emphasis.
                        .environment(\.legibilityWeight, legibilityWeight)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .opacity(isSelected ? 0.85 : 1)
                        .help(branch)
                    }
                }
                .padding(.vertical, 1)
            } icon: {
                let iconStyle = isSelected ? AnyShapeStyle(.primary)
                    : isLinked ? AnyShapeStyle(.secondary)
                    : AnyShapeStyle(folder.repositoryIconColor.opacity(isInfrequent ? 0.6 : 1))
                if showWorktreeInformation && showWorktreeStatus {
                    WorktreeStatusIcon(url: folder.url, isMain: !isLinked, name: displayNames.displayName(for: folder),
                                       symbol: isLinked ? nil : folder.symbol, style: iconStyle)
                } else if showWorktreeInformation && isLinked {
                    WorktreeIndicator(path: folder.url.path)
                } else {
                    Image(systemName: folder.symbol)
                        .foregroundStyle(iconStyle)
                }
            }
            .labelStyle(SidebarEntryLabelStyle())
            Spacer(minLength: 4)
            if showWorktreeInformation && tree?.isLocked == true {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    .immediateHelp(String(localized: "Locked Worktree"))
                    .accessibilityLabel(Text("Locked Worktree"))
            }
            if showWorktreeInformation && (tree?.isPrunable == true || worktrees.errors[folder.identity] != nil) {
                warningButton("Load Worktrees", message: worktrees.errors[folder.identity] ?? String(localized: "Missing Worktree"), directory: folder.url)
            }
            if isSaved && missingRepositories.contains(folder.identity) {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                    .immediateHelp(String(localized: "Repository Not Found") + "\n" + folder.url.path)
                    .accessibilityLabel(Text("Repository Not Found"))
                    .accessibilityIdentifier("missingRepository-" + folder.url.path)
            }
            if isSaved && interval != .off {
                if let fetchError {
                    ProjectAutoFetchWarning(folder: folder, repositoryName: displayNames.displayName(for: folder),
                                            message: fetchError, onError: onError)
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2).foregroundStyle(.secondary)
                        .immediateHelp(String(localized: "Automatic Fetch") + "\n" + interval.title)
                        .accessibilityLabel(Text("Automatic Fetch"))
                        .accessibilityValue(Text(verbatim: interval.title))
                }
            }
        }
        .tag(folder.url)
        .contextMenu {
            let repositories = actionRepositories(clicked: folder)
            if repositories.count > 1 {
                groupingActions(for: repositories)
                Divider()
                CopyRepositoryPathButton(url: folder.url)
                Button("Remove from Sidebar") { requestRemoval(repositories) }
            } else {
                Button(displayNames.customName(for: folder) == nil
                       ? String(localized: "Name Repository")
                       : String(localized: "Rename Repository"), systemImage: "pencil") {
                    repositoryToName = RepositoryNamingTarget(repository: folder)
                }
                Divider()
                if isSaved { groupingActions(for: [folder]); Divider() }
                if globalShowWorktreeInformation {
                    worktreeEnableToggle(for: folder)
                    if showWorktreeInformation {
                        Button("New Worktree", systemImage: "plus") {
                            creatingWorktree = WorktreeSheetTarget(url: folder.url)
                        }
                        Button("Manage Worktrees", systemImage: "square.stack.3d.up") {
                            managingWorktrees = WorktreeSheetTarget(url: worktrees.source(for: folder.url))
                        }
                        if worktrees.list(for: folder.url).count > 1 {
                            Button("Clean Up Merged Worktrees", systemImage: "trash") {
                                cleaningWorktrees = WorktreeSheetTarget(url: worktrees.source(for: folder.url))
                            }
                        }
                        if isLinked && tree?.branch != nil && !disableCommitOperations {
                            Button("Finish Worktree", systemImage: "checkmark.circle") {
                                finishingWorktree = WorktreeSheetTarget(url: folder.url)
                            }
                        }
                    }
                    Divider()
                }
                if isSaved { ProjectAutoFetchMenu(folder: folder) }
                Divider()
                Button("Show in Finder", systemImage: "folder") { reveal(folder) }
                CopyRepositoryPathButton(url: folder.url)
                if let groupURL {
                    Divider()
                    if isInfrequent {
                        Button("Mark as Active", systemImage: "tray.and.arrow.up") {
                            setInfrequent(false, repository: folder, groupURL: groupURL)
                        }
                    } else {
                        Button("Mark as Inactive", systemImage: "archivebox") {
                            setInfrequent(true, repository: folder, groupURL: groupURL)
                        }
                    }
                }
                Divider()
                if isSaved && missingRepositories.contains(folder.identity) {
                    Button("Locate", systemImage: "magnifyingglass") { locate(folder) }
                }
                if isSaved {
                    Button("Remove from Sidebar") { requestRemoval([folder]) }
                }
            }
        }
    }

    private func warningButton(_ operation: LocalizedStringResource, message: String, directory: URL) -> some View {
        Button {
            onError(OperationFailure(operation, GenericError(errorDescription: message), directory: directory))
        } label: {
            Image(systemName: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                .padding(4).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .immediateHelp(String(localized: operation) + "\n" + message + "\n" + String(localized: "View Error Details"))
        .accessibilityLabel(Text("View Error Details"))
        .accessibilityValue(Text(verbatim: String(localized: operation)))
    }

    private func worktreeEnableToggle(for repository: WorkspaceEntry) -> some View {
        Toggle("Enable Worktrees", isOn: Binding(
            get: { showsWorktreeInformation(for: repository.url) },
            set: { saveWorktreeEnabled($0, for: repository) }
        ))
    }

    private func saveWorktreeEnabled(_ enabled: Bool, for repository: WorkspaceEntry) {
        Task {
            do {
                try await worktrees.refresh(repository.url)
                var preferences = worktreePreferences
                preferences.setEnabled(enabled, for: worktrees.repositoryIdentity(for: repository.url))
                worktreePreferencesData = try JSONEncoder().encode(preferences)
            } catch { onError(OperationFailure("Save Repository Settings", error)) }
        }
    }

    private func relocateWorktree(_ old: URL, _ destination: URL?, fallback: URL) {
        let oldID = WorkspaceEntry(url: old).identity
        let replacement = destination ?? worktrees.replacementAnchor(removing: old, saved: folders.flatMap(\.repositories), family: fallback)
        if selection.map({ WorkspaceEntry(url: $0).identity }) == oldID {
            selection = destination ?? worktrees.list(for: fallback).first(where: { !$0.isBare && !$0.isPrunable })?.url
        }
        if let destination {
            var names = displayNames
            if let name = names.customName(for: WorkspaceEntry(url: old)) {
                names.setName(name, for: WorkspaceEntry(url: destination))
                names.setName("", for: WorkspaceEntry(url: old))
                do { displayNamesData = try JSONEncoder().encode(names) } catch { onError(OperationFailure("Save Repository Name", error)) }
            }
            var dates = sidebarDates
            let newPath = WorkspaceEntry(url: destination).identity.path
            dates.added[newPath] = dates.added.removeValue(forKey: oldID.path)
            dates.opened[newPath] = dates.opened.removeValue(forKey: oldID.path)
            saveDates(dates)
        }
        let update: (WorkspaceEntry) -> WorkspaceEntry? = { entry in
            guard entry.identity == oldID else { return entry }
            return replacement.map { WorkspaceEntry(url: $0) }
        }
        folders = folders.compactMap { entry in
            if entry.isRepository { return update(entry) }
            var group = entry
            group.children = entry.repositories.compactMap(update)
            group.infrequentRepositoryURLs = entry.infrequentRepositoryURLs?.compactMap { url in
                WorkspaceEntry(url: url).identity == oldID ? replacement : url
            }
            return group
        }
    }

    private var sidebarSelection: Binding<Set<URL>> {
        Binding(get: { selectedRepositories }, set: { values in
            // Filtering or moving a row between groups must not clear the current repository.
            guard !values.isEmpty else { return }
            guard !values.contains(where: { worktrees.worktree(at: $0)?.isPrunable == true }) else { return }
            let added = values.subtracting(selectedRepositories)
            selectedRepositories = values
            if let lastAdded = added.sorted(by: { $0.path < $1.path }).last {
                selection = lastAdded
            } else if let selection, !values.contains(selection), !values.isEmpty {
                self.selection = values.sorted(by: { $0.path < $1.path }).first
            }
        })
    }

    private func actionRepositories(clicked: WorkspaceEntry? = nil) -> [WorkspaceEntry] {
        if let clicked, !selectedRepositories.contains(clicked.url) { return [clicked] }
        return WorkspaceGroups.uniqueRepositories(folders).filter { selectedRepositories.contains($0.url) }
    }

    @ViewBuilder
    private func groupingActions(for repositories: [WorkspaceEntry]) -> some View {
        let identities = Set(repositories.map(\.identity))
        Menu {
            Button("Ungrouped") {
                folders = WorkspaceGroups.movingRepositories(identities, to: nil, in: folders)
            }
            Divider()
            ForEach(folders.filter { !$0.isRepository }, id: \.identity) { group in
                Button(group.displayName) {
                    folders = WorkspaceGroups.movingRepositories(identities, to: group.identity, in: folders)
                    collapsedGroups.remove(group.identity)
                }
            }
        } label: {
            Label("Move to Group", systemImage: "folder")
        }
        Button("New Group with Selection", systemImage: "folder.badge.plus") {
            beginNewGroup(with: repositories)
        }
    }

    private func beginNewGroup(with repositories: [WorkspaceEntry]) {
        groupDraft = RepositoryGroupDraft(name: String(localized: "New Group"), selected: repositories)
    }

    private func saveDisplayName(_ name: String, for repository: WorkspaceEntry) {
        var names = displayNames
        names.setName(name, for: repository)
        do {
            displayNamesData = try JSONEncoder().encode(names)
            repositoryToName = nil
        } catch {
            onError(OperationFailure("Save Repository Name", error))
        }
    }

    private func expansion(for folder: WorkspaceEntry, isSearching: Bool) -> Binding<Bool> {
        Binding(get: { isSearching || !collapsedGroups.contains(folder.identity) }, set: { expanded in
            guard !isSearching else { return }
            if expanded { collapsedGroups.remove(folder.identity) }
            else { collapsedGroups.insert(folder.identity) }
        })
    }

    private func infrequentExpansion(for folder: WorkspaceEntry, isSearching: Bool) -> Binding<Bool> {
        Binding(get: { isSearching || expandedInfrequentGroups.contains(folder.identity) }, set: { expanded in
            guard !isSearching else { return }
            if expanded { expandedInfrequentGroups.insert(folder.identity) }
            else { expandedInfrequentGroups.remove(folder.identity) }
        })
    }

    private func setInfrequent(_ infrequent: Bool, repository: WorkspaceEntry, groupURL: URL) {
        var updated = folders
        let identity = WorkspaceEntry(url: groupURL).identity
        guard let index = updated.firstIndex(where: { !$0.isRepository && $0.identity == identity }) else { return }
        updated[index].setInfrequent(infrequent, repository: repository)
        folders = updated
    }

    private var menuActions: MenuActions {
        var actions = MenuActions()
        guard !isAdding, cloneParent == nil, groupDraft == nil, groupToRename == nil,
              repositoryToName == nil, creatingWorktree == nil, managingWorktrees == nil, cleaningWorktrees == nil,
              finishingWorktree == nil else { return actions }
        actions[.openRepository] = chooseDirectory
        actions[.cloneRepository] = chooseCloneDirectory
        actions[.newGroup] = { beginNewGroup(with: []) }
        if let selection, showsWorktreeInformation(for: selection) {
            actions[.newWorktree] = { creatingWorktree = WorktreeSheetTarget(url: selection) }
            actions[.manageWorktrees] = {
                managingWorktrees = WorktreeSheetTarget(url: worktrees.source(for: selection))
            }
            if let tree = worktrees.list(for: selection).first(where: { $0.id == RepositoryLocation.canonical(selection) }),
               !tree.isMain, tree.branch != nil {
                if !disableCommitOperations { actions[.finishWorktree] = { finishingWorktree = WorktreeSheetTarget(url: selection) } }
            }
        }
        return actions
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = String(localized: "Add Repository or Folder")
        panel.message = String(localized: "Add a Git repository or a folder containing multiple repositories.")
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                isAdding = true
                defer { isAdding = false }
                do {
                    var entries: [WorkspaceEntry] = []
                    for url in panel.urls { entries.append(try await discovery.inspect(url)) }
                    let repositories = WorkspaceGroups.uniqueRepositories(entries)
                    if let directory = entries.first(where: { !$0.isRepository }) {
                        groupDraft = RepositoryGroupDraft(name: directory.displayName, selected: repositories, incoming: repositories)
                    } else {
                        folders = WorkspaceGroups.addingRepositories(repositories, to: folders)
                        search = ""
                        if let repository = repositories.last { selection = repository.url }
                    }
                } catch {
                    onError(OperationFailure("Add Repositories from Finder", error))
                }
            }
        }
    }

    private var removalTitle: String {
        String(localized: "Remove \(pendingRemoval.count) Repositories from the Sidebar?")
    }

    /// One repository is removed right away, since Undo restores it; several ask first.
    private func requestRemoval(_ repositories: [WorkspaceEntry]) {
        let saved = Set(folders.flatMap(\.repositories).map(\.identity))
        let removable = repositories.filter { saved.contains($0.identity) }
        guard !removable.isEmpty else { return }
        if removable.count > 1 {
            pendingRemoval = removable
        } else {
            removeFromSidebar(removable)
        }
    }

    private func removeFromSidebar(_ repositories: [WorkspaceEntry]) {
        updateFoldersUndoably(WorkspaceGroups.removingRepositories(Set(repositories.map(\.identity)), from: folders),
                              actionName: String(localized: "Remove from Sidebar"))
    }

    /// Registers the previous sidebar with the window's undo manager, so Command-Z restores it and Redo reapplies it.
    private func updateFoldersUndoably(_ updated: [WorkspaceEntry], actionName: String) {
        let binding = $folders
        let manager = undoManager
        SidebarUndo.apply(updated, to: binding, manager: manager, actionName: actionName)
    }

    private func refreshMissingRepositories() {
        let missing = Set(folders.flatMap(\.repositories).filter { entry in
            entry.url.isFileURL && !FileManager.default.fileExists(atPath: entry.url.path)
        }.map(\.identity))
        if missing != missingRepositories { missingRepositories = missing }
    }

    private func locate(_ folder: WorkspaceEntry) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Locate Repository")
        panel.message = String(localized: "Choose the new location of \(displayNames.displayName(for: folder)).")
        panel.directoryURL = folder.url.deletingLastPathComponent()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let entry = try await discovery.inspect(url)
                    guard entry.isRepository else {
                        throw GenericError(errorDescription: String(localized: "The selected folder is not a Git repository."))
                    }
                    relocateWorktree(folder.url, entry.url, fallback: entry.url)
                    refreshMissingRepositories()
                } catch {
                    onError(OperationFailure("Locate Repository", error))
                }
            }
        }
    }

    private func reveal(_ folder: WorkspaceEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
    }
}

/// A request from outside the sidebar to start adding a repository.
struct SidebarRequest: Equatable {
    enum Kind { case open, clone }
    let kind: Kind
    let id = UUID()
}

/// Sidebar edits share one undo target; the sidebar contents live in user defaults behind a binding.
@MainActor
private final class SidebarUndo {
    static let shared = SidebarUndo()

    static func apply(_ folders: [WorkspaceEntry], to binding: Binding<[WorkspaceEntry]>,
                      manager: UndoManager?, actionName: String) {
        let previous = binding.wrappedValue
        binding.wrappedValue = folders
        manager?.registerUndo(withTarget: shared) { _ in
            MainActor.assumeIsolated {
                apply(previous, to: binding, manager: manager, actionName: actionName)
            }
        }
        manager?.setActionName(actionName)
    }
}

private struct RepositoryNamingTarget: Identifiable {
    let repository: WorkspaceEntry
    var id: URL { repository.identity }
}

private struct RepositoryDisplayNameSheet: View {
    let repository: WorkspaceEntry
    @State var name: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Repository Display Name")
                .font(.headline)
            Text("Only changes the name shown in the sidebar. The folder name stays unchanged.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Display Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameIsFocused)
                .accessibilityIdentifier("repositoryDisplayNameField")
                .onSubmit { onSave(name) }
            Text(repository.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text("Leave empty to use the folder name.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Use Folder Name") { name = repository.url.lastPathComponent }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(name) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .task { nameIsFocused = true }
    }
}

private struct CloneParent: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ModificationRefreshID: Hashable {
    let paths: [URL]
    let enabled: Bool
}

private struct GroupNamingTarget: Identifiable {
    let group: WorkspaceEntry
    var id: URL { group.identity }
}

private struct SidebarRowContext {
    let organization: SidebarOrganization
    let saved: [WorkspaceEntry]
    let savedIdentities: Set<URL>

    init(organization: SidebarOrganization, saved: [WorkspaceEntry]) {
        self.organization = organization
        self.saved = saved
        savedIdentities = Set(saved.map(\.identity))
    }
}

private struct SidebarEntryLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 8) {
            configuration.icon
                .font(.system(size: 13, weight: .regular))
                .frame(width: 18)
            configuration.title.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WorktreeRefreshID: Hashable {
    let paths: [URL]
    let enabled: Bool
}

private struct WorktreeStatusMonitorID: Hashable {
    let paths: [String]
    let enabled: Bool
}
