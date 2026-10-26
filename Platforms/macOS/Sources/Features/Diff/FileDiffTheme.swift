import AppKit
import FoldGitCore

struct FileDiffTheme {
    private let preferredFontSize: CGFloat?
    init(fontSize: CGFloat? = nil) { preferredFontSize = fontSize }
    static var font: NSFont { NSFont.monospacedSystemFont(ofSize: AppPreferences.codeFontSize(), weight: .regular) }
    var font: NSFont { NSFont.monospacedSystemFont(ofSize: preferredFontSize ?? AppPreferences.codeFontSize(), weight: .regular) }

    func globalAttributes() -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }

    func backGroundColor(for kind: Chunk.Line.Kind) -> NSColor? {
        switch kind {
        case .removed: NSColor.systemRed.withAlphaComponent(0.1)
        case .added: NSColor.systemGreen.withAlphaComponent(0.2)
        case .header, .unchanged: nil
        }
    }

    func inlineBackgroundColor(for kind: Chunk.Line.Kind) -> NSColor? {
        switch kind {
        case .removed: NSColor.systemRed.withAlphaComponent(0.28)
        case .added: NSColor.systemGreen.withAlphaComponent(0.35)
        case .header, .unchanged: nil
        }
    }
}
