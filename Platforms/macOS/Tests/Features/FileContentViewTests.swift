import AppKit
import Darwin
import FoldGitTestSupport
import SwiftUI
import Testing
@testable import FoldGit

@MainActor
struct FileContentViewTests {
    @Test func detailSwitchesInlineWithoutOpeningASheetOrResettingTheMode() async throws {
        let repository = try await TestRepository.create(commits: 1)
        defer { repository.remove() }
        let store = FileHistoryStore()
        defer { store.deactivate() }
        store.activate(in: repository.url)
        await store.refreshTask?.value
        await store.treeTask?.value
        let host = NSHostingView(rootView: FileHistoryDetailView(store: store).environment(\.folder, repository.url))
        let window = makeWindow(host)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(descendants(host).compactMap { $0 as? NSSegmentedControl }.isEmpty)
        store.selectFile("example.swift")
        await store.historyTask?.value
        await store.diffTask?.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.detailMode == .history)
        #expect(store.content.url == nil)
        let picker = try #require(descendants(host).compactMap { $0 as? NSSegmentedControl }.first {
            $0.segmentCount == 2 && $0.label(forSegment: 0) == String(localized: "Commit History")
        })
        #expect(picker.segmentCount == 2)
        #expect(picker.selectedSegment == 0)
        #expect(window.attachedSheet == nil)

        picker.selectedSegment = 1
        _ = picker.sendAction(picker.action, to: picker.target)
        await store.content.readTask?.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.detailMode == .content)
        #expect(descendants(host).contains { $0 is NSTextView && ($0 as? NSTextView)?.isEditable == false })
        #expect(window.attachedSheet == nil)

        picker.selectedSegment = 0
        _ = picker.sendAction(picker.action, to: picker.target)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.detailMode == .history)
        #expect(store.content.url == nil)
        #expect(window.attachedSheet == nil)
        #expect(picker.window === window)
        store.selectFile(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(descendants(host).compactMap { $0 as? NSSegmentedControl }.isEmpty)
    }

    @Test func nativeFindAndCopyPreserveWhitespaceAndUnicode() async throws {
        let source = "\r\n\tlet greeting = \"中文 😀\"\r\n\r\n"
        guard case .text(_, _, let layout) = try FileContentReader.decode(Data(source.utf8), plain: false) else {
            Issue.record("Text fixture was rejected")
            return
        }
        let document = FileContentDocument(text: source, plain: false, layout: layout)
        let host = NSHostingView(rootView: FileContentTextViewer(document: document, path: "test.swift", fontSize: 13, wraps: false))
        let window = makeWindow(host)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let text = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(text))
        text.selectAll(nil)
        #expect(text.selectedRange() == NSRange(location: 0, length: source.utf16.count))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let types = text.writablePasteboardTypes
        #expect(text.writeSelection(to: pasteboard, types: types))
        #expect(types.contains { pasteboard.string(forType: $0) == source })
        host.rootView = FileContentTextViewer(document: document, path: "test.swift", fontSize: 13, wraps: false, findRequest: UUID())
        for _ in 0..<100 {
            if text.enclosingScrollView?.isFindBarVisible == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(text.enclosingScrollView?.isFindBarVisible == true)
        #expect(text.textLayoutManager != nil)
    }

    @Test func nativeViewerUsesTextKit2AndPreservesSelectionAcrossStyleUpdates() async throws {
        let document = FileContentDocument(text: "let greeting = \"中文 😀\"\n// 完整内容\n", plain: false)
        let host = NSHostingView(rootView: FileContentTextViewer(document: document, path: "test.swift", fontSize: 13, wraps: true))
        let window = makeWindow(host)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let text = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
        #expect(text.textLayoutManager != nil)
        #expect(!text.isEditable)
        #expect(text.isSelectable)
        #expect(text.string == document.text)
        #expect(text.textContainer?.widthTracksTextView == true)
        #expect(text.enclosingScrollView?.hasVerticalScroller == true)
        let selection = (document.text as NSString).range(of: "中文 😀")
        text.setSelectedRange(selection)
        #expect((text.string as NSString).substring(with: text.selectedRange()) == "中文 😀")
        let keywordColor = try #require(text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(keywordColor != .textColor)
        let scroll = try #require(text.enclosingScrollView)
        let lineNumbers = try #require(scroll.superview?.subviews.first { $0.identifier?.rawValue == "fileContentLineNumbers" })
        #expect(!scroll.hasVerticalRuler)
        #expect(!scroll.rulersVisible)
        #expect(lineNumbers.frame.width >= 38)
        #expect(lineNumbers.frame.maxX <= scroll.frame.minX + 1)
        #expect(text.usesFindBar)
        host.rootView = FileContentTextViewer(document: document, path: "test.swift", fontSize: 16, wraps: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(text.selectedRange() == selection)
        #expect(text.font?.pointSize == 16)
        #expect(text.textContainer?.widthTracksTextView == false)
        #expect(text.enclosingScrollView?.hasHorizontalScroller == true)
        #expect(text.textLayoutManager != nil)
    }

    @Test func newDocumentReplacesTextAndCancelsPreviousHighlighting() async throws {
        let first = FileContentDocument(text: String(repeating: "let first = 123 // comment\n", count: 10_000), plain: false)
        let second = FileContentDocument(text: "plain content", plain: true)
        let host = NSHostingView(rootView: FileContentTextViewer(document: first, path: "first.swift", fontSize: 13, wraps: false))
        let window = makeWindow(host)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.rootView = FileContentTextViewer(document: second, path: "second.txt", fontSize: 13, wraps: false)
        try await Task.sleep(for: .milliseconds(200))
        let text = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
        #expect(text.string == second.text)
        #expect(text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .textColor)
        #expect(text.textLayoutManager != nil)
    }

    @Test func largeDocumentsRenderAndScrollWithoutReplacingTheTextKitEngine() async throws {
        let line = "let value = 123 // " + String(repeating: "a", count: 109) + "\n"
        for (size, plain, wraps) in [(FileContentReader.automaticLimit, false, false),
                                     (FileContentReader.automaticLimit, false, true),
                                     (FileContentReader.maximumBytes, true, false)] {
            let source = String(String(repeating: line, count: size / line.utf8.count).prefix(size))
            let document = FileContentDocument(text: source, plain: plain, layout: .init(lineCount: size / line.utf8.count + 1, maximumColumns: 128))
            let before = residentBytes()
            let clock = ContinuousClock()
            let started = clock.now
            let host = NSHostingView(rootView: FileContentTextViewer(document: document, path: "large.swift", fontSize: 13, wraps: wraps))
            let window = makeWindow(host)
            host.layoutSubtreeIfNeeded()
            let firstLayout = started.duration(to: clock.now)
            let text = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
            #expect(text.string == source)
            #expect(text.textLayoutManager != nil)
            let scrollStarted = clock.now
            text.scrollRangeToVisible(NSRange(location: text.string.utf16.count - 1, length: 1))
            host.layoutSubtreeIfNeeded()
            let scrollTime = scrollStarted.duration(to: clock.now)
            #expect(text.selectedRange().length == 0)
            #expect(text.textLayoutManager != nil)
            text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
            #expect((text.string as NSString).substring(with: text.selectedRange()) == source)
            try await Task.sleep(for: .milliseconds(200))
            #expect(firstLayout < .seconds(1))
            print("File content benchmark: \(source.utf8.count) bytes, wraps \(wraps), first layout \(firstLayout), scroll to end \(scrollTime), resident growth \(residentBytes() - before) bytes")
            if let output = ProcessInfo.processInfo.environment["FILE_HISTORY_SNAPSHOT_DIRECTORY"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                text.setSelectedRange(NSRange(location: 0, length: 0))
                text.scrollRangeToVisible(NSRange(location: 0, length: 1))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("file-content-\(size)-\(wraps).png"))
            }
            window.close()
        }
    }

    @Test func contentBrowserRendersInBothAppearances() async throws {
        let repository = try await TestRepository.create(commits: 0)
        defer { repository.remove() }
        try repository.write("Example.swift", "import Foundation\n\n// 工作区内容\nlet greeting = \"你好，世界 😀\"\nlet count = 42\n")
        let store = FileHistoryStore()
        store.activate(in: repository.url)
        await store.refreshTask?.value
        await store.treeTask?.value
        store.selectDetailMode(.content)
        store.selectFile("Example.swift")
        await store.content.readTask?.value
        for scheme in [ColorScheme.light, .dark] {
            let root = HStack(spacing: 0) {
                RepositoryFileTreeView(store: store).frame(width: 280)
                Divider()
                FileHistoryDetailView(store: store)
            }
            .environment(\.folder, repository.url)
            .environment(\.colorScheme, scheme)
            .frame(width: 960, height: 640)
            let host = NSHostingView(rootView: root)
            let window = makeWindow(host)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let code = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string.contains("let greeting") })
            for _ in 0..<100 {
                if let color = code.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                   color != .textColor { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(descendants(host).compactMap { $0 as? NSTextView }.contains { $0.string.contains("let greeting") })
            #expect(descendants(host).compactMap { $0 as? NSSegmentedControl }.contains { $0.segmentCount == 2 })
            if let output = ProcessInfo.processInfo.environment["FILE_HISTORY_SNAPSHOT_DIRECTORY"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                var coloredPixels = 0
                for y in stride(from: 0, to: min(bitmap.pixelsHigh, 500), by: 2) {
                    for x in stride(from: bitmap.pixelsWide / 2, to: bitmap.pixelsWide, by: 2) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if max(color.redComponent, color.greenComponent, color.blueComponent)
                            - min(color.redComponent, color.greenComponent, color.blueComponent) > 0.15 { coloredPixels += 1 }
                    }
                }
                #expect(coloredPixels > 20)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("file-content-browser-\(scheme).png"))
            }
            window.close()
        }
        store.deactivate()
    }

    private func makeWindow(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderBack(nil)
        return window
    }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendants($0) }
    }

    private func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}
