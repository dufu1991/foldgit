import AppKit
import Testing
@testable import FoldGit

@MainActor
struct SyntaxHighlighterTests {
    @Test func highlightingKeepsUnicodeAndEscapeSequencesIntact() {
        let source = "let greeting = \"中文 \\\"quoted\\\"\" // comment\nlet count = 42"
        let text = NSMutableAttributedString(string: source)
        SyntaxHighlighter.apply(to: text, filePath: "Example.swift")
        #expect(text.string == source)
        #expect(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil)
        let comment = (source as NSString).range(of: "// comment")
        #expect(text.attribute(.foregroundColor, at: comment.location, effectiveRange: nil) as? NSColor == .systemGreen)
    }
}
