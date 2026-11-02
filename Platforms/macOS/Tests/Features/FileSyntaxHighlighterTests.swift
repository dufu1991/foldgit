import AppKit
import HighlightSwift
import Testing
@testable import FoldGit

struct FileSyntaxHighlighterTests {
    @Test func filenameDetectionCoversCommonLanguagesWithoutGuessing() async throws {
        for path in ["main.swift", "package.json", "index.js", "App.tsx", "App.vue", "index.html", "main.css",
                     "main.scss", "App.cs", "Main.java", "Main.kt", "main.go", "main.rs", "main.cpp", "main.h",
                     "main.py", "main.rb", "index.php", "script.sh", "config.yaml", "config.toml", "query.sql",
                     "README.md", "Dockerfile", "Makefile", "Package.resolved"] {
            #expect(try await FileSyntaxHighlighter.shared.language(for: path) != nil)
        }
        #expect(try await FileSyntaxHighlighter.shared.language(for: "notes.unknown") == nil)
        #expect(try await FileSyntaxHighlighter.shared.spans(in: "let untouched = true", path: "notes.unknown").isEmpty)
        #expect(try await Highlight().languageAliases().count > 50)
    }

    @Test func syntaxScopesDistinguishJSONKeysStringsNumbersAndBooleans() async throws {
        let source = "\n\t{\"名称\": \"中文 😀\", \"count\": 42, \"enabled\": true, \"nothing\": null}\r\n\n"
        let spans = try await FileSyntaxHighlighter.shared.spans(in: source, path: "package.json")
        let scopes = Set(spans.flatMap(\.scopes))
        #expect(scopes.isSuperset(of: ["attr", "string", "number", "literal"]))
        let text = source as NSString
        #expect(spans.contains { text.substring(with: $0.range) == "42" && $0.scopes.contains("number") })
        #expect(spans.contains { text.substring(with: $0.range) == "true" && $0.scopes.contains("literal") })
        #expect(spans.contains { text.substring(with: $0.range).contains("中文 😀") && $0.scopes.contains("string") })
        #expect(spans.allSatisfy { NSMaxRange($0.range) <= text.length })
    }

    @Test func whitespaceEscapesUnicodeAndNestedLanguagesKeepOriginalRanges() async throws {
        let highlighter = Highlight()
        let samples = [
            ("swift", "\r\n\tlet title = \"中文 😀 & < > \\\"quoted\\\"\"\r\n\r\n"),
            ("javascript", "\n  const greeting = `中文 😀 ${name}`;\n\t"),
            ("xml", "\n  <script>const value = 42</script><style>.item { color: red }</style>\r\n"),
            ("markdown", "\n# 中文 😀\n\n```swift\nlet count = 1\n```\n\n"),
            ("swift", "\n\t  \r\n"), ("swift", ""),
        ]
        for (language, source) in samples {
            let spans = try await highlighter.syntaxSpans(source, language: language)
            let length = source.utf16.count
            var previousEnd = 0
            for span in spans {
                #expect(span.range.location >= previousEnd)
                #expect(NSMaxRange(span.range) <= length)
                #expect(Range(span.range, in: source) != nil)
                previousEnd = NSMaxRange(span.range)
            }
        }
    }

    @Test @MainActor func xcodePaletteDistinguishesScopesAndFollowsAppearance() {
        var light = FileSyntaxPalette(isDark: false)
        var dark = FileSyntaxPalette(isDark: true)
        let key = light.color(for: ["attr"])
        let string = light.color(for: ["string"])
        let number = light.color(for: ["number"])
        #expect(key != string)
        #expect(string != number)
        #expect(key != number)
        #expect(light.color(for: ["keyword"]) != dark.color(for: ["keyword"]))
        #expect(light.color(for: ["title.class"]) != light.color(for: ["title"]))
    }

    @Test func largeHighlightingRunsAwayFromTheUIActorAndCanBeCancelled() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FileSyntaxHighlighter.shared.spans(in: "let count = 1", path: "test.swift")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let source = String(repeating: "{\"name\":\"中文 😀\",\"count\":42,\"enabled\":true}\n", count: 12_000)
        let start = ContinuousClock.now
        let spans = try await FileSyntaxHighlighter.shared.spans(in: source, path: "large.json")
        #expect(spans.count > 12_000)
        print("HighlightSwift span benchmark: \(source.utf8.count) bytes, \(spans.count) spans, \(start.duration(to: .now))")
    }
}
