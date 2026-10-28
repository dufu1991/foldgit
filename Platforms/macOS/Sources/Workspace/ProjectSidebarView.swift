import FoldGitCore
import SwiftUI

struct ProjectSidebarView: View {
    @AppStorage(PreferenceKey.repositoryDisplayNames.rawValue)
    private var displayNamesData = PreferenceDefaults.repositoryDisplayNames
    @AppStorage(PreferenceKey.sidebarSort.rawValue) private var sort = SidebarSort.manual
    @AppStorage(PreferenceKey.sidebarSortAscending.rawValue) private var ascending = true
    @AppStorage(PreferenceKey.sidebarDates.rawValue) private var datesData = PreferenceDefaults.sidebarDates
    @AppStorage(PreferenceKey.showWorktreeInformation.rawValue)
    private var globalShowWorktreeInformation = PreferenceDefaults.showWorktreeInformation
    @AppStorage(PreferenceKey.repositoryWorktreeVisibility.rawValue)
    private var worktreePreferencesData = PreferenceDefaults.repositoryWorktreeVisibility
    @Binding var folders: [WorkspaceEntry]
    @Binding var selection: URL?
    let onError: (Error) -> Void
    @Environment(\.appearsActive) private var appearsActive
    @Environment(WorktreeStore.self) private var worktrees
    @State private var finishingWorktree: WorktreeSheetTarget?
    @State private var creatingWorktree: WorktreeSheetTarget?
    @State private var managingWorktrees: WorktreeSheetTarget?
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
    @State private var displayNamesCache = DecodedPreference { RepositoryDisplayNames.decode($0 ?? Data()) }
    @State private var datesCache = DecodedPreference { SidebarDates.decode($0 ?? Data()) }
    @State private var worktreePreferencesCache = DecodedPreference { RepositoryWorktreePreferences.decode($0 ?? Data()) }
    private let activity = RepositoryActivity()
    private let discovery = MacRepositoryDiscovery.make()

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
        .task(id: WorktreeRefreshID(paths: folders.flatMap(\.repositories).map(\.identity), enabled: appearsActive)) {
            await worktrees.refreshRepositories(folders.flatMap(\.repositories).map(\.url))
            guard appearsActive else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                await worktrees.refreshRepositories(folders.flatMap(\.repositories).map(\.url))
            }
        }
        .onChange(of: sort) { ascending = sort == .name || sort == .manual }
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
            NativeSearchField(text: $search, placeholder: String(localized: "Search Directories or Repositories"),
                              accessibilityIdentifier: "sidebarSearchField")
                .frame(height: 26)
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
            .help("Sort Repositories")
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
            .help("Add Repository or Folder")
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
        return DisclosureGroup(isExpanded: expansion(for: folder, isSearching: organization.isSearching)) {
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
                DisclosureGroup(isExpanded: infrequentExpansion(for: folder, isSearching: organization.isSearching)) {
                    ForEach(infrequent, id: \.url.absoluteString) { repository in
                        repositoryRow(repository, context: context, groupURL: folder.url, isInfrequent: true)
                    }
                    .onMove(perform: organization.canMove ? { source, destination in
                        moveRepositories(infrequent, in: folder, from: source, to: destination)
                    } : nil)
                } label: {
                    HStack {
                        Label("Inactive", systemImage: "archivebox")
                        Spacer(minLength: 4)
                        Text(infrequent.count, format: .number).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack {
                Label(folder.displayName, systemImage: folder.symbol)
                Spacer(minLength: 4)
                Text(children.count, format: .number).monospacedDigit().foregroundStyle(.secondary)
            }
            .help(folder.displayName)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Rename Group", systemImage: "pencil") { groupToRename = GroupNamingTarget(group: folder) }
                Button("Manage Repositories", systemImage: "folder.badge.gearshape") {
                    // Use the complete saved membership even when the sidebar is filtered.
                    guard let group = folders.first(where: { $0.identity == folder.identity }) else { return }
                    groupDraft = RepositoryGroupDraft(groupID: group.identity, name: group.displayName, selected: group.repositories)
                }
                Divider()
                Button("Dissolve Group", systemImage: "folder.badge.minus") {
                    folders = WorkspaceGroups.dissolvingGroup(folder.identity, in: folders)
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
        catch { onError(error) }
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
        let isSaved = context.savedIdentities.contains(folder.identity)
        let autoFetch = AutoFetchScheduler.shared
        let interval = autoFetch.interval(for: folder)
        let fetchError = autoFetch.errors[AutoFetchScheduler.key(for: folder.url)]
        return HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayNames.displayName(for: folder))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(isInfrequent ? .secondary : .primary)
                    if showWorktreeInformation, let tree, worktrees.list(for: folder.url).count > 1 {
                        Text(tree.branch ?? String(localized: "Detached HEAD"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            } icon: {
                Image(systemName: folder.symbol)
                    .foregroundStyle(selectedRepositories.contains(folder.url)
                        ? AnyShapeStyle(.primary)
                        : AnyShapeStyle(folder.repositoryIconColor.opacity(isInfrequent ? 0.6 : 1)))
            }
            Spacer(minLength: 4)
            if showWorktreeInformation && isLinked { WorktreeIndicator(path: folder.url.path).fixedSize() }
            if showWorktreeInformation && tree?.isLocked == true {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Locked Worktree")
            }
            if showWorktreeInformation && (tree?.isPrunable == true || worktrees.errors[folder.identity] != nil) {
                Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .help(worktrees.errors[folder.identity] ?? String(localized: "Missing Worktree"))
            }
            if isSaved && interval != .off {
                Image(systemName: fetchError == nil ? "clock.arrow.circlepath" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(fetchError == nil ? Color.secondary : .orange)
                    .help(fetchError ?? interval.title)
            }
        }
        .help(folder.url.path)
        .tag(folder.url)
        .contextMenu {
            let repositories = actionRepositories(clicked: folder)
            if repositories.count > 1 {
                groupingActions(for: repositories)
                Divider()
                Button("Remove from Sidebar") {
                    folders = WorkspaceGroups.removingRepositories(Set(repositories.map(\.identity)), from: folders)
                }
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
                        if isLinked && tree?.branch != nil {
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
                if isSaved {
                    Button("Remove from Sidebar") {
                        folders = WorkspaceGroups.removingRepositories([folder.identity], from: folders)
                    }
                }
            }
        }
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
            } catch { onError(error) }
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
                do { displayNamesData = try JSONEncoder().encode(names) } catch { onError(error) }
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
            onError(error)
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
                    onError(error)
                }
            }
        }
    }

    private func reveal(_ folder: WorkspaceEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
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

private struct WorktreeRefreshID: Hashable {
    let paths: [URL]
    let enabled: Bool
}
