import Foundation
import Markdown

enum PreviewDocumentKind: String {
    case markdown, mermaid

    init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdx": self = .markdown
        case "mmd", "mermaid": self = .mermaid
        default: return nil
        }
    }
}

struct MarkdownStyle: Sendable {
    var heading = 0
    var bold = false
    var italic = false
    var strike = false
    var code = false
    var indent = 0
    var link: String?
}

enum MarkdownPart: Sendable {
    case text(String, MarkdownStyle)
    case code(String, language: String?, line: Int)
    case image(String, alt: String)
    case table(columns: Int)
    case cell(row: Int, column: Int)
    case endTable
}

enum MarkdownDocument {
    static func parse(_ source: String, kind: PreviewDocumentKind) async throws -> [MarkdownPart] {
        if kind == .mermaid { return [.code(source, language: "mermaid", line: 1)] }
        let task = Task.detached(priority: .userInitiated) {
            var parts = [MarkdownPart]()
            try append(Document(parsing: source), style: .init(), to: &parts)
            return parts
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func append(_ node: Markup, style: MarkdownStyle, to parts: inout [MarkdownPart]) throws {
        try Task.checkCancellation()
        var style = style
        var suffix = ""
        switch node {
        case let text as Markdown.Text: parts.append(.text(text.string, style)); return
        case let code as InlineCode:
            style.code = true
            parts.append(.text(code.code, style)); return
        case let code as CodeBlock:
            parts.append(.code(code.code, language: code.language?.split(whereSeparator: \.isWhitespace).first.map(String.init),
                               line: (code.range?.lowerBound.line ?? 0) + 1))
            return
        case let image as Markdown.Image:
            parts.append(.image(image.source ?? "", alt: image.plainText)); return
        case let link as Markdown.Link: style.link = link.destination
        case is Strong: style.bold = true
        case is Emphasis: style.italic = true
        case is Strikethrough: style.strike = true
        case let heading as Heading: style.heading = heading.level; suffix = "\n\n"
        case is Paragraph: suffix = "\n\n"
        case is SoftBreak: parts.append(.text(" ", style)); return
        case is LineBreak: parts.append(.text("\n", style)); return
        case is ThematicBreak: parts.append(.text("────────\n\n", style)); return
        case is BlockQuote: style.indent += 1; style.italic = true
        case let item as ListItem:
            style.indent += 1
            let marker: String
            if let checkbox = item.checkbox { marker = checkbox == .checked ? "☑" : "☐" }
            else if let list = item.parent as? OrderedList { marker = "\(Int(list.startIndex) + item.indexInParent)." }
            else { marker = "•" }
            parts.append(.text(marker + " ", style))
        case let table as Table:
            parts.append(.table(columns: table.maxColumnCount))
            let rows = [table.head as Markup] + table.body.children.map { $0 as Markup }
            for (row, cells) in rows.enumerated() {
                for (column, cell) in cells.children.enumerated() {
                    parts.append(.cell(row: row, column: column))
                    var cellStyle = style
                    cellStyle.bold = row == 0
                    try append(cell, style: cellStyle, to: &parts)
                    parts.append(.text("\n", cellStyle))
                }
            }
            parts.append(.endTable)
            parts.append(.text("\n", style))
            return
        case let html as HTMLBlock: parts.append(.text(html.rawHTML + "\n", style)); return
        case let html as InlineHTML: parts.append(.text(html.rawHTML, style)); return
        default: break
        }
        for child in node.children { try append(child, style: style, to: &parts) }
        if !suffix.isEmpty { parts.append(.text(suffix, style)) }
    }
}
