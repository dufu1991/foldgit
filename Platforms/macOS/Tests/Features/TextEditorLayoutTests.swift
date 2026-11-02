import AppKit
import CoreText
import FoldGitCore
import SwiftUI
import Testing
@testable import FoldGit

@MainActor
struct TextEditorLayoutTests {
    nonisolated private static let messages = [
        "fix: Correct the input field layout",
        "fix: 修复搜索框无法输入的问题",
        "修复输入区域顶部文字显示不完整的问题",
        "fix: 入力欄の文字が切れる問題を修正",
        "fix: 입력 영역의 텍스트 잘림 수정",
        "fix: Corriger la saisie des caractères accentués",
    ]

    @Test(arguments: messages, [ColorScheme.light, .dark])
    func amendMessageFirstLineFitsInsideEditor(message: String, scheme: ColorScheme) async throws {
        let commit = Commit(hash: "test", parentHashes: [], author: "Test", authorEmail: "test@example.com",
                            authorDate: "2026-11-02T00:00:00Z", title: message, body: "", branches: [], tags: [])
        let root = AmendCommitSheet(folder: .init(url: URL(fileURLWithPath: "/tmp")),
                                    showingAmendCommitAt: .constant(commit), onCreate: {})
            .environment(\.colorScheme, scheme)
            .frame(width: 520, height: 240)
        try await verifyFirstLine(root, message: message)
    }

    @Test(arguments: messages)
    func commitMessageFirstLineFitsInsideEditor(message: String) async throws {
        let root = CommitMessageEditor(folder: .init(url: URL(fileURLWithPath: "/tmp")),
                                       commitMessage: .constant(message), cachedDiffStat: .constant(nil),
                                       isAmend: .constant(false), error: .constant(nil), cachedDiffRaw: .constant(""),
                                       amendCommit: .constant(nil), onCommit: {})
            .frame(width: 680, height: 160)
        try await verifyFirstLine(root, message: message)
    }

    private func verifyFirstLine(_ root: some View, message: String) async throws {
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 680, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
        #expect(editor.string == message)
        let manager = try #require(editor.textLayoutManager)
        var firstLineBounds: CGRect?
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            guard let line = fragment.textLineFragments.first else { return false }
            let attributedString = line.attributedString.attributedSubstring(from: line.characterRange)
            let glyphBounds = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(attributedString), .useGlyphPathBounds)
            let baseline = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
                + line.glyphOrigin.y + editor.textContainerOrigin.y
            firstLineBounds = CGRect(x: 0, y: baseline - glyphBounds.maxY,
                                     width: glyphBounds.width, height: glyphBounds.height)
            return false
        }
        let bounds = try #require(firstLineBounds)
        // Fallback glyphs must fit above the clipping edge even when the first line starts with Latin text.
        #expect(bounds.minY >= editor.visibleRect.minY)
        #expect(bounds.maxY <= editor.visibleRect.maxY)
        #expect(window.makeFirstResponder(editor))
        #expect(window.firstResponder === editor)
    }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendants($0) }
    }
}
