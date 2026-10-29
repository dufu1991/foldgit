import AppKit
import FoldGitCore
import SwiftUI
import XCTest
@testable import FoldGit

final class SideBySideDiffTests: XCTestCase {
    func testReplacementPadsShorterSideAndKeepsContextAligned() {
        let chunk = Chunk(raw: "@@ -10,4 +20,3 @@\n context\n-old first\n-old second\n+new\n tail\n")
        let diff = SideBySideDiff(chunk: chunk)
        XCTAssertTrue(diff.isSupported)
        XCTAssertEqual(diff.rows.map { $0.old?.text }, ["context", "old first", "old second", "tail"])
        XCTAssertEqual(diff.rows.map { $0.new?.text }, ["context", "new", nil, "tail"])
        XCTAssertEqual(diff.rows.map { $0.old?.lineNumber }, [10, 11, 12, 13])
        XCTAssertEqual(diff.rows.map { $0.new?.lineNumber }, [20, 21, nil, 22])
        XCTAssertEqual(chunk.raw, "@@ -10,4 +20,3 @@\n context\n-old first\n-old second\n+new\n tail\n")
    }

    func testInsertionAndDeletionWithZeroLengthRanges() {
        let inserted = SideBySideDiff(chunk: Chunk(raw: "@@ -0,0 +1,2 @@\n+first\n+\n"))
        XCTAssertTrue(inserted.rows.allSatisfy { $0.old == nil })
        XCTAssertEqual(inserted.rows.map { $0.new?.text }, ["first", ""])
        XCTAssertEqual(inserted.rows.map { $0.new?.lineNumber }, [1, 2])
        let deleted = SideBySideDiff(chunk: Chunk(raw: "@@ -1,2 +0,0 @@\n-first\n-\n"))
        XCTAssertTrue(deleted.rows.allSatisfy { $0.new == nil })
        XCTAssertEqual(deleted.rows.map { $0.old?.lineNumber }, [1, 2])
    }

    func testSeveralChangeBlocksAndOmittedRangeCounts() {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -4 +8 @@\n-old\n+new\n same\n+extra\n end"))
        XCTAssertEqual(diff.rows.map { $0.old?.lineNumber }, [4, 5, nil, 6])
        XCTAssertEqual(diff.rows.map { $0.new?.lineNumber }, [8, 9, 10, 11])
    }

    func testWhitespaceUnicodeAndEmptyContextArePreserved() {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -1,3 +1,3 @@\n \n-\tlet value = \"旧值 👋\"\n+\tlet value = \"新值 🌍\"\n   "))
        XCTAssertEqual(diff.rows.count, 3)
        XCTAssertEqual(diff.rows[0].old?.text, "")
        XCTAssertEqual(diff.rows[1].new?.text, "\tlet value = \"新值 🌍\"")
        XCTAssertEqual(diff.rows[2].old?.text, "  ")
        XCTAssertEqual(diff.rows[2].new?.lineNumber, 3)
    }

    func testEndOfFileAnnotationsDoNotConsumeLineNumbersOrPairWithCode() {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -5,1 +5,2 @@\n-old\n\\ No newline at end of file\n+new\n+extra\n\\ No newline at end of file"))
        XCTAssertEqual(diff.rows.count, 3)
        XCTAssertEqual(diff.rows[1].old, nil)
        XCTAssertEqual(diff.rows[1].new?.text, "extra")
        XCTAssertEqual(diff.rows[1].new?.lineNumber, 6)
        XCTAssertEqual(diff.rows[2].old?.text, "\\ No newline at end of file")
        XCTAssertNil(diff.rows[2].old?.lineNumber)
        XCTAssertNil(diff.rows[2].new?.lineNumber)
    }

    func testCombinedDiffIsNotPresentedAsTwoWayDiff() {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@@ -1,1 -1,1 +1,2 @@@\n++conflict"))
        XCTAssertFalse(diff.isSupported)
        XCTAssertTrue(diff.rows.isEmpty)
    }

    @MainActor
    func testInlineBackgroundRangesKeepSyntaxColorsAndSourceTextInBothLayouts() throws {
        let chunk = Chunk(raw: "@@ -1 +1 @@\n-let 文本 = \"👨‍👩‍👧‍👦 旧值 👍🏽\"\n+let 文本 = \"👨‍👩‍👧‍👦 新值 👍🏻\"")
        let diff = SideBySideDiff(chunk: chunk)
        let columns = [diff.rows.map(\.old), diff.rows.map(\.new), diff.unifiedCells.map(Optional.some)]
        for cells in columns {
            for wraps in [false, true] {
                let rows = cells.map { SideBySideDiff.Row(new: $0) }
                let layout = DiffCodeLayout(rows: rows, columnWidth: 180, fontSize: 16, wraps: wraps)
                let view = DiffColumnTextView(frame: .zero)
                view.update(cells: cells, filePath: "Example.swift", layout: layout, lineCounts: layout.newLineCounts)
                view.resizeToFit(viewportWidth: 180)
                let storage = try XCTUnwrap(view.textStorage)
                XCTAssertEqual(view.string, cells.map { $0?.text ?? "" }.joined(separator: "\n"))
                XCTAssertTrue(view.isSelectable)
                XCTAssertFalse(view.isEditable)
                var offset = 0
                for cell in cells {
                    guard let cell else { offset += 1; continue }
                    for index in 0..<cell.text.utf16.count {
                        let expected = cell.changedRanges.contains { $0.contains(index) }
                        let background = storage.attribute(.backgroundColor, at: offset + index, effectiveRange: nil) as? NSColor
                        XCTAssertEqual(background, expected ? FileDiffTheme().inlineBackgroundColor(for: cell.kind) : nil)
                    }
                    for range in cell.changedRanges {
                        XCTAssertNotNil(storage.attribute(.foregroundColor, at: offset + range.lowerBound, effectiveRange: nil))
                    }
                    offset += cell.text.utf16.count + 1
                }
            }
        }
    }

    @MainActor
    func testInlineHighlightsRenderInBothLayoutsAndAppearances() async throws {
        let chunk = Chunk(raw: "@@ -1,4 +1,5 @@\n <section>\n-  <div class=\"full flex h-full\">\n-  <!-- 数据概览 👨‍👩‍👧‍👦 -->\n+  <div class=\"full relative h-full min-h-0 w-full\">\n+  <!-- 数据概览 👨‍👩‍👧‍👦：铺满内容区 -->\n+    <DataOverview />\n </section>")
        for layout in [DiffLayout.unified, .sideBySide] {
            for dark in [false, true] {
                let name = "InlineDiffRendering.\(UUID().uuidString)"
                let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
                defer { preferences.removePersistentDomain(forName: name) }
                preferences.set(layout.rawValue, forKey: PreferenceKey.diffLayout.rawValue)
                let root = ChunkView(chunk: chunk, filePath: "Example.vue")
                    .defaultAppStorage(preferences)
                    .frame(width: 1_200, height: 300, alignment: .topLeading)
                    .background(Color(nsColor: .textBackgroundColor))
                let view = NSHostingView(rootView: root)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 300),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.orderBack(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(200))
                view.layoutSubtreeIfNeeded()
                var pending: [NSView] = [view]
                var columns: [DiffColumnTextView] = []
                while let next = pending.popLast() {
                    if let column = next as? DiffColumnTextView { columns.append(column) }
                    pending.append(contentsOf: next.subviews)
                }
                XCTAssertEqual(columns.count, layout == .unified ? 1 : 2)
                for column in columns {
                    let storage = try XCTUnwrap(column.textStorage)
                    var count = 0
                    storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                        if value != nil { count += 1 }
                    }
                    XCTAssertGreaterThan(count, 0)
                }
                window.displayIfNeeded()
                let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                let snapshotName = "inline-\(layout.rawValue)-\(dark ? "dark" : "light")"
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = snapshotName
                attachment.lifetime = .keepAlways
                add(attachment)
                if let directory = ProcessInfo.processInfo.environment["DIFF_SNAPSHOT_DIRECTORY"] {
                    let url = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try png.write(to: url.appendingPathComponent("\(snapshotName).png"))
                }
            }
        }
    }

    @MainActor
    func testNativeColumnsKeepLongLinesUnwrappedAndSelectable() throws {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -1,2 +1,2 @@\n-\tlet text = \"旧值 👋\"\n+let text = \"" + String(repeating: "long code ", count: 100) + "\"\n next"))
        let view = DiffColumnTextView(frame: .zero)
        view.update(cells: diff.rows.map(\.new), filePath: "Example.swift")
        view.resizeToFit(viewportWidth: 240)
        XCTAssertGreaterThan(view.frame.width, 240)
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable)
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let first = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let last = manager.lineFragmentRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil)
        XCTAssertEqual(last.minY - first.minY, DiffColumnTextView.rowHeight, accuracy: 0.01)
        XCTAssertEqual(view.frame.height, CGFloat(diff.rows.count) * DiffColumnTextView.rowHeight + 8)
        XCTAssertTrue(view.string.hasSuffix("\nnext"))
    }


    @MainActor
    func testWrappedColumnsKeepFollowingRowsAligned() throws {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -1,2 +1,2 @@\n-short\n+" + String(repeating: "长代码 👋 ", count: 35) + "\n next"))
        let layout = DiffCodeLayout(rows: diff.rows, columnWidth: 240, fontSize: FileDiffTheme.font.pointSize, wraps: true)
        XCTAssertGreaterThan(layout.newLineCounts[0], layout.oldLineCounts[0])
        let old = DiffColumnTextView(frame: .zero)
        let new = DiffColumnTextView(frame: .zero)
        old.update(cells: diff.rows.map(\.old), filePath: "file.swift", layout: layout, lineCounts: layout.oldLineCounts)
        new.update(cells: diff.rows.map(\.new), filePath: "file.swift", layout: layout, lineCounts: layout.newLineCounts)
        for view in [old, new] {
            view.resizeToFit(viewportWidth: 240)
            XCTAssertEqual(view.frame.width, 240)
            XCTAssertEqual(view.frame.height, layout.height + 8)
            let manager = try XCTUnwrap(view.layoutManager)
            let nextCharacter = (view.string as NSString).range(of: "next").location
            let glyph = manager.glyphIndexForCharacter(at: nextCharacter)
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            XCTAssertEqual(rect.minY, layout.rowHeights[0], accuracy: 0.5)
        }
    }

    @MainActor
    func testWrapLayoutUsesBothColumnsAndRespondsToWidthAndFontSize() {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -1 +1 @@\n-" + String(repeating: "old code ", count: 30) + "\n+short"))
        let narrow = DiffCodeLayout(rows: diff.rows, columnWidth: 200, fontSize: 13, wraps: true)
        let wide = DiffCodeLayout(rows: diff.rows, columnWidth: 500, fontSize: 13, wraps: true)
        let large = DiffCodeLayout(rows: diff.rows, columnWidth: 200, fontSize: 18, wraps: true)
        let unwrapped = DiffCodeLayout(rows: diff.rows, columnWidth: 200, fontSize: 13, wraps: false)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertGreaterThan(large.height, narrow.height)
        XCTAssertEqual(unwrapped.oldLineCounts, [1])
        XCTAssertEqual(unwrapped.newLineCounts, [1])
        XCTAssertGreaterThan(narrow.oldLineCounts[0], narrow.newLineCounts[0])
    }

    @MainActor
    func testUnifiedWrappingAndFontSettingsReachNativeTextView() async throws {
        let suite = "UnifiedCodeSettings.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let chunk = Chunk(raw: "@@ -1 +1 @@\n-" + String(repeating: "old code ", count: 30) + "\n+new")
        let root = ChunkView(chunk: chunk, filePath: "file.swift")
            .defaultAppStorage(preferences)
            .frame(width: 400, height: 800, alignment: .topLeading)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        var nowrapHeight: CGFloat = 0
        for wraps in [false, true] {
            preferences.set(wraps, forKey: PreferenceKey.wrapLongLines.rawValue)
            preferences.set(16.0, forKey: PreferenceKey.codeFontSize.rawValue)
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            var pending: [NSView] = [view]
            var textViews: [NSTextView] = []
            while let next = pending.popLast() {
                if let text = next as? NSTextView, text.string.contains("old code") { textViews.append(text) }
                pending.append(contentsOf: next.subviews)
            }
            let text = try XCTUnwrap(textViews.first)
            XCTAssertEqual(text.font?.pointSize, 16)
            let manager = try XCTUnwrap(text.layoutManager)
            let container = try XCTUnwrap(text.textContainer)
            manager.ensureLayout(for: container)
            let height = manager.usedRect(for: container).height
            XCTAssertGreaterThan(text.frame.height, 0)
            if wraps {
                XCTAssertLessThanOrEqual(text.frame.width, 400)
                XCTAssertGreaterThan(height, nowrapHeight)
            } else {
                XCTAssertGreaterThan(text.frame.width, 400)
                nowrapHeight = height
            }
        }
    }

    @MainActor
    func testVerticalGestureKeepsItsDirectionThroughMomentum() {
        var gesture = DiffScrollGesture()
        XCTAssertEqual(gesture.route(deltaX: 1, deltaY: 10, phase: .began, momentumPhase: [], shift: false), .vertical)
        XCTAssertEqual(gesture.route(deltaX: 8, deltaY: 2, phase: .changed, momentumPhase: [], shift: false), .vertical)
        XCTAssertEqual(gesture.route(deltaX: 0, deltaY: 0, phase: .ended, momentumPhase: [], shift: false), .vertical)
        XCTAssertEqual(gesture.route(deltaX: 5, deltaY: 1, phase: [], momentumPhase: .began, shift: false), .vertical)
        XCTAssertEqual(gesture.route(deltaX: 1, deltaY: 0, phase: [], momentumPhase: .ended, shift: false), .vertical)
        XCTAssertEqual(gesture.route(deltaX: 10, deltaY: 1, phase: .began, momentumPhase: [], shift: false), .horizontal)
    }

    @MainActor
    func testHorizontalGestureDoesNotSwitchColumnsWhenDeltasChange() {
        var gesture = DiffScrollGesture()
        XCTAssertEqual(gesture.route(deltaX: 10, deltaY: 1, phase: .began, momentumPhase: [], shift: false), .horizontal)
        XCTAssertEqual(gesture.route(deltaX: 1, deltaY: 8, phase: .changed, momentumPhase: [], shift: false), .horizontal)
        XCTAssertEqual(gesture.route(deltaX: 0, deltaY: 0, phase: .cancelled, momentumPhase: [], shift: false), .horizontal)
        XCTAssertEqual(gesture.route(deltaX: 1, deltaY: 8, phase: .began, momentumPhase: [], shift: false), .vertical)
    }

    @MainActor
    func testMouseWheelAndShiftScrollingRemainIndependent() {
        var gesture = DiffScrollGesture()
        XCTAssertEqual(gesture.route(deltaX: 0, deltaY: 5, phase: [], momentumPhase: [], shift: true), .horizontal)
        XCTAssertEqual(gesture.route(deltaX: 0, deltaY: 5, phase: [], momentumPhase: [], shift: false), .vertical)
        XCTAssertEqual(gesture.route(deltaX: 0, deltaY: 0, phase: .began, momentumPhase: [], shift: false), .vertical)
        XCTAssertEqual(gesture.route(deltaX: 5, deltaY: 1, phase: .changed, momentumPhase: [], shift: false), .horizontal)
    }

    @MainActor
    func testLargeDiffViewportDrawingPerformance() throws {
        let cells = (1...10_000).map { (number: Int) in
            SideBySideDiff.Cell(text: "line \(number)", lineNumber: number, kind: .added)
        }
        let view = DiffColumnTextView(frame: .zero)
        view.update(cells: cells, filePath: "large.txt")
        view.resizeToFit(viewportWidth: 600)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 500,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let dirtyRect = NSRect(x: 0, y: 8_000 * DiffColumnTextView.rowHeight, width: 600, height: 500)
        context.cgContext.translateBy(x: 0, y: -dirtyRect.minY)
        context.cgContext.clip(to: dirtyRect)
        measure {
            for _ in 0..<10 {
                view.drawBackground(in: dirtyRect)
            }
        }
    }

    func testAutomaticLayoutThresholdAndManualOverrides() {
        XCTAssertEqual(DiffLayout.automatic.resolved(for: 0), .unified)
        XCTAssertEqual(DiffLayout.automatic.resolved(for: 799), .unified)
        XCTAssertEqual(DiffLayout.automatic.resolved(for: 800), .unified)
        XCTAssertEqual(DiffLayout.automatic.resolved(for: 801), .sideBySide)
        XCTAssertEqual(DiffLayout.automatic.resolved(for: 1400), .sideBySide)
        XCTAssertEqual(DiffLayout.unified.resolved(for: 1400), .unified)
        XCTAssertEqual(DiffLayout.sideBySide.resolved(for: 320), .sideBySide)
    }

    @MainActor
    func testLayoutPreferenceUpdatesHistoryAndStagingTogether() async throws {
        let name = "SideBySideDiffTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let raw = "diff --git a/test.swift b/test.swift\n--- a/test.swift\n+++ b/test.swift\n@@ -1 +1 @@\n-old\n+new"
        let files = [ExpandableModel(isExpanded: true, model: try FileDiff(raw: raw))]
        let root = VStack {
            DiffLayoutPicker()
            FileDiffsView(expandableFileDiffs: .constant(files))
            StageFileDiffsView(
                expandableFileDiffs: .constant(files),
                selectButtonImageSystemName: "minus.circle",
                selectFileButtonHelp: "Unstage This File",
                selectButtonHelp: "Unstage This Hunk",
                collapsedDirectories: .constant([])
            )
        }
        .defaultAppStorage(preferences)
        .frame(maxWidth: .infinity)
        .frame(height: 600)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        let scenarios: [(layout: DiffLayout?, width: CGFloat, columns: Int)] = [
            (nil, 650, 2),
            (nil, 1000, 4),
            (.automatic, 650, 2),
            (.automatic, 1000, 4),
            (.automatic, 650, 2),
            (.unified, 1000, 2),
            (.sideBySide, 650, 4),
            (.unified, 900, 2),
        ]
        for scenario in scenarios {
            if let layout = scenario.layout {
                preferences.set(layout.rawValue, forKey: PreferenceKey.diffLayout.rawValue)
            } else {
                preferences.removeObject(forKey: PreferenceKey.diffLayout.rawValue)
            }
            window.setContentSize(NSSize(width: scenario.width, height: 600))
            try await Task.sleep(for: .milliseconds(150))
            view.layoutSubtreeIfNeeded()
            let countColumns: (NSView) -> Int = { root in
                var pending = [root]
                var count = 0
                while let next = pending.popLast() {
                    count += next is DiffColumnTextView ? 1 : 0
                    pending.append(contentsOf: next.subviews)
                }
                return count
            }
            XCTAssertEqual(countColumns(view), scenario.columns, "Layout: \(String(describing: scenario.layout)), width: \(scenario.width)")
            XCTAssertEqual(preferences.string(forKey: PreferenceKey.diffLayout.rawValue), scenario.layout?.rawValue)
        }
    }

    @MainActor
    func testSideBySideRendersAtCompactAndWideWidths() async throws {
        let chunk = Chunk(raw: "@@ -120,4 +120,5 @@ func example() {\n let title = \"Hello\"\n-\tlet count = 1\n+\tlet count = 2\n+let description = \"" + String(repeating: "long line ", count: 20) + "\"\n \n return title")
        for width in [520.0, 1000.0] {
            for dark in [false, true] {
                let root = SideBySideChunkView(diff: SideBySideDiff(chunk: chunk), filePath: "Example.swift")
                    .frame(width: width)
                    .background(Color(nsColor: .textBackgroundColor))
                let view = NSHostingView(rootView: root)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = view.fittingSize
                XCTAssertEqual(size.width, width, accuracy: 1)
                XCTAssertLessThan(size.height, 400)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.orderBack(nil)
                defer { window.close() }
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                window.displayIfNeeded()
                if let directory = ProcessInfo.processInfo.environment["DIFF_SNAPSHOT_DIRECTORY"] {
                    let url = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: image)
                    let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    try png.write(to: url.appendingPathComponent("diff-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
