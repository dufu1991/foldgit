import AppKit
import SwiftUI

extension View {
    func immediateHelp(_ text: String) -> some View {
        background(ImmediateHelpAnchor(text: text).accessibilityHidden(true))
            .accessibilityHint(Text(verbatim: text))
    }

    func immediateHelp(_ details: ImmediateHelpDetails) -> some View {
        background(ImmediateHelpAnchor(text: details.text, details: details).accessibilityHidden(true))
            .accessibilityHint(Text(verbatim: details.text))
    }
}

struct ImmediateHelpDetails: Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
    }
    struct Section: Equatable {
        var title: String = ""
        let rows: [Row]
    }
    let title: String
    let summary: String
    let sections: [Section]

    var text: String {
        ([title, summary] + sections.flatMap { section in
            [section.title] + section.rows.map { "\($0.label) \($0.value)" }
        }).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The summary and every section on one line, for lists that show the facts without a tooltip.
    var compactText: String {
        (summary.split(whereSeparator: \.isNewline).map(String.init) + sections.map { section in
            let rows = section.rows.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
            return section.title.isEmpty ? rows : section.title + " " + rows
        }).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @MainActor var attributedText: NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let result = NSMutableAttributedString(string: "")
        let column = min(180, ceil(sections.flatMap(\.rows).map { ($0.label as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 20)
        let append = { (text: String, weight: NSFont.Weight, secondary: Bool, gap: CGFloat) in
            guard !text.isEmpty else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = gap
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: weight),
                .foregroundColor: secondary ? NSColor.labelColor.withAlphaComponent(0.72) : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        append(title, .semibold, false, 4)
        append(summary, .regular, false, 8)
        for (sectionIndex, section) in sections.enumerated() {
            let isLastSection = sectionIndex == sections.count - 1
            if !section.title.isEmpty { append(section.title, .medium, true, 4) }
            for (index, row) in section.rows.enumerated() {
                let paragraph = NSMutableParagraphStyle()
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: column)]
                paragraph.headIndent = column
                paragraph.paragraphSpacing = index < section.rows.count - 1 ? 3 : isLastSection ? 0 : 8
                let line = NSMutableAttributedString(string: row.label + "\t" + row.value + "\n", attributes: [
                    .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
                ])
                line.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
                                  range: NSRange(location: (row.label + "\t").utf16.count, length: row.value.utf16.count))
                result.append(line)
            }
        }
        if result.length > 0 { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }
}

private struct ImmediateHelpAnchor: NSViewRepresentable {
    let text: String
    var details: ImmediateHelpDetails?

    func makeNSView(context: Context) -> ImmediateHelpView {
        ImmediateHelpView()
    }

    func updateNSView(_ view: ImmediateHelpView, context: Context) {
        if view.text != text || view.details != details {
            view.hideHelp()
            view.text = text
            view.details = details
        }
    }

    static func dismantleNSView(_ view: ImmediateHelpView, coordinator: ()) {
        view.hideHelp()
    }
}

final class ImmediateHelpView: NSView {
    var text = ""
    var details: ImmediateHelpDetails?
    private var hoverArea: NSTrackingArea?
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var windowObserver: NSObjectProtocol?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        hideHelp()
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        showHelp()
    }

    override func mouseExited(with event: NSEvent) {
        hideHelp()
    }

    private func showHelp() {
        guard panel == nil, !text.isEmpty, let window, window.attachedSheet == nil,
              let screen = window.screen else { return }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.cell?.usesSingleLineMode = false
        label.preferredMaxLayoutWidth = 320
        if let details { label.attributedStringValue = details.attributedText }
        let fittingSize = label.sizeThatFits(NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        let textSize = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        let size = NSSize(width: textSize.width + 16, height: textSize.height + 12)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        label.frame = NSRect(origin: NSPoint(x: 8, y: 6), size: textSize)
        background.addSubview(label)

        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let preferredX = anchor.maxX + 8
        let x = preferredX + size.width <= visible.maxX ? preferredX : anchor.minX - size.width - 8
        let origin = NSPoint(x: min(max(x, visible.minX), visible.maxX - size.width),
                             y: min(max(anchor.midY - size.height / 2, visible.minY), visible.maxY - size.height))
        let helpPanel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        helpPanel.isOpaque = false
        helpPanel.backgroundColor = .clear
        helpPanel.hasShadow = true
        helpPanel.ignoresMouseEvents = true
        helpPanel.hidesOnDeactivate = true
        helpPanel.isReleasedWhenClosed = false
        helpPanel.level = .popUpMenu
        helpPanel.contentView = background
        helpPanel.appearance = effectiveAppearance
        panel = helpPanel
        window.addChildWindow(helpPanel, ordered: .above)
        helpPanel.orderFront(nil)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            self?.hideHelp()
            return event
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideHelp() }
        }
    }

    func hideHelp() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
        panel = nil
    }
}
