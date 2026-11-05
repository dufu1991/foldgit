import AppKit
import Darwin
import FoldGitTestSupport
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import FoldGit

@MainActor
struct FileContentViewTests {
    @Test(arguments: ["website/assets/og.png", "website/assets/screenshots/main-en-dark@2x.webp"])
    func repositoryImageFormatsLoadAsImages(path: String) async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../", isDirectory: true).standardizedFileURL
        let store = FileContentStore()
        defer { store.hide() }
        store.show(directory: directory, path: path)
        await store.readTask?.value
        guard case .image(let image) = store.state else {
            Issue.record("File content must preview the repository image instead of rejecting its text encoding")
            return
        }
        #expect(image.pixelWidth > 0)
        #expect(image.pixelHeight > 0)
        let metadata = try #require(store.metadata)
        #expect(Int64(image.byteCount) == metadata.size)
    }

    @Test(arguments: ["png", "webp"], [1, 2])
    func imagePreviewRendersKnownColorsAtBothPixelDensities(format: String, density: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foldgit-preview-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = "preview.\(format)"
        try previewImageData(format: format).write(to: directory.appendingPathComponent(path))
        let store = FileContentStore()
        defer { store.hide() }
        store.show(directory: directory, path: path)
        await store.readTask?.value
        guard case .image(let image) = store.state else {
            Issue.record("The preview fixture must load as an image")
            return
        }
        #expect(image.pixelWidth == 640)
        #expect(image.pixelHeight == 480)
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: FileContentView(store: store, path: path, findRequest: nil)
                .environment(\.colorScheme, scheme))
            let window = makeWindow(host)
            defer { window.close() }
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width) * density,
                pixelsHigh: Int(host.bounds.height) * density, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = host.bounds.size
            var colorCounts = [0, 0, 0, 0]
            let rendered = try await waitForLayout(host) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                colorCounts = [0, 0, 0, 0]
                for y in stride(from: bitmap.pixelsHigh / 4, to: bitmap.pixelsHigh * 3 / 4, by: 8) {
                    for x in stride(from: bitmap.pixelsWide / 4, to: bitmap.pixelsWide * 3 / 4, by: 8) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
                        if red > 0.75 && green < 0.25 && blue < 0.25 { colorCounts[0] += 1 }
                        if red < 0.25 && green > 0.75 && blue < 0.25 { colorCounts[1] += 1 }
                        if red < 0.25 && green < 0.25 && blue > 0.75 { colorCounts[2] += 1 }
                        if red > 0.75 && green > 0.75 && blue < 0.25 { colorCounts[3] += 1 }
                    }
                }
                return colorCounts.allSatisfy { $0 > 20 }
            }
            // All four fixture colors must appear; a blank canvas or placeholder cannot pass.
            #expect(rendered, "Expected all four image colors, sampled \(colorCounts)")
            #expect(!descendants(host).contains { $0 is NSTextView })
            if let output = ProcessInfo.processInfo.environment["FILE_HISTORY_SNAPSHOT_DIRECTORY"] {
                let target = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: target.appendingPathComponent("file-image-\(image.format)-\(scheme)-\(density)x.png"))
            }
        }
    }

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
        #expect(try await waitForLayout(host) {
            descendants(host).compactMap { $0 as? NSSegmentedControl }.isEmpty
        })
        store.selectFile("example.swift")
        await store.historyTask?.value
        await store.diffTask?.value
        #expect(try await waitForLayout(host) {
            descendants(host).contains { $0 is NSSegmentedControl }
        })
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
        #expect(try await waitForLayout(host) {
            descendants(host).contains { $0 is NSTextView && ($0 as? NSTextView)?.isEditable == false }
        })
        #expect(store.detailMode == .content)
        let contentText = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { !$0.isEditable })
        #expect(contentText.window === window)
        #expect(window.attachedSheet == nil)

        picker.selectedSegment = 0
        _ = picker.sendAction(picker.action, to: picker.target)
        #expect(try await waitForLayout(host) {
            contentText.window == nil
        })
        #expect(store.detailMode == .history)
        #expect(store.content.url == nil)
        #expect(window.attachedSheet == nil)
        #expect(picker.window === window)
        store.selectFile(nil)
        #expect(store.selectedPath == nil)
        #expect(try await waitForLayout(host) {
            descendants(host).compactMap { $0 as? NSSegmentedControl }.isEmpty
        })
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

    private func previewImageData(format: String) throws -> Data {
        if format == "webp" {
            // Lossless 640 x 480 WebP with opaque red, green, blue and yellow quadrants.
            return try #require(Data(base64Encoded:
                "UklGRloAAABXRUJQVlA4TE4AAAAvf8J3AB8gEEjaH3qN+RcQFPk/2vwHXyTATNs2IzmSIzkCPSs5ov8T8HE3Lv/xH//xH//xH//xH/8VrYl7cfmP//iP//iP//iP//ivaAE="))
        }
        let context = try #require(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                      CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 0, alpha: 1)]
        for (index, color) in colors.enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: index % 2 * 320, y: index / 2 * 240, width: 320, height: 240))
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func waitForLayout(_ host: NSView, matching condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        host.layoutSubtreeIfNeeded()
        return condition()
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
