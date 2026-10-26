import AppKit
import FoldGitCore
import FoldGitTestSupport
import SwiftUI
import Testing
@testable import FoldGit

@MainActor
struct WorktreeStoreTests {
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
