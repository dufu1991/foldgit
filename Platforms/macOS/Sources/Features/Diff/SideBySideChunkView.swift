import AppKit
import FoldGitCore
import SwiftUI

struct SideBySideChunkView: View {
    let diff: SideBySideDiff
    let filePath: String
    @AppStorage(PreferenceKey.codeFontSize.rawValue) private var fontSize = AppPreferences.defaultCodeFontSize
    @AppStorage(PreferenceKey.wrapLongLines.rawValue) private var wrapLongLines = false
    @State private var viewportWidth: CGFloat = 0

    private var layout: DiffCodeLayout {
        DiffCodeLayout(rows: diff.rows, columnWidth: max(120, (viewportWidth - 1) / 2),
                       fontSize: fontSize, wraps: wrapLongLines)
    }

    var body: some View {
        let layout = layout
        return VStack(alignment: .leading, spacing: 0) {
            Text(diff.header)
                .font(.system(size: FileDiffTheme.font.pointSize, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            HStack(spacing: 0) {
                column(title: "Before", cells: diff.rows.map(\.old), layout: layout, lineCounts: layout.oldLineCounts)
                Divider()
                column(title: "After", cells: diff.rows.map(\.new), layout: layout, lineCounts: layout.newLineCounts)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
    }

    private func column(title: LocalizedStringKey, cells: [SideBySideDiff.Cell?], layout: DiffCodeLayout, lineCounts: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            DiffCodeColumn(cells: cells, filePath: filePath, layout: layout, lineCounts: lineCounts)
                .frame(height: layout.height + 8 + (wrapLongLines ? 0 : 16))
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

struct DiffCodeColumn: NSViewRepresentable {
    let cells: [SideBySideDiff.Cell?]
    let filePath: String
    var layout: DiffCodeLayout? = nil
    var lineCounts: [Int] = []

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = DiffColumnScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = DiffColumnTextView(frame: .zero)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? DiffColumnTextView else { return }
        scrollView.hasHorizontalScroller = layout?.wraps != true
        textView.update(cells: cells, filePath: filePath, layout: layout, lineCounts: lineCounts)
        textView.resizeToFit(viewportWidth: scrollView.contentSize.width)
    }
}

struct DiffScrollGesture {
    enum Axis {
        case horizontal, vertical
    }

    private var axis: Axis?

    mutating func route(deltaX: CGFloat, deltaY: CGFloat, phase: NSEvent.Phase,
                        momentumPhase: NSEvent.Phase, shift: Bool) -> Axis {
        let isMouseWheel = phase.isEmpty && momentumPhase.isEmpty
        if phase.contains(.began) || isMouseWheel {
            axis = nil
        }
        if axis == nil && (deltaX != 0 || deltaY != 0) {
            axis = shift || abs(deltaX) > abs(deltaY) ? .horizontal : .vertical
        }
        let destination = axis ?? .vertical
        // Keep the direction through the transition from finger movement to momentum.
        if phase.contains(.cancelled) || momentumPhase.contains(.ended)
            || momentumPhase.contains(.cancelled) || isMouseWheel {
            axis = nil
        }
        return destination
    }
}

private final class DiffColumnScrollView: NSScrollView {
    private var gesture = DiffScrollGesture()

    override func tile() {
        super.tile()
        (documentView as? DiffColumnTextView)?.resizeToFit(viewportWidth: contentSize.width)
    }

    override func scrollWheel(with event: NSEvent) {
        let axis = gesture.route(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
            phase: event.phase, momentumPhase: event.momentumPhase,
            shift: event.modifierFlags.contains(.shift)
        )
        if axis == .vertical {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class DiffColumnTextView: NSTextView {
    private static var theme: FileDiffTheme { FileDiffTheme() }
    static var rowHeight: CGFloat { ceil(theme.font.ascender - theme.font.descender + theme.font.leading) + 4 }

    private struct LineNumberLabel {
        let text: NSAttributedString
        let size: NSSize
    }

    private var cells: [SideBySideDiff.Cell?] = []
    private var filePath: String?
    private var gutterWidth: CGFloat = 42
    private var contentWidth: CGFloat = 0
    private var layout: DiffCodeLayout?
    private var rowOffsets: [CGFloat] = [0]
    private var renderedFontSize: CGFloat = 0
    private var currentTheme = FileDiffTheme()
    private var lineHeight: CGFloat = DiffColumnTextView.rowHeight
    private let retainedStorage: NSTextStorage
    private var lineNumberLabels: [Int: LineNumberLabel] = [:]

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer? = nil) {
        let storage = container?.layoutManager?.textStorage ?? NSTextStorage()
        retainedStorage = storage
        let resolvedContainer: NSTextContainer
        if let container {
            resolvedContainer = container
        } else {
            let manager = NSLayoutManager()
            resolvedContainer = NSTextContainer()
            storage.addLayoutManager(manager)
            manager.addTextContainer(resolvedContainer)
        }
        super.init(frame: frameRect, textContainer: resolvedContainer)
        isEditable = false
        isSelectable = true
        isRichText = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: 0, height: 4)
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.lineFragmentPadding = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: gutterWidth + 8, y: 4) }

    func update(cells: [SideBySideDiff.Cell?], filePath: String, layout: DiffCodeLayout? = nil, lineCounts: [Int] = []) {
        guard self.cells != cells || self.filePath != filePath || self.layout != layout
                || renderedFontSize != (layout.map { CGFloat($0.fontSize) } ?? FileDiffTheme.font.pointSize) else { return }
        self.layout = layout
        renderedFontSize = layout.map { CGFloat($0.fontSize) } ?? FileDiffTheme.font.pointSize
        currentTheme = FileDiffTheme(fontSize: renderedFontSize)
        let font = currentTheme.font
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 4
        let heights = layout?.rowHeights ?? Array(repeating: lineHeight, count: cells.count)
        rowOffsets = [0]
        for height in heights { rowOffsets.append(rowOffsets.last! + height) }
        textContainer?.containerSize = NSSize(width: layout?.wraps == true ? layout!.textWidth : .greatestFiniteMagnitude,
                                             height: .greatestFiniteMagnitude)
        self.cells = cells
        self.filePath = filePath
        lineNumberLabels.removeAll(keepingCapacity: true)
        let theme = currentTheme
        let source = cells.map { $0?.text ?? "" }.joined(separator: "\n")
        let attributed = NSMutableAttributedString(string: source, attributes: theme.globalAttributes())
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: theme.font]).width * 4
        paragraph.tabStops = []
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.baseWritingDirection = .leftToRight
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
        if let layout, layout.wraps {
            var location = 0
            for (index, cell) in cells.enumerated() {
                let length = (cell?.text ?? "").utf16.count + (index < cells.count - 1 ? 1 : 0)
                let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                style.paragraphSpacing = max(0, layout.rowHeights[index] - CGFloat(lineCounts[index]) * lineHeight)
                if length > 0 {
                    attributed.addAttribute(.paragraphStyle, value: style, range: NSRange(location: location, length: length))
                }
                location += length
            }
        }
        SyntaxHighlighter.apply(to: attributed, filePath: filePath)
        var location = 0
        for cell in cells {
            if let cell, let color = theme.inlineBackgroundColor(for: cell.kind) {
                for range in cell.changedRanges {
                    attributed.addAttribute(.backgroundColor, value: color,
                                            range: NSRange(location: location + range.lowerBound, length: range.count))
                }
            }
            location += (cell?.text.utf16.count ?? 0) + 1
        }
        textStorage?.setAttributedString(attributed)
        self.font = theme.font
        gutterWidth = layout?.gutterWidth ?? max(42, CGFloat(cells.compactMap { $0?.lineNumber }.map { String($0).count }.max() ?? 1) * 10 + 8)
        if let textContainer, let layoutManager {
            layoutManager.ensureLayout(for: textContainer)
            contentWidth = ceil(layoutManager.usedRect(for: textContainer).maxX) + gutterWidth + 16
        }
        needsDisplay = true
    }

    func resizeToFit(viewportWidth: CGFloat) {
        let size = NSSize(width: layout?.wraps == true ? viewportWidth : max(viewportWidth, contentWidth), height: (rowOffsets.last ?? 0) + 8)
        if frame.size != size {
            setFrameSize(size)
        }
    }

    override func drawBackground(in rect: NSRect) {
        let dirtyRect = rect.intersection(visibleRect)
        guard !dirtyRect.isEmpty else { return }
        super.drawBackground(in: dirtyRect)
        let firstRow = rowIndex(at: dirtyRect.minY - 4)
        let endRow = min(cells.count, rowIndex(at: dirtyRect.maxY - 4) + 1)
        guard firstRow < endRow else { return }
        let theme = currentTheme
        for index in firstRow..<endRow {
            let cell = cells[index]
            let rowRect = NSRect(x: 0, y: 4 + rowOffsets[index], width: bounds.width, height: rowOffsets[index + 1] - rowOffsets[index])
            let color: NSColor?
            switch cell?.kind {
            case .removed: color = theme.backGroundColor(for: .removed)
            case .added: color = theme.backGroundColor(for: .added)
            case nil: color = .quaternaryLabelColor
            default: color = nil
            }
            if let color {
                color.setFill()
                rowRect.fill()
            }
            if let number = cell?.lineNumber {
                let label = lineNumberLabel(for: number)
                label.text.draw(at: NSPoint(x: gutterWidth - label.size.width - 4,
                                           y: rowRect.minY + (lineHeight - label.size.height) / 2))
            }
        }
    }

    private func rowIndex(at y: CGFloat) -> Int {
        var lower = 0
        var upper = cells.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rowOffsets[middle + 1] <= y { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    private func lineNumberLabel(for number: Int) -> LineNumberLabel {
        if let label = lineNumberLabels[number] {
            return label
        }
        // Bound the cache for large hunks while reusing labels during small scrolls.
        if lineNumberLabels.count >= 512 {
            lineNumberLabels.removeAll(keepingCapacity: true)
        }
        let text = NSAttributedString(string: String(number), attributes: [
            .font: currentTheme.font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let label = LineNumberLabel(text: text, size: text.size())
        lineNumberLabels[number] = label
        return label
    }
}

struct DiffCodeLayout: Equatable {
    let wraps: Bool
    let fontSize: Double
    let gutterWidth: CGFloat
    let textWidth: CGFloat
    let oldLineCounts: [Int]
    let newLineCounts: [Int]
    let rowHeights: [CGFloat]
    var height: CGFloat { rowHeights.reduce(0, +) }

    init(rows: [SideBySideDiff.Row], columnWidth: CGFloat, fontSize: Double, wraps: Bool) {
        self.wraps = wraps
        self.fontSize = min(18, max(11, fontSize))
        let font = NSFont.monospacedSystemFont(ofSize: self.fontSize, weight: .regular)
        let digits = rows.flatMap { [$0.old?.lineNumber, $0.new?.lineNumber] }.compactMap { $0 }.map { String($0).count }.max() ?? 1
        gutterWidth = max(42, CGFloat(digits) * ("0" as NSString).size(withAttributes: [.font: font]).width + 8)
        textWidth = wraps ? max(32, floor(columnWidth - gutterWidth - 16)) : .greatestFiniteMagnitude
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 4
        let width = floor(textWidth)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * 4
        paragraph.tabStops = []
        paragraph.baseWritingDirection = .leftToRight
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let fontSize = self.fontSize
        let countLines = { (text: String?) -> Int in
            guard wraps, let text, !text.isEmpty else { return 1 }
            // Layout runs on every view update; resizing and scrolling reuse measured lines.
            let key = "\(fontSize)|\(width)|\(text)" as NSString
            if let cached = WrappedLineCache.counts.object(forKey: key) { return cached.intValue }
            let storage = NSTextStorage(string: text, attributes: attributes)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            var count = 0
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, _, _ in count += 1 }
            WrappedLineCache.counts.setObject(NSNumber(value: max(1, count)), forKey: key)
            return max(1, count)
        }
        oldLineCounts = rows.map { countLines($0.old?.text) }
        newLineCounts = rows.map { countLines($0.new?.text) }
        rowHeights = zip(oldLineCounts, newLineCounts).map { CGFloat(max($0, $1)) * lineHeight }
    }
}

private enum WrappedLineCache {
    nonisolated(unsafe) static let counts: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 20_000
        return cache
    }()
}
