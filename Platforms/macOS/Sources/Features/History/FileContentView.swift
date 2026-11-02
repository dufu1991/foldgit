import AppKit
import HighlightSwift
import SwiftUI

struct FileContentView: View {
    var store: FileContentStore
    let path: String
    @AppStorage(PreferenceKey.codeFontSize.rawValue) private var fontSize = AppPreferences.defaultCodeFontSize
    @AppStorage(PreferenceKey.wrapLongLines.rawValue) private var wraps = false
    @State private var findRequest: UUID?
    @State private var highlightingFailed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Working Tree").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Find in File", systemImage: "magnifyingglass") { findRequest = UUID() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(!hasText)
                    .help("Find in File")
                if let metadata = store.metadata {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: metadata.size, countStyle: .file))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                OpenFileButton(filePath: path)
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
            switch store.state {
            case .idle, .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .requiresLoad:
                message("Large Text File", description: "Load the complete file as plain text. Syntax highlighting and line wrapping are disabled for performance.") {
                    Button("Load Plain Text") { store.load(allowLarge: true) }
                        .accessibilityIdentifier("loadFilePlainText")
                }
            case .text(let document):
                if highlightingFailed {
                    Text("Syntax highlighting is unavailable. The original text is shown.")
                        .font(.callout).foregroundStyle(.secondary).padding(8)
                }
                if document.plain {
                    Text("Syntax highlighting and line wrapping are disabled for this large file.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.bar)
                }
                if document.text.isEmpty {
                    message("Empty File", description: "This file contains no text.") { EmptyView() }
                } else {
                    FileContentTextViewer(document: document, path: path, fontSize: fontSize,
                                          wraps: wraps && !document.plain, findRequest: findRequest,
                                          onHighlightFailure: { highlightingFailed = true })
                        .accessibilityIdentifier("fileContentText")
                }
            case .missing:
                message("File No Longer Exists", description: "The selected file is no longer available in the working tree.") {
                    Button("Retry") { store.load() }
                }
            case .unavailable(let reason):
                message("Cannot Preview File", description: reason.description) {
                    Button("Open File") { openFile() }
                }
            case .failed(let reason):
                ContentUnavailableView {
                    Label("Could Not Read File", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: reason)
                } actions: {
                    Button("Retry") { store.load() }
                }
            }
        }
        .focusedSceneValue(\.fileMenu, fileMenu)
        .onChange(of: path) { highlightingFailed = false }
    }

    private var hasText: Bool {
        if case .text(let document) = store.state { return !document.text.isEmpty }
        return false
    }

    private var fileMenu: MenuActions? {
        guard hasText else { return nil }
        var actions = MenuActions()
        actions[.findInFile] = { findRequest = UUID() }
        return actions
    }

    @State private var openingError: Error?

    private func openFile() {
        if let url = store.url { openingError = FileOpening.open(url, using: NSWorkspace.shared.open) }
    }

    private func message(_ title: LocalizedStringKey, description: LocalizedStringKey,
                         @ViewBuilder actions: () -> some View) -> some View {
        ContentUnavailableView { Label(title, systemImage: "doc.text") } description: {
            Text(description)
        } actions: { actions() }
        .errorSheet($openingError, operation: "Open File")
    }
}

private extension FileContentRestriction {
    var description: LocalizedStringKey {
        switch self {
        case .tooLarge: "Files larger than 10 MiB must be opened externally."
        case .tooManyLines: "Files with more than 100,000 lines must be opened externally."
        case .lineTooLong: "This file contains a line that is too long to preview safely. Open it externally."
        case .binary: "Binary files and images must be opened externally."
        case .encoding: "This file uses an unsupported text encoding. Open it externally."
        case .notRegular: "Folders, symbolic links and special files must be opened externally."
        }
    }
}

/// A single native scroll container keeps TextKit 2 in charge of viewport layout.
struct FileContentTextViewer: NSViewRepresentable {
    let document: FileContentDocument
    let path: String
    let fontSize: Double
    let wraps: Bool
    var findRequest: UUID? = nil
    var onHighlightFailure: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let proposed = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 640, height: 480))
        return CGSize(width: proposed.width.isFinite ? proposed.width : 640,
                      height: proposed.height.isFinite ? proposed.height : 480)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FileContentScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let text = FileContentTextView(usingTextLayoutManager: true)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.allowsUndo = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 12, height: 8)
        text.isVerticallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = FileLineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        if let findRequest, findRequest != coordinator.findRequest {
            coordinator.findRequest = findRequest
            Task { @MainActor [weak text] in
                await Task.yield()
                guard coordinator.findRequest == findRequest, let text, let window = text.window else { return }
                window.makeFirstResponder(text)
                let action = NSMenuItem()
                action.tag = NSTextFinder.Action.showFindInterface.rawValue
                text.performFindPanelAction(action)
            }
        }
        let changedDocument = coordinator.documentID != document.id
        let isDark = context.environment.colorScheme == .dark
        let changedStyle = coordinator.fontSize != fontSize || coordinator.wraps != wraps || coordinator.isDark != isDark
        guard changedDocument || changedStyle else { return }
        coordinator.documentID = document.id
        coordinator.fontSize = fontSize
        coordinator.wraps = wraps
        coordinator.isDark = isDark
        coordinator.highlightTask?.cancel()
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = wraps
        text.autoresizingMask = wraps ? [.width] : []
        scroll.hasHorizontalScroller = !wraps
        text.textContainer?.widthTracksTextView = wraps
        text.textContainer?.containerSize = NSSize(
            width: wraps ? max(1, scroll.contentSize.width - 24) : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 4
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        if let ruler = scroll.verticalRulerView as? FileLineNumberRuler {
            ruler.update(lineStarts: document.layout.lineStarts, font: font)
        }
        text.setFrameSize(NSSize(
            width: wraps ? max(1, scroll.contentSize.width) : max(scroll.contentSize.width, CGFloat(document.layout.maximumColumns) * spaceWidth + 32),
            height: wraps ? max(1, scroll.contentSize.height) : max(scroll.contentSize.height, CGFloat(document.layout.lineCount) * lineHeight + 16)))
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.defaultTabInterval = spaceWidth * 4
        paragraph.tabStops = []
        paragraph.baseWritingDirection = .leftToRight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph,
        ]
        if changedDocument {
            text.textStorage?.setAttributedString(NSAttributedString(string: document.text, attributes: attributes))
            text.setSelectedRange(NSRange(location: 0, length: 0))
            scroll.contentView.scroll(to: .zero)
        } else if let storage = text.textStorage {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        text.font = font
        if !document.plain {
            coordinator.highlight(document: document, path: path, isDark: isDark,
                                  textView: text, onFailure: onHighlightFailure)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()
    }

    @MainActor final class Coordinator {
        var documentID: UUID?
        var fontSize: Double?
        var wraps: Bool?
        var isDark: Bool?
        var findRequest: UUID?
        var highlightTask: Task<Void, Never>?

        func highlight(document: FileContentDocument, path: String, isDark: Bool,
                       textView: NSTextView, onFailure: (() -> Void)?) {
            highlightTask = Task { [weak textView] in
                let spans: [HighlightSwift.SyntaxSpan]
                do {
                    spans = try await FileSyntaxHighlighter.shared.spans(in: document.text, path: path)
                } catch {
                    if !Task.isCancelled, documentID == document.id { onFailure?() }
                    return
                }
                var palette = FileSyntaxPalette(isDark: isDark)
                // Yield between bounded batches so selection and scrolling can respond immediately.
                for start in stride(from: 0, to: spans.count, by: 256) {
                    guard !Task.isCancelled, documentID == document.id, let storage = textView?.textStorage else { return }
                    storage.beginEditing()
                    for span in spans[start..<min(start + 256, spans.count)] {
                        storage.addAttribute(.foregroundColor, value: palette.color(for: span.scopes), range: span.range)
                    }
                    storage.endEditing()
                    await Task.yield()
                }
            }
        }
    }
}

private final class FileContentScrollView: NSScrollView {
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        verticalRulerView?.needsDisplay = true
    }
    override func tile() {
        super.tile()
        guard let text = documentView as? NSTextView else { return }
        let width = max(1, contentSize.width)
        if text.textContainer?.widthTracksTextView == true {
            text.setFrameSize(NSSize(width: width, height: max(text.frame.height, contentSize.height)))
        }
    }
}

private final class FileLineNumberRuler: NSRulerView {
    private var lineStarts = [0]
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    override var isFlipped: Bool { true }

    func update(lineStarts: [Int], font: NSFont) {
        self.lineStarts = lineStarts
        self.font = NSFont.monospacedSystemFont(ofSize: max(9, font.pointSize - 1), weight: .regular)
        ruleThickness = max(38, CGFloat(String(lineStarts.count).count) * self.font.maximumAdvancement.width + 16)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let rulerBounds = NSRect(x: 0, y: bounds.minY, width: ruleThickness, height: bounds.height)
        NSBezierPath(rect: rulerBounds).addClip()
        NSColor.textBackgroundColor.setFill()
        rulerBounds.intersection(rect).fill()
        guard let text = scrollView?.documentView as? NSTextView,
              let manager = text.textLayoutManager, let content = text.textContentStorage,
              let viewport = manager.textViewportLayoutController.viewportRange else { return }
        let visible = text.visibleRect
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let y = fragment.layoutFragmentFrame.minY + text.textContainerOrigin.y
            if y > visible.maxY { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            var lower = 0
            var upper = self.lineStarts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if self.lineStarts[middle] <= offset { lower = middle + 1 }
                else { upper = middle }
            }
            let label = String(max(1, lower)) as NSString
            let baseline = fragment.textLineFragments.first.map {
                y + $0.typographicBounds.minY + $0.glyphOrigin.y
            } ?? y + self.font.ascender
            let point = self.convert(NSPoint(x: 0, y: baseline - self.font.ascender), from: text)
            label.draw(at: NSPoint(x: self.ruleThickness - label.size(withAttributes: attributes).width - 8, y: point.y),
                       withAttributes: attributes)
            return true
        }
    }
}

private final class FileContentTextView: NSTextView {
    // The default getter can ensure layout for the entire document while finding its origin.
    // Code is always aligned to the top-left, so the origin never depends on document layout.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: textContainerInset.height)
    }
}
