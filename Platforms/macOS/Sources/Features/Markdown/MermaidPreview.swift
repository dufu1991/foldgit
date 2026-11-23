import AppKit
import NornaKit

private final class DiagramProof: NSObject {
    let artifact: DiagramArtifact
    let pdf: Data

    init(artifact: DiagramArtifact, pdf: Data) {
        self.artifact = artifact
        self.pdf = pdf
    }
}

actor MermaidPreview {
    static let shared = MermaidPreview()
    private let cache = NSCache<NSString, DiagramProof>()
    private let renderer = NativeDiagramRenderer()

    private init() {
        cache.countLimit = 24
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    func render(source: String, width: Int, dark: Bool) async throws -> (DiagramArtifact, Data) {
        let key = "\(width)/\(dark)/\(source)" as NSString
        if let proof = cache.object(forKey: key) { return (proof.artifact, proof.pdf) }
        let artifact = try await renderer.render(source, options: .init(maxWidth: Double(max(160, width))))
        try Task.checkCancellation()
        let pdf = try DiagramExporter.data(for: artifact.scene, theme: dark ? .appleDark : .appleLight,
                                               colorStyle: .themed, options: .init(format: .pdf, background: .transparent))
        cache.setObject(DiagramProof(artifact: artifact, pdf: pdf), forKey: key, cost: pdf.count + source.utf8.count)
        return (artifact, pdf)
    }
}

final class DiagramAttachment: NSTextAttachment {
    var diagram: DiagramArtifact?
    var source = ""
    var dark = false
    var width = 0
    var line = 1
    var fontSize = 12.0
    var loading = false
}

@MainActor final class MarkdownTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let storage = textStorage, let layoutManager, let textContainer else { return }
        let visible = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let range = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.attachment, in: range) { value, range, _ in
            guard let attachment = value as? DiagramAttachment, !attachment.loading, attachment.diagram == nil else { return }
            attachment.loading = true
            Task { [weak self] in
                await self?.load(attachment, near: range.location)
            }
        }
    }

    private func load(_ attachment: DiagramAttachment, near index: Int) async {
        let replacement: NSAttributedString
        do {
            let (diagram, pdf) = try await MermaidPreview.shared.render(source: attachment.source, width: attachment.width, dark: attachment.dark)
            guard let image = NSImage(data: pdf) else { throw CocoaError(.fileReadCorruptFile) }
            let scale = min(1, CGFloat(attachment.width) / max(1, image.size.width))
            image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            attachment.diagram = diagram
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
            replacement = NSAttributedString(attachment: attachment)
        } catch {
            let position = (error as? DiagramRenderError)?.line.map { " · L\(attachment.line + $0 - 1)" } ?? ""
            let fallback = NSMutableAttributedString(string: String(localized: "Diagram preview unavailable") + position + "\n",
                                                    attributes: [.foregroundColor: NSColor.secondaryLabelColor])
            let offset = fallback.length
            fallback.append(NSAttributedString(string: attachment.source, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: attachment.fontSize, weight: .regular), .foregroundColor: NSColor.textColor
            ]))
            if let spans = try? await FileSyntaxHighlighter.shared.spans(in: attachment.source, path: "block.mermaid", isDark: attachment.dark) {
                for span in spans {
                    fallback.addAttribute(.foregroundColor, value: span.color, range: NSRange(location: offset + span.range.location, length: span.range.length))
                }
            }
            replacement = fallback
        }
        guard let storage = textStorage else { return }
        var location: Int?
        if index < storage.length, storage.attribute(.attachment, at: index, effectiveRange: nil) as? DiagramAttachment === attachment {
            location = index
        } else {
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if value as? DiagramAttachment === attachment { location = range.location; stop.pointee = true }
            }
        }
        if let location {
            storage.replaceCharacters(in: NSRange(location: location, length: 1), with: replacement)
            needsDisplay = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        guard let layoutManager, let textContainer else { return menu }
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y),
                                            in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return menu }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard let storage = textStorage, index < storage.length,
              let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? DiagramAttachment else { return menu }
        menu.addItem(.separator())
        for (title, action, tag) in [(String(localized: "Copy Source"), #selector(copyDiagram), 0),
                                     (String(localized: "Export PNG"), #selector(exportDiagram), 0),
                                     (String(localized: "Export SVG"), #selector(exportDiagram), 1)] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = attachment
            item.tag = tag
        }
        return menu
    }

    @objc private func copyDiagram(_ sender: NSMenuItem) {
        guard let attachment = sender.representedObject as? DiagramAttachment else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(attachment.source, forType: .string)
    }

    @objc private func exportDiagram(_ sender: NSMenuItem) {
        guard let attachment = sender.representedObject as? DiagramAttachment, let diagram = attachment.diagram else { return }
        let format: DiagramExportFormat = sender.tag == 1 ? .svg : .png
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "diagram." + format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try DiagramExporter.data(for: diagram.scene, theme: attachment.dark ? .appleDark : .appleLight,
                                                options: .init(format: format))
            try data.write(to: url, options: .atomic)
        } catch { presentError(error) }
    }
}
