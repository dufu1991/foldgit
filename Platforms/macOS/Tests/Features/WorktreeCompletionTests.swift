import AppKit
import FoldGitCore
import FoldGitTestSupport
import SwiftUI
import Testing
@testable import FoldGit

@MainActor
struct WorktreeCompletionTests {
    private func feature(in repository: TestRepository) async throws -> URL {
        let source = repository.url.deletingLastPathComponent().appendingPathComponent(repository.url.lastPathComponent + "-feature")
        try await GitRuntime.run(GitWorktreeCommand(directory: repository.url,
            operation: .add(destination: source, branch: .new(name: "feature", startPoint: "HEAD"))))
        try "let feature = true\n".write(to: source.appendingPathComponent("example.swift"), atomically: true, encoding: .utf8)
        _ = try await GitRuntime.run(arguments: ["git", "add", "."], currentDirectoryURL: source)
        _ = try await GitRuntime.run(arguments: ["git", "commit", "-m", "feature"], currentDirectoryURL: source)
        return source
    }

    @Test func completionMovesFromReviewToMergeAndOptionalCleanup() async throws {
        let repo = try await TestRepository.create()
        let source = try await feature(in: repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        let model = WorktreeCompletionModel(source: source)
        await model.load()
        #expect(model.targetBranch == "main")
        #expect(model.phase == .review && model.plan?.commitCount == 1)
        await model.merge()
        #expect(model.phase == .merged && model.errorMessage == nil)
        model.deleteBranch = true
        await model.cleanup()
        #expect(model.phase == .done && model.sourceRemoved && model.branchDeleted)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try await repo.git(["branch", "--list", "feature"]).isEmpty)
    }

    @Test func reopenedWorkflowFindsConflictAndCanAbortOrContinue() async throws {
        let repo = try await TestRepository.create()
        let source = try await feature(in: repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        try repo.write("example.swift", "let target = true\n")
        try await repo.commit("target")
        let model = WorktreeCompletionModel(source: source)
        await model.load()
        await model.merge()
        #expect(model.phase == .conflicts)
        let reopened = WorktreeCompletionModel(source: source)
        await reopened.load()
        #expect(reopened.phase == .conflicts)
        let conflicts = MergeResolutionModel(directory: repo.url)
        await conflicts.refresh()
        #expect(conflicts.state?.conflicts.count == 1)
        #expect(await conflicts.abort())
        await reopened.mergeAborted()
        #expect(reopened.phase == .review)
        await reopened.merge()
        #expect(await conflicts.resolve("example.swift", choosing: .incoming))
        #expect(await conflicts.continueMerge())
        await reopened.mergeFinished()
        #expect(reopened.phase == .merged)
        reopened.removeWorktree = false
        await reopened.cleanup()
        #expect(reopened.phase == .done && !reopened.sourceRemoved)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func editsAfterMergeBlockCleanupAndLeaveTheSourceUsable() async throws {
        let repo = try await TestRepository.create()
        let source = try await feature(in: repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        let model = WorktreeCompletionModel(source: source)
        await model.load()
        await model.merge()
        try "more work\n".write(to: source.appendingPathComponent("pending.swift"), atomically: true, encoding: .utf8)
        await model.cleanup()
        #expect(model.phase == .merged && !model.sourceRemoved)
        #expect(model.errorMessage != nil)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func ordinaryMergeIsDetectedByRepositorySession() async throws {
        let repo = try await TestRepository.create()
        let source = try await feature(in: repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        try repo.write("example.swift", "target\n")
        try await repo.commit("target")
        _ = try? await GitRuntime.run(GitMerge(directory: repo.url, branchName: "feature"))
        let session = RepositorySession()
        await session.refresh(in: repo.url, fetchRemote: false)
        #expect(session.mergeState?.isMerging == true)
        #expect(session.mergeState?.conflicts.map(\.path) == ["example.swift"])
    }

    @Test func reviewAndConflictSheetsRenderInBothAppearances() async throws {
        let repo = try await TestRepository.create()
        let source = try await feature(in: repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        let store = WorktreeStore()
        try await store.refresh(source)
        let review = WorktreeCompletionModel(source: source)
        await review.load()
        #expect(review.phase == .review && !review.isBusy)
        for dark in [false, true] {
            try await snapshot(WorktreeCompletionSheet(model: review, onRemoved: { _, _ in }).environment(store),
                               name: "review", width: 600, dark: dark)
        }
        try repo.write("example.swift", "let target = true\n")
        try await repo.commit("target")
        let plan = try await WorktreeCompletion.prepare(source: source, targetBranch: "main")
        _ = try await WorktreeCompletion.merge(plan)
        for dark in [false, true] {
            try await snapshot(MergeResolutionContent(directory: repo.url, onFinished: {}, onAborted: {}).padding(24),
                               name: "conflicts", width: 760, dark: dark)
        }
        try await GitMergeWorkflow.resolve("example.swift", choosing: .target, in: repo.url)
        try await GitMergeWorkflow.continueMerge(in: repo.url)
        let cleanup = WorktreeCompletionModel(source: source)
        await cleanup.load()
        #expect(cleanup.phase == .merged && !cleanup.isBusy)
        for dark in [false, true] {
            try await snapshot(WorktreeCompletionSheet(model: cleanup, onRemoved: { _, _ in }).environment(store),
                               name: "cleanup", width: 600, dark: dark)
        }
    }

    private func snapshot<Content: View>(_ content: Content, name: String, width: CGFloat, dark: Bool) async throws {
        let root = content.environment(\.locale, Locale(identifier: "zh-Hans"))
            .frame(width: width).background(Color(nsColor: .windowBackgroundColor))
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        #expect(size.width <= width + 1)
        #expect(size.height <= 800)
        window.setContentSize(CGSize(width: width, height: max(size.height, 300)))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: "/tmp/foldgit-merge-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}
