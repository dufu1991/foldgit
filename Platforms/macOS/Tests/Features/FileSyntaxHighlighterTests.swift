import FoldGitCore
import Foundation
import Testing
@testable import FoldGit

struct FileSyntaxHighlighterTests {
    @Test func filenameDetectionCoversCommonLanguagesWithoutGuessing() async throws {
        let highlighter = FileSyntaxHighlighter.shared
        for path in ["main.swift", "package.json", "index.js", "App.tsx", "App.vue", "index.html", "main.css",
                     "main.scss", "App.cs", "Main.java", "Main.kt", "main.go", "main.rs", "main.cpp", "main.h",
                     "main.py", "main.rb", "index.php", "script.sh", "config.yaml", "config.toml", "query.sql",
                     "README.md", "Dockerfile", "Makefile", "Package.resolved"] {
            #expect(highlighter.language(for: path) != nil, "Missing language for \(path)")
        }
        #expect(highlighter.language(for: "App.vue") == "vue")
        #expect(highlighter.language(for: "notes.unknown") == nil)
        #expect(try await highlighter.spans(in: "let untouched = true", path: "notes.unknown").isEmpty)
    }

    @Test func colorsPreserveUTF16RangesAndFollowAppearance() async throws {
        let source = "\n\t{\"名称\": \"中文 😀\", \"count\": 42, \"enabled\": true}\r\n\n"
        let highlighter = FileSyntaxHighlighter.shared
        let light = try await highlighter.spans(in: source, path: "package.json")
        let dark = try await highlighter.spans(in: source, path: "package.json", isDark: true)
        let text = source as NSString
        let value = text.range(of: "中文 😀")
        let number = text.range(of: "42")
        let color = { (range: NSRange, spans: [SyntaxColorSpan]) in
            spans.first { NSIntersectionRange($0.range, range).length > 0 }?.rgb
        }
        #expect(color(value, light) != nil)
        #expect(color(number, light) != nil)
        #expect(color(value, light) != color(number, light))
        #expect(color(value, light) != color(value, dark))
        for span in light + dark {
            #expect(NSMaxRange(span.range) <= text.length)
            #expect(Range(span.range, in: source) != nil)
        }
    }

    @Test(arguments: [
        ("infra.tf", "terraform"), ("flake.nix", "nix"), ("app.ex", "elixir"), ("mix.exs", "elixir"),
        ("main.zig", "zig"), ("build.zig.zon", "zig"), ("Main.hs", "haskell"), ("Counter.sol", "solidity"),
        ("CMakeLists.txt", "cmake"), ("change.diff", "diff"), ("change.patch", "diff"),
        ("COMMIT_EDITMSG", "git-commit"), ("git-rebase-todo", "git-rebase"),
    ])
    func detectsBundledLanguagesAndGitFormats(path: String, language: String) {
        #expect(FileSyntaxHighlighter.shared.language(for: path) == language)
    }

    @Test func changedSourceIsNotUsedToColorStaleDiffRows() async throws {
        let spans = try await FileSyntaxHighlighter.shared.spansByLine(
            in: "/*\r\nnew 😀\r\n*/\r\n", language: "swift", isDark: false,
            matching: [1: "/*\r", 2: "old 😀\r", 3: "*/\r"]
        )
        #expect(spans[1]?.spans.isEmpty == false)
        #expect(spans[2] == nil)
        #expect(spans[3]?.spans.isEmpty == false)
    }

    @Test func cachedTokensServeLaterRequestsWithTheSameColors() async throws {
        let source = "let value = \"cached\" // note\n"
        let first = try await FileSyntaxHighlighter.shared.spans(in: source, path: "Cache.swift")
        let lines = try await FileSyntaxHighlighter.shared.spansByLine(
            in: source, language: "swift", isDark: false, matching: [1: "let value = \"cached\" // note"])
        #expect(!first.isEmpty)
        #expect(lines[1]?.spans == first)
    }

    @Test @MainActor func diffColorsSkipRowsWhoseTextChanged() {
        let span = SyntaxColorSpan(range: NSRange(location: 0, length: 3), rgb: 0xCF222E)
        let colors = DiffSyntaxColors(before: [4: SyntaxLine(text: "let old", spans: [span])],
                                      after: [7: SyntaxLine(text: "let new", spans: [span])])
        let removed = SideBySideDiff.Cell(text: "-let old", kind: .removed, oldLineNumber: 4)
        #expect(colors.spans(for: removed, oldSide: false, prefixLength: 1) == [span])
        #expect(colors.spans(for: .init(text: "let new", lineNumber: 7, kind: .added), oldSide: false) == [span])
        #expect(colors.spans(for: .init(text: "let old", lineNumber: 4, kind: .removed), oldSide: true) == [span])
        #expect(colors.spans(for: .init(text: "let edited", lineNumber: 7, kind: .added), oldSide: false) == nil)
    }
}
