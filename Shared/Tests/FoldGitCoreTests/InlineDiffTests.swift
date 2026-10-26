import Foundation
import Testing
@testable import FoldGitCore

struct InlineDiffTests {
    private func highlighted(_ cell: SideBySideDiff.Cell?) -> [String] {
        guard let cell else { return [] }
        let text = cell.text as NSString
        return cell.changedRanges.map { text.substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
    }

    @Test func multipleEditsPreserveUnchangedCodeBetweenThem() {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -1 +1 @@\n-<div class=\"full flex h-full\">\n+<div class=\"full relative h-full min-h-0 w-full\">"))
        #expect(highlighted(diff.rows[0].old) == ["flex"])
        #expect(highlighted(diff.rows[0].new) == ["relative", " min-h-0 w-full"])
        #expect(highlighted(diff.unifiedCells[1]) == highlighted(diff.rows[0].old))
        #expect(highlighted(diff.unifiedCells[2]) == highlighted(diff.rows[0].new))
    }

    @Test func insertedTextInsideChineseCommentDoesNotHighlightExistingText() {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -1 +1 @@\n-<!-- 数据概览 -->\n+<!-- 数据概览：铺满内容区，保证地图容器有实际宽高 -->"))
        #expect(highlighted(diff.rows[0].old).isEmpty)
        #expect(highlighted(diff.rows[0].new).joined() == "：铺满内容区，保证地图容器有实际宽高")
    }

    @Test func unicodeRangesPreserveWholeGraphemesAndUTF16Offsets() {
        let old = "let 文本 = \"👨‍👩‍👧‍👦 旧值 👍🏽 e\u{301}\""
        let new = "let 文本 = \"👨‍👩‍👧‍👦 新值 👍🏻 o\u{308}\""
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -1 +1 @@\n-\(old)\n+\(new)"))
        #expect(highlighted(diff.rows[0].old) == ["旧", "👍🏽", "e\u{301}"])
        #expect(highlighted(diff.rows[0].new) == ["新", "👍🏻", "o\u{308}"])
        for cell in diff.rows.flatMap({ [$0.old, $0.new].compactMap { $0 } }) + diff.unifiedCells {
            let boundaries = Set(cell.text.indices.map { $0.utf16Offset(in: cell.text) } + [cell.text.utf16.count])
            for range in cell.changedRanges {
                #expect(boundaries.contains(range.lowerBound))
                #expect(boundaries.contains(range.upperBound))
            }
        }
    }

    @Test func nearbyIdentifierChangesRefineToCharacters() {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -1 +1 @@\n-let itemCount = 10\n+let itemCounts = 20"))
        #expect(highlighted(diff.rows[0].old) == ["1"])
        #expect(highlighted(diff.rows[0].new) == ["s", "2"])
    }

    @Test func insertedLineDoesNotShiftFollowingReplacements() {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -1,2 +1,3 @@\n-let title = \"Old\"\n-let count = 10\n+// Added explanation\n+let title = \"New\"\n+let count = 20"))
        #expect(diff.rows.count == 3)
        #expect(diff.rows[0].old == nil)
        #expect(diff.rows[1].old?.lineNumber == 1)
        #expect(diff.rows[1].new?.lineNumber == 2)
        #expect(highlighted(diff.rows[2].old) == ["1"])
        #expect(highlighted(diff.rows[2].new) == ["2"])
        #expect(highlighted(diff.unifiedCells[2]) == ["1"])
        #expect(highlighted(diff.unifiedCells[5]) == ["2"])
    }

    @Test func pureChangesAndUnrelatedReplacementsKeepWholeLineStyling() {
        for raw in ["@@ -0,0 +1 @@\n+new", "@@ -1 +0,0 @@\n-old", "@@ -1 +1 @@\n-abc\n+XYZ"] {
            let diff = SideBySideDiff(chunk: Chunk(raw: raw))
            #expect(diff.rows.flatMap { [$0.old, $0.new].compactMap { $0 } }.allSatisfy { $0.changedRanges.isEmpty })
        }
    }

    @Test func unrelatedLinesRetainStablePositionalPairing() {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -1,2 +1 @@\n-old first\n-old second\n+new"))
        #expect(diff.rows[0].old?.text == "old first")
        #expect(diff.rows[0].new?.text == "new")
        #expect(diff.rows[1].old?.text == "old second")
        #expect(diff.rows[1].new == nil)
    }

    @Test func removingHighlightedFragmentsLeavesIdenticalText() {
        let fragments = ["count", "value", "20", " ", "-", "旧", "新", "👨‍👩‍👧‍👦", "👍🏽", "e\u{301}"]
        var seed: UInt64 = 42
        let next = { () -> Int in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(fragments.count))
        }
        let unchangedText = { (cell: SideBySideDiff.Cell) in
            let text = NSMutableString(string: cell.text)
            for range in cell.changedRanges.reversed() {
                text.deleteCharacters(in: NSRange(location: range.lowerBound, length: range.count))
            }
            return text as String
        }
        for _ in 0..<200 {
            let old = "let text = \"" + (0..<12).map { _ in fragments[next()] }.joined() + "\""
            let new = "let text = \"" + (0..<12).map { _ in fragments[next()] }.joined() + "\""
            let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -1 +1 @@\n-\(old)\n+\(new)"))
            let oldCell = diff.rows[0].old!
            let newCell = diff.rows[0].new!
            if !oldCell.changedRanges.isEmpty || !newCell.changedRanges.isEmpty {
                #expect(unchangedText(oldCell) == unchangedText(newCell))
            }
        }
    }

    @Test func whitespaceAndEmptyLinesArePreserved() {
        let raw = "@@ -1,2 +1,2 @@\n-\tlet count = 1  \n-\n+    let count = 1 \n+"
        let chunk = Chunk(raw: raw)
        let diff = SideBySideDiff(chunk: chunk)
        #expect(highlighted(diff.rows[0].old).joined().contains("\t"))
        #expect(highlighted(diff.rows[0].new).joined().contains("    "))
        #expect(diff.rows[1].old?.text == "")
        #expect(diff.rows[1].new?.text == "")
        #expect(diff.unifiedCells.map(\.text) == chunk.lines.map(\.raw))
        #expect(chunk.raw == raw)
    }

    @Test func endOfFileAnnotationsDoNotShiftUnifiedHighlights() {
        let diff = SideBySideDiff(chunk: Chunk(raw: "@@ -5 +5 @@\n-let count = 1\n\\ No newline at end of file\n+let count = 2\n\\ No newline at end of file"))
        #expect(highlighted(diff.unifiedCells[1]) == ["1"])
        #expect(highlighted(diff.unifiedCells[3]) == ["2"])
        #expect(diff.unifiedCells[3].lineNumber == 5)
        #expect(diff.unifiedCells[2].lineNumber == nil)
        #expect(diff.unifiedCells[4].lineNumber == nil)
    }

    @Test func oversizedLinesAndExhaustedBudgetSkipExpensiveWork() {
        let old = String(repeating: "a", count: 10_000) + "1"
        let new = String(repeating: "a", count: 10_000) + "2"
        var budget = InlineDiff.Budget()
        let result = InlineDiff.ranges(old: old, new: new, budget: &budget)
        #expect(result.old.isEmpty && result.new.isEmpty)
        #expect(budget.remaining == 1_000_000)
        budget.remaining = 0
        let exhausted = InlineDiff.ranges(old: "let count = 1", new: "let count = 2", budget: &budget)
        #expect(exhausted.old.isEmpty && exhausted.new.isEmpty)
    }

    @Test func largeBlocksPreserveAllLinesWithoutAnUnboundedAlignmentMatrix() {
        let count = 10_000
        let raw = "@@ -1,\(count) +1,\(count) @@\n"
            + (0..<count).map { "-let value\($0) = 1" }.joined(separator: "\n") + "\n"
            + (0..<count).map { "+let value\($0) = 2" }.joined(separator: "\n")
        let diff = SideBySideDiff(chunk: Chunk(raw: raw))
        #expect(diff.rows.count == count)
        #expect(diff.unifiedCells.count == count * 2 + 1)
        #expect(diff.rows.last?.old?.lineNumber == count)
        #expect(diff.rows.last?.new?.lineNumber == count)
        #expect(highlighted(diff.rows[0].new) == ["2"])
    }

    @Test func boundedMatrixStillPreservesCommonEdges() {
        let old = "prefix " + String(repeating: "a", count: 1_000) + " suffix"
        let new = "prefix " + String(repeating: "b", count: 1_000) + " suffix"
        var budget = InlineDiff.Budget(remaining: 3_000)
        let result = InlineDiff.ranges(old: old, new: new, budget: &budget)
        #expect(result.old == [7..<1_007])
        #expect(result.new == [7..<1_007])
        #expect(budget.remaining >= 0)
    }
}
