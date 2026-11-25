import AppKit
import FoldGitCore
import SwiftUI

struct MarkdownLocation: Hashable {
    let directory: URL
    let path: String
    var version: GitFileVersion = .workingTree

    func relativePath(_ target: String) -> String? {
        guard let components = URLComponents(string: target), components.scheme == nil, components.host == nil,
              !components.path.isEmpty, !components.path.hasPrefix("/") else { return nil }
        var parts = path.split(separator: "/").dropLast().map(String.init)
        for component in components.path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(component))
            }
        }
        let relative = parts.joined(separator: "/")
        guard !relative.isEmpty else { return nil }
        if version == .workingTree {
            let root = directory.resolvingSymlinksInPath().standardizedFileURL
            let file = root.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: file.path),
                  file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { return nil }
        }
        return relative
    }

    /// Decodes a repository image once per file version, so re-rendering on resize or appearance changes reuses it.
    func image(_ target: String) async -> DiffImage? {
        guard let path = relativePath(target), DiffImage.supports(path: path) else { return nil }
        let url = directory.appendingPathComponent(path)
        var key = "\(directory.path)\n\(version)\n\(path)"
        if version == .workingTree {
            // Working tree files can change on disk, so their cache entry follows the modification date.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            key += "\n\(modified?.timeIntervalSinceReferenceDate ?? 0)"
        }
        if let cached = MarkdownImageCache.shared.object(forKey: key as NSString) { return cached.image }
        let image: DiffImage?
        if version == .workingTree {
            image = await Task.detached {
                guard let file = try? FileContentReader.read(url, allowLarge: false),
                      case let .image(image) = file.content else { return nil as DiffImage? }
                return image
            }.value
        } else if let data = try? await GitFileContent.read(at: directory, path: path, version: version) {
            image = try? await Task.detached { try DiffImage.decode(data) }.value
        } else { image = nil }
        if let image {
            MarkdownImageCache.shared.setObject(.init(image), forKey: key as NSString, cost: image.byteCount)
        }
        return image
    }
}

private enum MarkdownImageCache {
    final class Entry: @unchecked Sendable {
        let image: DiffImage
        init(_ image: DiffImage) { self.image = image }
    }

    nonisolated(unsafe) static let shared: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
}

struct MarkdownPreview: View {
    let document: FileContentDocument
    let kind: PreviewDocumentKind
    let location: MarkdownLocation
    var findRequest: UUID?
    let openDocument: (String) -> Void
    @AppStorage(PreferenceKey.codeFontSize.rawValue) private var fontSize = AppPreferences.defaultCodeFontSize
    @Environment(\.colorScheme) private var scheme
    @State private var content: RenderedMarkdown?

    private struct ParsedMarkdown {
        let id: UUID
        let parts: [MarkdownPart]
    }

    @State private var parsed: ParsedMarkdown?

    private struct RenderKey: Hashable {
        let id: UUID
        let width: Int
        let dark: Bool
        let size: Double
    }

    var body: some View {
        GeometryReader { geometry in
            let key = RenderKey(id: document.id, width: max(64, Int(geometry.size.width) - 48), dark: scheme == .dark, size: fontSize)
            Group {
                if let content {
                    MarkdownReader(content: content, findRequest: findRequest) { target in
                        if let path = location.relativePath(target), PreviewDocumentKind(path: path) != nil { openDocument(path) }
                    }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .task(id: key) {
                // Coalesce live window resizing. A newly opened document renders immediately.
                if content != nil, parsed?.id == document.id {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                }
                let parts: [MarkdownPart]
                if let parsed, parsed.id == document.id { parts = parsed.parts }
                else {
                    guard let value = try? await MarkdownDocument.parse(document.text, kind: kind) else { return }
                    parsed = .init(id: document.id, parts: value)
                    parts = value
                }
                let result = await render(parts, key: key)
                if !Task.isCancelled { content = result }
            }
        }
        .accessibilityIdentifier("markdownPreview")
    }

    /// Loads every image the document may show in parallel instead of one at a time.
    private func loadImages(in parts: [MarkdownPart], dark: Bool) async -> [String: DiffImage] {
        let targets = Set(parts.flatMap { part -> [String] in
            guard case let .image(descriptor, _) = part else { return [] }
            return descriptor.targets(dark: dark)
        })
        guard !targets.isEmpty else { return [:] }
        let location = location
        return await withTaskGroup(of: (String, DiffImage?).self) { group in
            for target in targets { group.addTask { (target, await location.image(target)) } }
            var images: [String: DiffImage] = [:]
            for await (target, image) in group { if let image { images[target] = image } }
            return images
        }
    }

    @MainActor private func render(_ parts: [MarkdownPart], key: RenderKey) async -> RenderedMarkdown {
        var minimumWidth: CGFloat = 0
        let result = NSMutableAttributedString()
        var table: NSTextTable?
        var cell: NSTextTableBlock?
        let size = key.size + 2
        func append(_ text: String, _ style: MarkdownStyle = .init(), codeBlock: NSTextTableBlock? = nil) {
            let pointSize = style.heading == 0 ? size : size * max(1.05, 2.1 - Double(style.heading) * 0.18)
            var font = style.code ? NSFont.monospacedSystemFont(ofSize: key.size, weight: .regular)
                                  : NSFont.systemFont(ofSize: pointSize, weight: style.bold || style.heading > 0 ? .semibold : .regular)
            if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let paragraph = NSMutableParagraphStyle()
            if style.centered { paragraph.alignment = .center }
            paragraph.lineSpacing = 2
            paragraph.firstLineHeadIndent = CGFloat(style.indent * 16)
            paragraph.headIndent = paragraph.firstLineHeadIndent
            if let block = codeBlock ?? cell { paragraph.textBlocks = [block] }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
            if style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = style.link { attrs[.link] = link }
            if style.code && codeBlock == nil { attrs[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.08) }
            result.append(NSAttributedString(string: text, attributes: attrs))
        }
        func attach(_ image: NSImage, descriptor: MarkdownImage, style: MarkdownStyle) {
            var width = min(CGFloat(key.width), image.size.width)
            if let value = descriptor.width {
                let percent = value.hasSuffix("%")
                if let number = Double(percent ? String(value.dropLast()) : value), number.isFinite, number > 0 {
                    width = min(CGFloat(key.width), percent ? CGFloat(key.width) * number / 100 : number)
                }
            }
            image.size = NSSize(width: width, height: image.size.height * width / max(1, image.size.width))
            image.accessibilityDescription = descriptor.alt
            let attachment = NSTextAttachment()
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
            let offset = result.length
            append("\u{FFFC}", style)
            result.addAttribute(.attachment, value: attachment, range: NSRange(location: offset, length: 1))
        }
        let images = await loadImages(in: parts, dark: key.dark)
        for (index, part) in parts.enumerated() {
            if index.isMultiple(of: 64) { await Task.yield() }
            if Task.isCancelled { break }
            switch part {
            case let .text(value, style): append(value, style)
            case let .table(columns):
                minimumWidth = max(minimumWidth, CGFloat(columns) * 86 + 48)
                table = NSTextTable()
                table?.numberOfColumns = max(1, columns)
                table?.collapsesBorders = true
            case let .cell(row, column):
                if let table {
                    cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    cell?.setWidth(4, type: .absoluteValueType, for: .padding)
                    cell?.setWidth(1, type: .absoluteValueType, for: .border)
                    cell?.setBorderColor(.separatorColor)
                }
            case .endTable: cell = nil; table = nil
            case let .image(descriptor, style):
                // A new NSImage per render, since attaching it changes its display size.
                if let decoded = descriptor.targets(dark: key.dark).lazy.compactMap({ images[$0] }).first {
                    let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.pixelWidth, height: decoded.pixelHeight))
                    attach(image, descriptor: descriptor, style: style)
                }
                else { append(descriptor.alt.isEmpty ? descriptor.source : descriptor.alt, style) }
            case let .code(source, language, line):
                if language?.lowercased() == "mermaid" {
                    let attachment = DiagramAttachment()
                    attachment.source = source
                    attachment.dark = key.dark
                    attachment.width = key.width
                    attachment.line = line
                    attachment.fontSize = key.size
                    attachment.attachmentCell = NSTextAttachmentCell(textCell: "Mermaid…")
                    result.append(NSAttributedString(attachment: attachment))
                    append("\n\n")
                    continue
                }
                let offset = result.length
                let block = NSTextTableBlock(table: NSTextTable(), startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
                block.table.setContentWidth(100, type: .percentageValueType)
                block.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)
                block.setWidth(10, type: .absoluteValueType, for: .padding)
                for edge in [NSRectEdge.minX, .maxX] {
                    block.setWidth(14, type: .absoluteValueType, for: .padding, edge: edge)
                }
                append(source.hasSuffix("\n") ? source : source + "\n", .init(code: true), codeBlock: block)
                if let language, let spans = try? await FileSyntaxHighlighter.shared.spans(in: source, path: "block." + language, isDark: key.dark) {
                    for span in spans {
                        result.addAttribute(.foregroundColor, value: span.color, range: NSRange(location: offset + span.range.location, length: span.range.length))
                    }
                }
                append("\n")
            }
        }
        return RenderedMarkdown(text: result, minimumWidth: minimumWidth)
    }
}

private struct RenderedMarkdown {
    let text: NSAttributedString
    let minimumWidth: CGFloat
}

private final class MarkdownScrollView: NSScrollView {
    var minimumWidth: CGFloat = 0

    override func tile() {
        super.tile()
        guard let text = documentView as? NSTextView else { return }
        let width = max(minimumWidth, contentSize.width)
        if abs(text.frame.width - width) > 0.5 {
            text.setFrameSize(NSSize(width: width, height: text.frame.height))
        }
    }
}

private struct MarkdownReader: NSViewRepresentable {
    let content: RenderedMarkdown
    let findRequest: UUID?
    let openDocument: (String) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var content: NSAttributedString?
        var findRequest: UUID?
        var openDocument: ((String) -> Void)?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let target = (link as? URL)?.absoluteString ?? link as? String else { return true }
            if let url = URL(string: target), let scheme = url.scheme?.lowercased() {
                if ["http", "https", "mailto"].contains(scheme) { NSWorkspace.shared.open(url) }
            } else { openDocument?(target) }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MarkdownScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let text = MarkdownTextView(usingTextLayoutManager: false)
        text.isEditable = false
        text.isSelectable = true
        text.usesFindBar = true
        text.isVerticallyResizable = true
        text.autoresizingMask = []
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 18, height: 16)
        text.delegate = context.coordinator
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.openDocument = openDocument
        if coordinator.content !== content.text {
            (scroll as? MarkdownScrollView)?.minimumWidth = content.minimumWidth
            scroll.tile()
            coordinator.content = content.text
            text.textStorage?.setAttributedString(content.text)
        }
        if let findRequest, findRequest != coordinator.findRequest {
            coordinator.findRequest = findRequest
            text.window?.makeFirstResponder(text)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            text.performFindPanelAction(item)
        }
    }
}
