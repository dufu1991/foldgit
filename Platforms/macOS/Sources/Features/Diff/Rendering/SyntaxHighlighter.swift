import AppKit

/// A token pass shared by both diff layouts. It never changes source text.
@MainActor
enum SyntaxHighlighter {
    // NSRegularExpression matches UTF-16 directly, avoiding String-to-NSRange conversion per token.
    // Strings stop at line ends, so an apostrophe in prose cannot color the following lines.
    private static let expression = try! NSRegularExpression(
        pattern: #"(?:"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`)|(?://[^\n]*|/\*[\s\S]*?\*/|\(\*[\s\S]*?\*\)|#[^\n]*)|\b(?:0x[\da-fA-F]+|\d+(?:\.\d+)?)\b|\b(?:actor|async|await|as|break|case|catch|class|const|continue|def|defer|do|else|enum|export|extension|false|final|for|from|func|function|guard|if|import|in|init|interface|internal|is|let|module|mut|nil|nonisolated|null|open|override|package|private|protocol|public|return|self|some|static|struct|super|switch|throw|throws|trait|true|try|type|typealias|var|void|where|while|with|yield)\b"#
    )

    static func apply(to text: NSMutableAttributedString, filePath: String) {
        guard let language = Language.detect(filePath: filePath) else { return }
        let hashComments = language == .python || language == .shell || language == .ruby || language == .perl
        let source = text.string as NSString
        for match in expression.matches(in: text.string, range: NSRange(location: 0, length: source.length)) {
            let first = source.character(at: match.range.location)
            let color: NSColor
            switch Character(UnicodeScalar(first) ?? " ") {
            case "#":
                guard hashComments else { continue }
                color = .systemGreen
            case "/", "(":
                color = .systemGreen
            case "\"", "'", "`":
                color = .systemRed
            case "0"..."9":
                color = .systemPurple
            default:
                color = .systemPink
            }
            text.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
