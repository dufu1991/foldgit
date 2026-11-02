import AppKit
import Testing
@testable import FoldGit

@MainActor
struct ImmediateHelpTests {
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
