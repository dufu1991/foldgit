import AppKit
import CoreText
import FoldGitCore
import FoldGitTestSupport
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
                                       error: .constant(nil), cachedDiffRaw: .constant(""),
                                       onCommit: {})
            .frame(width: 680, height: CommitMessageEditor.height)
        try await verifyFirstLine(root, message: message)
    }

    @Test(arguments: [280.0, 440.0, 560.0])
    func multilineInputWrapsAndScrollsWithoutClipping(width: Double) async throws {
        let line = "A long commit message with words and 中文输入 😀 " + String(repeating: "unbroken", count: 20)
        let message = Array(repeating: line, count: 30).joined(separator: "\n")
        let host = NSHostingView(rootView: MultilineTextEditor(text: .constant(message)).frame(width: width, height: 180))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(descendants(host).compactMap { $0 as? MultilineEditorScrollView }.first)
        let editor = try #require(scroll.documentView as? NSTextView)
        #expect(editor.textContainerInset.height >= 8)
        #expect(abs(editor.frame.width - scroll.contentSize.width) < 1)
        let manager = try #require(editor.textLayoutManager)
        var wrappedLines = 0
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            wrappedLines = fragment.textLineFragments.count
            for line in fragment.textLineFragments {
                #expect(line.typographicBounds.maxX + editor.textContainerOrigin.x <= editor.bounds.width - 8)
            }
            return false
        }
        #expect(wrappedLines > 1)
        editor.scrollRangeToVisible(NSRange(location: message.utf16.count, length: 0))
        #expect(scroll.documentVisibleRect.minY > 0)
        editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        #expect(scroll.documentVisibleRect.minY < 1)
        #expect(editor.string == message)
    }

    @Test func nativeMultilineEditsAndUndoKeepTheBindingInSync() async throws {
        var message = "First line\n第二行"
        let binding = Binding(get: { message }, set: { message = $0 })
        let host = NSHostingView(rootView: MultilineTextEditor(text: binding).frame(width: 320, height: 120))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: message.utf16.count, length: 0))
        editor.insertText("\nThird line", replacementRange: editor.selectedRange())
        #expect(message == "First line\n第二行\nThird line")
        editor.breakUndoCoalescing()
        #expect(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        #expect(editor.string == "First line\n第二行")
        #expect(message == "First line\n第二行")
        editor.undoManager?.redo()
        #expect(message == "First line\n第二行\nThird line")
        editor.undoManager?.undo()
        #expect(message == "First line\n第二行")
        editor.setSelectedRange(NSRange(location: message.utf16.count, length: 0))
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        host.rootView = MultilineTextEditor(text: binding).frame(width: 280, height: 120)
        host.layoutSubtreeIfNeeded()
        #expect(editor.hasMarkedText())
        #expect(editor.string.hasSuffix("拼"))
        editor.insertText("拼音", replacementRange: editor.markedRange())
        #expect(!editor.hasMarkedText())
        #expect(message.hasSuffix("拼音"))
    }

    @Test func squashMessageFirstLineFitsInsideEditor() async throws {
        let repository = try await TestRepository.create(commits: 3)
        defer { repository.remove() }
        let commits = try await GitRuntime.run(GitLog(directory: repository.url, revisionRange: ["HEAD"]))
        let expected = commits.reversed().map(\.title).joined(separator: " | ")
        TestPreferences.isolateCommitOperations()
        let root = SquashCommitSheet(directory: repository.url, hashes: Set(commits.map(\.hash)), onComplete: { _ in })
            .environment(\.colorScheme, .light)
            .defaultAppStorage(TestPreferences.isolated)
        try await verifyFirstLine(root, message: expected)
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
        var candidate: NSTextView?
        for _ in 0..<40 {
            candidate = descendants(host).compactMap { $0 as? NSTextView }.first
            if candidate?.string == message { break }
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
        }
        let editor = try #require(candidate)
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
