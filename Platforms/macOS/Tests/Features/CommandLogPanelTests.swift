import AppKit
import FoldGitCore
import FoldGitTestSupport
import SwiftUI
import Testing
@testable import FoldGit

@MainActor
struct CommandLogPanelTests {
    @Test func filtersAndExportsPreserveFailureDetails() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        await GitCommandLog.shared.clear(in: repository.url)
        _ = try await GitRuntime.run(GitStatus(directory: repository.url))
        await #expect(throws: GitExecutionError.self) {
            try await repository.git(["rev-parse", "--verify", "refs/heads/foldgit-missing"])
        }
        let entries = await GitCommandLog.shared.records(in: repository.url)
        let failures = CommandLogPresentation.filtered(entries, search: "", onlyFailures: true, includeReads: true)
        #expect(failures.count == 1)
        #expect(failures.first?.status == .failed)
        #expect(CommandLogPresentation.filtered(entries, search: "FOLDGIT-MISSING", onlyFailures: false, includeReads: true) == failures)
        #expect(CommandLogPresentation.filtered(entries, search: "", onlyFailures: false, includeReads: false) == failures)
        let text = CommandLogPresentation.transcript(failures)
        #expect(text.contains("refs/heads/foldgit-missing"))
        #expect(text.contains(repository.url.path))
        let standardError = try #require(failures.first?.standardError?.text)
        #expect(text.contains(standardError))
        #expect(!text.contains("status --porcelain"))
    }

    @Test func panelRendersAtMinimumWidthInBothAppearances() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        for scheme in [ColorScheme.light, .dark] {
            let root = CommandLogPanel(directory: repository.url, isPresented: .constant(true), selectedID: .constant(nil))
                .environment(\.colorScheme, scheme)
                .frame(width: 320, height: 600)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            #expect(image.pixelsWide >= 320)
            #expect(image.pixelsHigh >= 600)
        }
    }
}
