import AppKit
import FoldGitCore
import FoldGitTestSupport
import SwiftUI
import Testing
@testable import FoldGit

@MainActor
struct WorktreeStatusPresentationTests {
    @Test func backgroundSidebarPausesStatusReadsAndActivationRefreshesImmediately() async throws {
        let repository = try await TestRepository.create()
        let linked = repository.url.deletingLastPathComponent().appendingPathComponent("FoldGit-foreground-\(UUID())")
        defer { repository.remove(); try? FileManager.default.removeItem(at: linked) }
        let store = WorktreeStore()
        try await store.execute(.add(destination: linked, branch: .new(name: "feature", startPoint: "HEAD")), in: repository.url)
        let suite = "FoldGit.StatusLifecycle.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PreferenceKey.showWorktreeInformation.rawValue)
        defaults.set(true, forKey: PreferenceKey.showWorktreeStatus.rawValue)
        var preferences = RepositoryWorktreePreferences()
        preferences.setEnabled(true, for: store.repositoryIdentity(for: repository.url))
        defaults.set(try JSONEncoder().encode(preferences), forKey: PreferenceKey.repositoryWorktreeVisibility.rawValue)
        let sidebar = ProjectSidebarView(folders: .constant([WorkspaceEntry(url: repository.url)]), selection: .constant(repository.url), onError: { _ in })
            .defaultAppStorage(defaults).environment(store).frame(width: 260, height: 400)
        let host = NSHostingView(rootView: AnyView(sidebar.environment(\.appearsActive, false).environment(\.scenePhase, .background)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        #expect(store.statuses.status(for: linked) == nil)
        host.rootView = AnyView(sidebar.environment(\.appearsActive, true).environment(\.scenePhase, .active))
        for _ in 0..<80 {
            if store.statuses.status(for: linked) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.statuses.status(for: linked)?.isClean == true)
        host.rootView = AnyView(sidebar.environment(\.appearsActive, false).environment(\.scenePhase, .background))
        try await Task.sleep(for: .milliseconds(100))
        try "new work".write(to: linked.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(2))
        #expect(store.statuses.status(for: linked)?.isClean == true)
        host.rootView = AnyView(sidebar.environment(\.appearsActive, true).environment(\.scenePhase, .active))
        for _ in 0..<80 {
            if store.statuses.status(for: linked)?.changes.untracked == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.statuses.status(for: linked)?.changes.untracked == 1)
    }

    private func status(changes: String = "", operation: GitPendingOperation? = nil,
                        integrated: Bool = true, unstarted: Bool = false, upstream: Bool = false) throws -> WorktreeStatus {
        let headers = "# branch.oid abcd\0# branch.head feature\0" + (upstream ? "# branch.upstream origin/main\0# branch.ab +2 -3\0" : "")
        return WorktreeStatus(working: try GitWorkingTreeStatus.parse(headers + changes), operation: operation,
            trunk: TrunkComparison(reference: "master", ahead: 1, behind: 30,
                integration: integrated ? .ancestor : .notIntegrated, integratedInto: integrated ? "master" : nil,
                isUnstarted: unstarted))
    }

    @Test func iconPrioritizesConflictsOperationsAndChangesAndNeverMarksMainAsIntegrated() throws {
        let clean = try status()
        let dirty = try status(changes: "1 .M N... 100644 100644 100644 aaa bbb file\0")
        let conflict = try status(changes: "u UU N... 100644 100644 100644 100644 aaa bbb ccc file\0", operation: .merge)
        #expect(WorktreeVisualState(status: nil, isMain: false, isOnTrunk: false) == .unknown)
        #expect(WorktreeVisualState(status: clean, isMain: true, isOnTrunk: false) == .clean)
        #expect(WorktreeVisualState(status: clean, isMain: false, isOnTrunk: true) == .clean)
        #expect(WorktreeVisualState(status: clean, isMain: false, isOnTrunk: false) == .integrated)
        #expect(WorktreeVisualState(status: dirty, isMain: false, isOnTrunk: false) == .modified)
        #expect(WorktreeVisualState(status: try status(operation: .rebase), isMain: false, isOnTrunk: false) == .operating)
        #expect(WorktreeVisualState(status: conflict, isMain: false, isOnTrunk: false) == .conflicted)
        // A worktree created on the trunk and never committed to is not shown as merged.
        #expect(WorktreeVisualState(status: try status(unstarted: true), isMain: false, isOnTrunk: false) == .clean)
        let unstarted = WorktreeStatusText.details(status: try status(unstarted: true), isMain: false, isOnTrunk: false,
                                                   name: "feature")
        #expect(unstarted.sections[0].rows.first?.value == String(localized: "Clean Worktree"))
        #expect(unstarted.sections[1].rows.first?.value == String(localized: "No commits since this worktree was created"))
    }

    @Test func unchangedRefreshesDoNotInvalidateObservers() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let store = WorktreeStore()
        try await store.refresh(repository.url)
        let families = [store.list(for: repository.url)]
        await store.statuses.refresh(families)
        let entry = store.statuses.entry(for: repository.url)
        let changed = ObservationFlag()
        withObservationTracking {
            _ = entry.status
            _ = entry.trunk
            _ = entry.failed
        } onChange: { changed.set() }
        await store.statuses.refresh(families)
        await store.statuses.refresh(families, onlyPaths: [RepositoryLocation.canonical(repository.url).path])
        #expect(!changed.value)
        try repository.write("new.txt", "new\n")
        await store.statuses.refresh(families)
        #expect(changed.value)
    }

    @Test func tooltipSeparatesWorktreeIdentityChangesAndNamedComparisonAndOmitsZeroCounts() throws {
        let dirty = try status(changes: "1 M. N... 100644 100644 100644 aaa bbb staged\0? untracked\0", upstream: true)
        let main = WorktreeStatusText.details(status: dirty, isMain: true, isOnTrunk: true, name: "my-one")
        #expect(main.title.contains(String(localized: "Main Worktree")))
        #expect(main.sections[0].rows.map(\.label) == [String(localized: "Working Tree"), String(localized: "Staged Changes"), String(localized: "Untracked Files")])
        #expect(main.sections[0].rows[0].value == String(localized: "Uncommitted Changes"))
        #expect(main.sections[1].rows.map(\.label) == [String(localized: "Ahead of \("origin/main")"), String(localized: "Behind \("origin/main")")])
        let linked = WorktreeStatusText.details(status: try status(integrated: false), isMain: false, isOnTrunk: false,
                                               name: "feature")
        #expect(linked.title.contains(String(localized: "Linked Worktree")))
        #expect(linked.sections.count == 2)
        #expect(linked.sections[0].rows.map(\.value) == [String(localized: "Clean Worktree")])
        // Every row names the reference it compares with, so no row depends on a heading above it.
        #expect(linked.sections[1].title.isEmpty)
        #expect(linked.sections[1].rows.map(\.label) == [String(localized: "Merge Status"),
            String(localized: "Ahead of \("master")"), String(localized: "Behind \("master")")])
        #expect(linked.sections[1].rows.map(\.value) == [String(localized: "Not merged into \("master")"),
            String(localized: "\(1) commits"), String(localized: "\(30) commits")])
        let unavailable = WorktreeStatusText.details(status: nil, isMain: false, isOnTrunk: false, name: "feature", failed: true)
        #expect(unavailable.summary == String(localized: "Worktree Status Unavailable"))
    }
}

private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

struct WorktreeStatusMonitoringTests {
    private struct Fixture: Sendable {
        let repository: TestRepository
        let linked: URL
        static func create() async throws -> Self {
            // FSEvents does not reliably publish changes beneath macOS's temporary folders.
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { root.deleteLastPathComponent() }
            let parent = root.appendingPathComponent(".build/status-monitor-fixtures")
            let repository = try await TestRepository.create(parent: parent)
            let linked = repository.url.deletingLastPathComponent().appendingPathComponent("FoldGit-watch-\(UUID())")
            try await repository.git(["worktree", "add", "-b", "feature", linked.path, "main"])
            return Self(repository: repository, linked: RepositoryLocation.canonical(linked))
        }
        func remove() { repository.remove(); try? FileManager.default.removeItem(at: linked) }
        func plan() async throws -> RepositoryChangeMonitor.StatusWatchPlan {
            try await RepositoryChangeMonitor.statusWatchPlan(for: [GitRuntime.run(GitWorktreeList(directory: repository.url))])
        }
    }

    @Test func metadataRoutingKeepsIndexesIndependentAndSharedRefsInvalidateTheFamily() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        let main = RepositoryLocation.canonical(fixture.repository.url).path
        let linked = fixture.linked.path
        let metadata = try #require(plan.roots.first { $0.kind == .metadata })
        let shared = try #require(plan.roots.first { $0.kind == .sharedMetadata })
        #expect(plan.affected(by: [metadata.path + "/index"]) == .init(paths: [linked]))
        #expect(plan.affected(by: [metadata.path + "/HEAD"]) == .init(paths: [linked], listPaths: [linked]))
        #expect(plan.affected(by: [metadata.path + "/rebase-merge/head-name"]) == .init(paths: [linked]))
        #expect(plan.affected(by: [metadata.path + "/BISECT_LOG"]) == .init(paths: [linked]))
        #expect(plan.affected(by: [shared.path + "/index"]) == .init(paths: [main]))
        #expect(plan.affected(by: [shared.path + "/HEAD"]) == .init(paths: [main], listPaths: [main]))
        #expect(plan.affected(by: [shared.path + "/refs/heads/main"]) == .init(paths: [main, linked]))
        #expect(plan.affected(by: [shared.path + "/packed-refs"]) == .init(paths: [main, linked]))
        #expect(plan.affected(by: [shared.path + "/worktrees/new-tree/HEAD"]) == .init(paths: [main, linked], listPaths: [main, linked]))
        #expect(plan.affected(by: [shared.path + "/objects/ab/cdef", metadata.path + "/HEAD.lock", shared.path + "/refs/heads/main.lock"]).isEmpty)
        // Edits never reload the worktree list, however many files change.
        #expect(plan.affected(by: (0..<500).map { linked + "/node_modules/pkg\($0)/index.js" }) == .init(paths: [linked]))
    }

    @Test func changesArrivingBeforeTheConsumerTakesThemAreHandedOverOnce() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        let feed = RepositoryChangeMonitor.statusChanges(in: plan, latency: 0.05)
        for _ in 0..<20 { NotificationCenter.default.post(name: GitRuntime.repositoryDidChange, object: fixture.linked) }
        var ticks = feed.ticks.makeAsyncIterator()
        _ = await ticks.next()
        let family = Set(plan.families.keys)
        #expect(feed.take() == .init(paths: family, listPaths: family))
        #expect(feed.take().isEmpty)
    }

    @Test(arguments: ["stage", "commit", "checkout", "notification"])
    func externalGitAndAppMutationsProduceRefreshEvents(operation: String) async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try "changed\n".write(to: fixture.linked.appendingPathComponent("example.swift"), atomically: true, encoding: .utf8)
        if operation == "commit" { try await externalGit(["add", "example.swift"], in: fixture.linked) }
        let plan = try await fixture.plan()
        let feed = RepositoryChangeMonitor.statusChanges(in: plan, latency: 0.05)
        let expected: Set<String> = operation == "commit" || operation == "notification"
            ? Set(plan.families.keys) : [fixture.linked.path]
        try await withThrowingTaskGroup(of: Set<String>.self) { group in
            group.addTask {
                var observed = Set<String>()
                for await _ in feed.ticks {
                    observed.formUnion(feed.take().paths)
                    if expected.isSubset(of: observed) { return observed }
                }
                return observed
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw GitExecutionError(description: "Timed out waiting for a status event.")
            }
            defer { group.cancelAll() }
            switch operation {
            case "stage": try await externalGit(["add", "example.swift"], in: fixture.linked)
            case "commit": try await externalGit(["commit", "-m", "test: external commit"], in: fixture.linked)
            case "checkout": try await externalGit(["switch", "--detach"], in: fixture.linked)
            default: NotificationCenter.default.post(name: GitRuntime.repositoryDidChange, object: fixture.linked)
            }
            let changed = try #require(try await group.next())
            #expect(expected.isSubset(of: changed))
            if operation == "stage" {
                let status = try await WorktreeStatus.read(fixture.linked, trunk: nil)
                #expect(status.changes.staged == 1)
            }
        }
    }

    private func externalGit(_ arguments: [String], in directory: URL) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }.value
    }
}

@MainActor
struct WorktreeCleanupFeatureTests {
    @Test func batchCleanupKeepsIgnoredAndChangedWorktreesAndContinuesAfterFailure() async throws {
        let repository = try await TestRepository.create()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldGit-cleanup-ui-\(UUID())")
        defer { repository.remove(); try? FileManager.default.removeItem(at: root) }
        try repository.write(".gitignore", "build/\n")
        try await repository.git(["add", "--force", ".gitignore"])
        try await repository.commit("test: ignore build files")
        let safe = root.appendingPathComponent("z-safe")
        let changed = root.appendingPathComponent("a-changed")
        let ignored = root.appendingPathComponent("ignored")
        for url in [safe, changed, ignored] {
            try await repository.git(["worktree", "add", "-b", url.lastPathComponent, url.path, "main"])
        }
        let key = ignored.appendingPathComponent("build/local-signing-key.pem")
        try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "private test data".write(to: key, atomically: true, encoding: .utf8)
        let model = WorktreeCleanupModel(repository: repository.url)
        await model.load()
        #expect(model.phase == .review)
        #expect(model.candidates.count == 3)
        let ignoredID = RepositoryLocation.canonical(ignored)
        #expect(!model.selection.contains(ignoredID))
        #expect(model.candidates.first { $0.id == ignoredID }?.ignoredEntries == ["build/local-signing-key.pem"])
        model.selection = [RepositoryLocation.canonical(safe), RepositoryLocation.canonical(changed)]
        try "new work".write(to: changed.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
        var removed: [URL] = []
        await model.run { removed.append(RepositoryLocation.canonical($0)) }
        #expect(model.phase == .finished)
        #expect(removed == [RepositoryLocation.canonical(safe)])
        #expect(model.outcomes[RepositoryLocation.canonical(safe)] == .removed(.deleted))
        if case .failed = model.outcomes[RepositoryLocation.canonical(changed)] {} else { Issue.record("Changed worktree should be kept and reported.") }
        #expect(FileManager.default.fileExists(atPath: changed.path))
        #expect(try String(contentsOf: key, encoding: .utf8) == "private test data")
    }

    @Test func sidebarStatusRefreshTracksChangesAndMergedIntegration() async throws {
        let repository = try await TestRepository.create()
        let linked = repository.url.deletingLastPathComponent().appendingPathComponent("FoldGit-status-ui-\(UUID())")
        defer { repository.remove(); try? FileManager.default.removeItem(at: linked) }
        try await repository.git(["worktree", "add", "-b", "feature", linked.path, "main"])
        let store = WorktreeStore()
        try await store.refresh(repository.url)
        await store.statuses.refresh([store.list(for: repository.url)])
        #expect(store.statuses.status(for: linked)?.canBeCleanedUp == true)
        #expect(store.statuses.isOnTrunk(repository.url))
        #expect(!store.statuses.isOnTrunk(linked))
        try "new work".write(to: linked.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        await store.statuses.refresh([store.list(for: repository.url)], onlyPaths: [RepositoryLocation.canonical(linked).path])
        #expect(store.statuses.status(for: linked)?.changes.untracked == 1)
        #expect(store.statuses.status(for: linked)?.canBeCleanedUp == false)
        try await GitRuntime.run(arguments: ["git", "add", "new.txt"], currentDirectoryURL: linked)
        await store.statuses.refresh([store.list(for: repository.url)])
        let status = try #require(store.statuses.status(for: linked))
        #expect(status.changes.staged == 1)
        #expect(status.changes.untracked == 0)
        let details = WorktreeStatusText.details(status: status, isMain: false, isOnTrunk: false, name: "feature")
        #expect(details.compactText.contains(String(localized: "Staged Changes")))
        #expect(!details.compactText.contains("\n"))
    }
}

@MainActor
struct WorktreeStoreTests {
    @Test func ordinaryRepositoryBranchSubtitleRespectsSettingsAndWorktreeVisibility() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let store = WorktreeStore()
        try await store.refresh(repository.url)
        #expect(store.sidebarBranch(for: repository.url, showInformation: false, showRepositoryBranch: false) == nil)
        #expect(store.sidebarBranch(for: repository.url, showInformation: false, showRepositoryBranch: true) == "main")
        #expect(store.sidebarBranch(for: repository.url, showInformation: true, showRepositoryBranch: true) == nil)
        try await repository.git(["checkout", "--detach"])
        try await store.refresh(repository.url)
        #expect(store.sidebarBranch(for: repository.url, showInformation: false, showRepositoryBranch: true) == String(localized: "Detached HEAD"))
        try await repository.git(["checkout", "main"])
        let linked = repository.url.appendingPathComponent("linked")
        try await store.execute(.add(destination: linked, branch: .new(name: "feature", startPoint: "HEAD")), in: repository.url)
        #expect(store.sidebarBranch(for: repository.url, showInformation: true, showRepositoryBranch: false) == "main")
        #expect(store.sidebarBranch(for: linked, showInformation: true, showRepositoryBranch: false) == "feature")
        #expect(store.sidebarBranch(for: linked, showInformation: false, showRepositoryBranch: true) == "feature")
    }

    @Test func ordinaryRepositoryBranchMonitorFollowsExternalCheckoutWithoutLoadingStatuses() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let store = WorktreeStore()
        try await store.refresh(repository.url)
        let monitor = Task { await store.monitorBranches([store.list(for: repository.url)], minimumInterval: .milliseconds(50)) }
        defer { monitor.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        try await repository.git(["checkout", "-b", "feature/sidebar"])
        for _ in 0..<100 {
            if store.worktree(at: repository.url)?.branch == "feature/sidebar" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.sidebarBranch(for: repository.url, showInformation: false, showRepositoryBranch: true) == "feature/sidebar")
        #expect(store.statuses.status(for: repository.url) == nil)
    }

    @Test func ordinaryRepositoryBranchSidebarFitsNarrowWindows() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        try await repository.git(["checkout", "-b", "feature/ordinary-repository-branch-display"])
        let store = WorktreeStore()
        try await store.refresh(repository.url)
        let suite = "FoldGit.RepositoryBranchRendering.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let entry = WorkspaceEntry(url: repository.url)
        var names = RepositoryDisplayNames()
        names.setName("FoldGit", for: entry)
        defaults.set(try JSONEncoder().encode(names), forKey: PreferenceKey.repositoryDisplayNames.rawValue)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foldgit-repository-branch-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for (enabled, selected) in [(false, false), (true, false), (true, true)] {
                defaults.set(enabled, forKey: PreferenceKey.showRepositoryBranch.rawValue)
                let content = ProjectSidebarView(folders: .constant([entry]), selection: .constant(selected ? entry.url : nil), onError: { _ in })
                    .environment(store).environment(\.appearsActive, false).defaultAppStorage(defaults)
                    .frame(width: 220, height: 320).background(Color(nsColor: .windowBackgroundColor))
                let view = NSHostingView(rootView: content)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 320),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.orderBack(nil)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                window.displayIfNeeded()
                #expect(view.fittingSize.width <= 220)
                let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                let png = try #require(image.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("branch-\(selected ? "selected" : enabled ? "on" : "off")-\(dark ? "dark" : "light").png"))
                window.close()
            }
        }
    }

    @Test func discoveryFromLinkedDirectoryFindsFamilyAndBranchDestination() async throws {
        let repository = try await TestRepository.create()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldGit-worktree-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { repository.remove(); try? FileManager.default.removeItem(at: root) }
        let linked = root.appendingPathComponent("feature")
        let moved = root.appendingPathComponent("renamed")
        let store = WorktreeStore()
        try await store.execute(.add(destination: linked, branch: .new(name: "feature", startPoint: "HEAD")), in: repository.url)
        #expect(store.worktree(at: linked)?.isMain == false)
        #expect(store.worktree(at: repository.url)?.isMain == true)
        #expect(store.destination(for: "feature", in: repository.url)?.id == linked.resolvingSymlinksInPath())
        #expect(store.destination(for: "feature", in: linked) == nil)
        let branches = [Branch(name: "main", isCurrent: true), Branch(name: "feature", isCurrent: false)]
        let hidden = store.visibility(for: repository.url, showInformation: false, currentBranch: "main")
        #expect(hidden.branches(branches).map(\.name) == ["main"])
        #expect(hidden.decorations(["feature", "HEAD -> main", "origin/main"]) == ["HEAD -> main", "origin/main"])
        let currentWorktree = store.visibility(for: linked, showInformation: false, currentBranch: "feature")
        #expect(currentWorktree.showsBranch("feature"))
        #expect(store.visibility(for: repository.url, showInformation: true).branches(branches) == branches)
        var preferences = RepositoryWorktreePreferences()
        let family = store.repositoryIdentity(for: linked)
        #expect(family == store.repositoryIdentity(for: repository.url))
        #expect(!store.showsInformation(for: repository.url, global: true, preferences: preferences))
        preferences.setEnabled(true, for: family)
        #expect(store.showsInformation(for: repository.url, global: true, preferences: preferences))
        #expect(store.showsInformation(for: linked, global: true, preferences: preferences))
        #expect(!store.showsInformation(for: URL(fileURLWithPath: "/another-repository"), global: true, preferences: preferences))
        #expect(!store.showsInformation(for: nil, global: true, preferences: preferences))
        #expect(!store.showsInformation(for: repository.url, global: false, preferences: preferences))
        #expect(!store.showsInformation(for: linked, global: false, preferences: preferences))
        let restored = RepositoryWorktreePreferences.decode(try JSONEncoder().encode(preferences))
        #expect(restored == preferences)
        #expect(store.showsInformation(for: linked, global: true, preferences: restored))
        preferences.setEnabled(false, for: family)
        #expect(!store.showsInformation(for: repository.url, global: true, preferences: preferences))
        #expect(!store.showsInformation(for: linked, global: true, preferences: preferences))
        let mainEntry = WorkspaceEntry(url: repository.url)
        let linkedEntry = WorkspaceEntry(url: linked)
        #expect(store.sidebarChildren(for: repository.url, saved: [mainEntry]).map(\.id) == [linked.resolvingSymlinksInPath()])
        #expect(store.sidebarChildren(for: linked, saved: [linkedEntry]).map(\.id) == [mainEntry.identity])
        #expect(store.sidebarChildren(for: repository.url, saved: [mainEntry, linkedEntry]).isEmpty)
        #expect(store.sidebarChildren(for: linked, saved: [mainEntry, linkedEntry]).isEmpty)
        try await store.refresh(linked)
        #expect(store.list(for: linked) == store.list(for: repository.url))
        try await store.execute(.move(linked, destination: moved), in: linked)
        #expect(!store.contains(linked))
        #expect(store.contains(moved))
        #expect(store.destination(for: "feature", in: repository.url)?.id == moved.resolvingSymlinksInPath())
        try await store.execute(.remove(moved), in: moved)
        #expect(!store.contains(moved))
        #expect(store.list(for: repository.url).count == 1)
        #expect(store.replacementAnchor(removing: moved, saved: [WorkspaceEntry(url: moved)], family: repository.url) == repository.url.resolvingSymlinksInPath())
        #expect(store.replacementAnchor(removing: moved, saved: [mainEntry, WorkspaceEntry(url: moved)], family: repository.url) == nil)
    }

    @Test func searchFindsAutomaticallyDiscoveredWorktreeByBranchPathAndAlias() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let linked = repository.url.appendingPathComponent("review-worktree")
        let store = WorktreeStore()
        try await store.execute(.add(destination: linked, branch: .new(name: "feature/review", startPoint: "HEAD")), in: repository.url)
        var names = RepositoryDisplayNames()
        names.setName("审核目录", for: WorkspaceEntry(url: linked))
        let entry = WorkspaceEntry(url: repository.url)
        let group = WorkspaceEntry.group(name: "项目", repositories: [entry])
        for query in ["feature/review", "review-worktree", "审核"] {
            let sidebar = SidebarOrganization(folders: [group], names: names, query: query, worktrees: store.families)
            #expect(sidebar.entries.first?.repositories == [entry])
        }
    }

    @Test func sidebarDiscoversWorktreesBeforeWindowActivation() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let linked = repository.url.appendingPathComponent("background-worktree")
        try await GitRuntime.run(GitWorktreeCommand(directory: repository.url,
            operation: .add(destination: linked, branch: .new(name: "background", startPoint: "HEAD"))))
        let store = WorktreeStore()
        let view = ProjectSidebarView(folders: .constant([WorkspaceEntry(url: repository.url)]),
                                     selection: .constant(nil), onError: { _ in })
            .environment(store).environment(\.appearsActive, false).frame(width: 260, height: 400)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderBack(nil)
        defer { window.close() }
        for _ in 0..<40 {
            if store.contains(linked) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.worktree(at: linked)?.branch == "background")
    }

    @Test func sidebarAndManagementRenderWithWorktreeIdentity() async throws {
        let repository = try await TestRepository.create()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldGit-worktree-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { repository.remove(); try? FileManager.default.removeItem(at: root) }
        #expect(NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil) != nil)
        let store = WorktreeStore()
        let linked = root.appendingPathComponent("feature-review")
        try await store.execute(.add(destination: linked, branch: .new(name: "feature/review", startPoint: "HEAD")), in: repository.url)
        let group = WorkspaceEntry.group(name: "FoldGit", repositories: [WorkspaceEntry(url: repository.url)])
        let defaultsName = "FoldGit.WorktreeRendering.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: PreferenceKey.showWorktreeInformation.rawValue)
        var preferences = RepositoryWorktreePreferences()
        preferences.setEnabled(true, for: store.repositoryIdentity(for: linked))
        defaults.set(try JSONEncoder().encode(preferences), forKey: PreferenceKey.repositoryWorktreeVisibility.rawValue)
        let directory = URL(fileURLWithPath: "/tmp/foldgit-worktree-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let content = HStack(spacing: 0) {
                ProjectSidebarView(folders: .constant([group]), selection: .constant(linked), onError: { _ in })
                    .frame(width: 260)
                Divider()
                WorktreeManagementSheet(repository: repository.url, onRelocated: { _, _ in })
            }
            .defaultAppStorage(defaults)
            .environment(store)
            .environment(\.folder, linked)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .background(Color(nsColor: .windowBackgroundColor))
            let view = NSHostingView(rootView: content)
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 901, height: 560),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderBack(nil)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            window.displayIfNeeded()
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(dark ? "worktrees-dark.png" : "worktrees-light.png"))
            #expect(view.fittingSize.width <= 910)
            window.close()
        }
    }
}
