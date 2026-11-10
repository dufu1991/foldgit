import AppKit
import Shiki

struct SyntaxColorSpan: Equatable, Sendable {
    let range: NSRange
    let rgb: UInt32

    @MainActor var color: NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

/// Colors for one source line. `text` lets a view skip rows whose content changed since tokenization.
struct SyntaxLine: Equatable, Sendable {
    let text: String
    let spans: [SyntaxColorSpan]
}

/// Reuses compiled grammars and keeps synchronous tokenization off the main actor.
actor FileSyntaxHighlighter {
    static let shared = FileSyntaxHighlighter()
    private var highlighter: ShikiHighlighter?

    nonisolated func language(for path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let filenames = [
            "Dockerfile": "docker", "Containerfile": "docker", "Makefile": "make",
            "GNUmakefile": "make", "Gemfile": "ruby", "Rakefile": "ruby", "Package.resolved": "json",
            "CMakeLists.txt": "cmake", "COMMIT_EDITMSG": "git-commit", "MERGE_MSG": "git-commit",
            "SQUASH_MSG": "git-commit", "TAG_EDITMSG": "git-commit", "git-rebase-todo": "git-rebase",
            ".bashrc": "bash", ".bash_profile": "bash", ".zshrc": "zsh", ".profile": "bash",
            ".env": "dotenv",
        ]
        let extensions = [
            "h": "c", "hh": "cpp", "hpp": "cpp", "hxx": "cpp", "cc": "cpp", "cxx": "cpp",
            "m": "objective-c", "mm": "objective-cpp", "cs": "csharp", "kt": "kotlin", "kts": "kotlin",
            "mjs": "javascript", "cjs": "javascript", "mts": "typescript", "cts": "typescript",
            "svg": "xml", "plist": "xml", "xaml": "xml", "pyw": "python", "pyi": "python",
            "rb": "ruby", "env": "dotenv", "proto": "proto", "gql": "graphql",
            "ex": "elixir", "exs": "elixir", "sol": "solidity", "zon": "zig",
            "hs-boot": "haskell", "hsig": "haskell", "patch": "diff",
        ]
        let ext = url.pathExtension.lowercased()
        let candidate = filenames[url.lastPathComponent] ?? extensions[ext] ?? ext
        return BundledShikiAssets.shared.canonicalLanguageID(for: candidate)
    }

    func spans(in source: String, path: String, isDark: Bool = false) throws -> [SyntaxColorSpan] {
        guard let language = language(for: path) else { return [] }
        return try lines(in: source, language: language, isDark: isDark).flatMap { line in
            line.spans.map { SyntaxColorSpan(range: NSRange(location: line.offset + $0.range.location, length: $0.range.length), rgb: $0.rgb) }
        }
    }

    /// Keep only rows shown by the patch. A worktree file can change after Git generated it.
    func spansByLine(in source: String, language: String, isDark: Bool,
                     matching expectedLines: [Int: String]) throws -> [Int: SyntaxLine] {
        let lines = try lines(in: source, language: language, isDark: isDark)
        var result: [Int: SyntaxLine] = [:]
        for (number, expected) in expectedLines where number > 0 && number <= lines.count {
            let line = lines[number - 1]
            let text = expected.hasSuffix("\r") ? expected.dropLast() : Substring(expected)
            guard line.text.utf16.elementsEqual(text.utf16) else { continue }
            result[number] = SyntaxLine(text: expected, spans: line.spans)
        }
        return result
    }

    private struct TokenizedLine {
        let offset: Int
        let text: String
        /// Ranges relative to the start of the line.
        let spans: [SyntaxColorSpan]
    }

    private struct CacheKey: Hashable {
        let source: String
        let language: String
        let isDark: Bool
    }

    /// Refreshes and re-expanded diffs usually tokenize unchanged sources again.
    private var cache: [CacheKey: [TokenizedLine]] = [:]
    private var cacheOrder: [CacheKey] = []
    private var cacheBytes = 0
    private static let cacheByteLimit = 16 * 1024 * 1024

    private func lines(in source: String, language: String, isDark: Bool) throws -> [TokenizedLine] {
        try Task.checkCancellation()
        let key = CacheKey(source: source, language: language, isDark: isDark)
        if let lines = cache[key] {
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            return lines
        }
        // Release packaging (Scripts/trim-shiki-themes.py) ships only these two themes.
        let theme = isDark ? "github-dark" : "github-light"
        let engine = try highlighter ?? ShikiHighlighter(defaultTheme: theme)
        highlighter = engine
        let result = try engine.codeToTokens(source, language: language, theme: theme,
                                            options: .init(tokenizeMaxLineLength: FileContentReader.maximumLineLength))
        try Task.checkCancellation()
        let lines = result.tokens.map { tokens in
            let text = tokens.map(\.content).joined()
            let offset = tokens.first?.offset ?? 0
            let length = text.utf16.count
            return TokenizedLine(offset: offset, text: text,
                                 spans: tokens.compactMap { Self.span(for: $0, origin: offset, limit: length) })
        }
        store(lines, for: key)
        return lines
    }

    private func store(_ lines: [TokenizedLine], for key: CacheKey) {
        // The key and the line texts each hold a copy of the source.
        let bytes = key.source.utf8.count * 2
        guard bytes <= Self.cacheByteLimit else { return }
        while cacheBytes + bytes > Self.cacheByteLimit, !cacheOrder.isEmpty {
            let evicted = cacheOrder.removeFirst()
            cacheBytes -= evicted.source.utf8.count * 2
            cache[evicted] = nil
        }
        cache[key] = lines
        cacheOrder.append(key)
        cacheBytes += bytes
    }

    private static func span(for token: ThemedToken, origin: Int, limit: Int) -> SyntaxColorSpan? {
        let location = token.offset - origin
        let length = token.content.utf16.count
        guard location >= 0, length > 0, length <= limit - location,
              let color = token.color, color.count == 7, color.hasPrefix("#"),
              let rgb = UInt32(color.dropFirst(), radix: 16) else { return nil }
        return SyntaxColorSpan(range: NSRange(location: location, length: length), rgb: rgb)
    }
}
