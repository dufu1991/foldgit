import AppKit
import Testing
@testable import FoldGit

@MainActor
struct ImmediateHelpTests {
    @Test func structuredHelpFitsLongLabelsAndPathsInBothAppearances() throws {
        let details = ImmediateHelpDetails(title: "关联工作树 · nice-banach-ee9fed", summary: "", sections: [
            .init(rows: [.init(label: "工作区", value: "未提交的更改"), .init(label: "已暂存", value: "1 项"),
                         .init(label: "未暂存", value: "190 项"), .init(label: "未跟踪", value: "20 项")]),
            .init(rows: [.init(label: "合并状态", value: "尚未并入 master"), .init(label: "领先 master", value: "2 个提交"),
                         .init(label: "落后 master", value: "30 个提交")]),
        ])
        let output = URL(fileURLWithPath: "/tmp/foldgit-status-redesign-snapshots")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 180, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let anchor = ImmediateHelpView(frame: NSRect(x: 20, y: 20, width: 20, height: 20))
            anchor.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            anchor.text = details.text
            anchor.details = details
            window.contentView?.addSubview(anchor)
            window.orderBack(nil)
            let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            anchor.mouseEntered(with: event)
            let panel = try #require(window.childWindows?.first)
            let content = try #require(panel.contentView)
            let label = try #require(content.subviews.compactMap { $0 as? NSTextField }.first)
            #expect(label.stringValue.contains("未暂存\t190 项"))
            #expect(label.bounds.width <= 320)
            #expect(panel.frame.width <= 336)
            #expect(panel.frame.height > 120)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(dark ? "tooltip-dark.png" : "tooltip-light.png"))
            anchor.mouseExited(with: event)
            #expect(!panel.isVisible)
        }
    }

    @Test func hoveringShowsHelpImmediatelyWithoutTakingFocusAndCleansUpOnExit() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 180, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = ImmediateHelpView(frame: NSRect(x: 20, y: 20, width: 20, height: 20))
        anchor.text = "自动获取\n每 60 分钟"
        window.contentView?.addSubview(anchor)
        window.orderBack(nil)
        let keyWindow = NSApp.keyWindow
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
                                                      modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: 0, trackingNumber: 0, userData: nil))

        anchor.mouseEntered(with: event)

        let panel = try #require(window.childWindows?.first)
        #expect(panel.isVisible)
        #expect(panel.ignoresMouseEvents)
        #expect(NSApp.keyWindow === keyWindow)
        #expect(anchor.hitTest(.zero) == nil)

        let label = try #require(panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first)
        let bitmap = try #require(label.bitmapImageRepForCachingDisplay(in: label.bounds))
        label.cacheDisplay(in: label.bounds, to: bitmap)
        let rows = (0..<bitmap.pixelsHigh).map { y in
            (0..<bitmap.pixelsWide).contains { x in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            }
        }
        let visibleLines = rows.indices.filter { rows[$0] && ($0 == 0 || !rows[$0 - 1]) }.count
        #expect(visibleLines == 2)

        anchor.mouseExited(with: event)

        #expect(!panel.isVisible)
        #expect(window.childWindows?.isEmpty != false)

        anchor.mouseEntered(with: event)
        let nextPanel = try #require(window.childWindows?.first)
        #expect(nextPanel.isVisible)
        anchor.removeFromSuperview()
        #expect(!nextPanel.isVisible)
        #expect(window.childWindows?.isEmpty != false)
    }
}
