import AppKit
import HighlightSwift

/// Serializes access to the shared JavaScript context while keeping it off the main actor.
actor FileSyntaxHighlighter {
    static let shared = FileSyntaxHighlighter()
    private let highlighter = Highlight()
    private var aliases: Set<String>?

    func language(for path: String) async throws -> String? {
        if aliases == nil { aliases = try await highlighter.languageAliases() }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let filenames = [
            "Dockerfile": "dockerfile", "Containerfile": "dockerfile", "Makefile": "makefile",
            "GNUmakefile": "makefile", "Gemfile": "ruby", "Rakefile": "ruby", "Package.resolved": "json",
            ".bashrc": "bash", ".bash_profile": "bash", ".zshrc": "bash", ".profile": "bash",
            ".env": "ini",
        ]
        let extensions = [
            "h": "c", "hh": "cpp", "hpp": "cpp", "hxx": "cpp", "cc": "cpp", "cxx": "cpp",
            "m": "objectivec", "mm": "objectivec", "cs": "csharp", "kt": "kotlin", "kts": "kotlin",
            "mjs": "javascript", "cjs": "javascript", "jsx": "javascript", "tsx": "typescript",
            "mts": "typescript", "cts": "typescript", "vue": "xml", "svelte": "xml", "svg": "xml",
            "plist": "xml", "xaml": "xml", "jsonc": "json", "json5": "json", "jsonl": "json",
            "pyw": "python", "pyi": "python", "rb": "ruby", "zsh": "bash", "env": "ini",
            "proto": "protobuf", "gql": "graphql",
        ]
        let ext = url.pathExtension.lowercased()
        let candidate = filenames[name] ?? extensions[ext] ?? ext
        return aliases?.contains(candidate) == true ? candidate : nil
    }

    func spans(in source: String, path: String) async throws -> [SyntaxSpan] {
        try Task.checkCancellation()
        guard let language = try await language(for: path) else { return [] }
        try Task.checkCancellation()
        let spans = try await highlighter.syntaxSpans(source, language: language)
        try Task.checkCancellation()
        return spans
    }
}

/// Resolves the upstream Xcode CSS colors over the emitter's nested scopes.
@MainActor
struct FileSyntaxPalette {
    private struct Rule {
        let selector: [Set<String>]
        let specificity: Int
        let color: NSColor

        func matches(_ scopes: [Set<String>]) -> Bool {
            guard let last = selector.last, let leaf = scopes.last, last.isSubset(of: leaf) else { return false }
            var scopeIndex = scopes.count - 2
            for required in selector.dropLast().reversed() {
                while scopeIndex >= 0 && !required.isSubset(of: scopes[scopeIndex]) { scopeIndex -= 1 }
                guard scopeIndex >= 0 else { return false }
                scopeIndex -= 1
            }
            return true
        }
    }

    private var rules: [Rule] = []
    private var cache: [String: NSColor] = [:]

    init(isDark: Bool) {
        let css = (isDark ? HighlightColors.dark(.xcode) : .light(.xcode)).css
        let blocks = try! NSRegularExpression(pattern: #"([^{}]+)\{([^{}]*)\}"#)
        let colors = try! NSRegularExpression(pattern: #"(?:^|;)\s*color\s*:\s*([^;]+)"#)
        let classes = try! NSRegularExpression(pattern: #"\.([\w-]+)"#)
        let source = css as NSString
        for block in blocks.matches(in: css, range: NSRange(location: 0, length: source.length)) {
            let body = source.substring(with: block.range(at: 2)) as NSString
            guard let colorMatch = colors.firstMatch(in: body as String, range: NSRange(location: 0, length: body.length)),
                  let color = Self.color(body.substring(with: colorMatch.range(at: 1))) else { continue }
            for selector in source.substring(with: block.range(at: 1)).split(separator: ",") {
                let parts = selector.split(whereSeparator: \.isWhitespace).map { part -> Set<String> in
                    let text = part.description as NSString
                    let matches = classes.matches(in: part.description, range: NSRange(location: 0, length: text.length))
                    let names = matches.map { text.substring(with: $0.range(at: 1)) }
                    return Set(names.isEmpty ? [part.description] : names)
                }
                guard !parts.isEmpty else { continue }
                rules.append(Rule(selector: parts, specificity: parts.reduce(0) { $0 + $1.count }, color: color))
            }
        }
    }

    mutating func color(for scopes: [String]) -> NSColor {
        let key = scopes.joined(separator: " ")
        if let cached = cache[key] { return cached }
        let classes = scopes.map { scope -> Set<String> in
            if scope.hasPrefix("language:") { return [String(scope.dropFirst(9))] }
            let parts = scope.split(separator: ".")
            guard let first = parts.first else { return [] }
            return Set(["hljs-" + first] + parts.dropFirst().enumerated().map {
                $0.element + String(repeating: "_", count: $0.offset + 1)
            })
        }
        var color = NSColor.textColor
        for depth in classes.indices {
            let parents = Array(classes.prefix(depth + 1))
            var specificity = -1
            for rule in rules where rule.specificity >= specificity && rule.matches(parents) {
                color = rule.color
                specificity = rule.specificity
            }
        }
        cache[key] = color
        return color
    }

    private static func color(_ value: String) -> NSColor? {
        let named = ["white": "ffffff", "black": "000000", "silver": "c0c0c0"]
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        hex = named[hex] ?? hex.replacingOccurrences(of: "#", with: "")
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
