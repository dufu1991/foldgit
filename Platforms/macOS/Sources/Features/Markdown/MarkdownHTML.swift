import Foundation
import Markdown
import SwiftSoup

struct MarkdownImage: Sendable {
    let source: String
    let alt: String
    var lightSource: String?
    var darkSource: String?
    var width: String?

    func targets(dark: Bool) -> [String] {
        let preferred = dark ? darkSource : lightSource
        return [preferred == source ? nil : preferred, source].compactMap { $0 }.filter { !$0.isEmpty }
    }
}

extension MarkdownDocument {
    // Parse sibling HTML tags together so that wrappers can also style native Markdown children.
    static func appendChildren(of parent: Markup, style: MarkdownStyle, to parts: inout [MarkdownPart]) throws {
        let children = parent.children
        guard children.contains(where: { $0 is InlineHTML || $0 is HTMLBlock }) else {
            for child in children { try append(child, style: style, to: &parts) }
            return
        }
        let marker = "foldgit-" + UUID().uuidString.lowercased()
        var fragment = ""
        var content = [Markup]()
        for child in children {
            if let html = child as? InlineHTML { fragment += html.rawHTML }
            else if let html = child as? HTMLBlock {
                fragment += html.rawHTML + "<\(marker)></\(marker)>"
            } else {
                fragment += "<\(marker) index='\(content.count)'></\(marker)>"
                content.append(child)
            }
        }
        guard let body = try SwiftSoup.parseBodyFragment(fragment).body() else { return }
        func visit(_ node: Node, style: MarkdownStyle) throws {
            try Task.checkCancellation()
            if let text = node as? TextNode {
                let value = text.text()
                if !value.isEmpty { parts.append(.text(value, style)) }
                return
            }
            guard let element = node as? Element else { return }
            var style = style
            let tag = element.tagName()
            if try element.attr("align").lowercased() == "center" { style.centered = true }
            switch tag {
            case marker:
                if let index = Int(try element.attr("index")), content.indices.contains(index) {
                    try append(content[index], style: style, to: &parts)
                } else if !parts.isEmpty {
                    if case let .text(text, _) = parts.last, text.hasSuffix("\n") { return }
                    parts.append(.text("\n\n", style))
                }
                return
            case "script", "style", "iframe", "template", "object", "head": return
            case "br": parts.append(.text("\n", style)); return
            case "a": style.link = try element.attr("href")
            case "b", "strong": style.bold = true
            case "i", "em": style.italic = true
            case "code": style.code = true
            case "center": style.centered = true
            case "h1", "h2", "h3", "h4", "h5", "h6": style.heading = Int(tag.dropFirst()) ?? 1
            case "picture", "img":
                guard let img = tag == "img" ? element : try element.select("img").first() else { return }
                var image = MarkdownImage(source: try img.attr("src"), alt: try img.attr("alt"), width: try img.attr("width"))
                if tag == "picture" {
                    for source in try element.select("source[srcset]") {
                        let media = try source.attr("media").lowercased().filter { !$0.isWhitespace }
                        let srcset = try source.attr("srcset")
                        guard let url = srcset.split(separator: ",").first?.split(whereSeparator: \.isWhitespace).first else { continue }
                        if image.lightSource == nil && (media.isEmpty || media == "(prefers-color-scheme:light)") { image.lightSource = String(url) }
                        if image.darkSource == nil && (media.isEmpty || media == "(prefers-color-scheme:dark)") { image.darkSource = String(url) }
                    }
                }
                parts.append(.image(image, style)); return
            default: break
            }
            for child in element.getChildNodes() { try visit(child, style: style) }
            if ["p", "div", "center", "tr", "h1", "h2", "h3", "h4", "h5", "h6"].contains(tag) { parts.append(.text("\n", style)) }
        }
        for child in body.getChildNodes() { try visit(child, style: style) }
    }
}
