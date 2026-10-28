import AppKit
import FoldGitCore
import SwiftUI
import XCTest
@testable import FoldGit

final class CommitGraphTests: XCTestCase {
    private func commit(_ hash: String, parents: [String] = [], title: String = "Commit", branches: [String] = []) -> Commit {
        Commit(hash: hash, parentHashes: parents, author: "Developer", authorEmail: "dev@example.com",
               authorDate: "2026-10-23T10:00:00Z", title: title, body: "", branches: branches, tags: [])
    }

    private var nestedMerges: [Commit] {
        [
            commit("a31f1a1", parents: ["b85a23c"], title: "Restore pane working directory", branches: ["HEAD -> main"]),
            commit("b85a23c", parents: ["d90a4b2", "c47d019"], title: "Merge feature branch into main"),
            commit("c47d019", parents: ["e61f2a8"], title: "Keep synchronized frames atomic", branches: ["feature/terminal"]),
            commit("e61f2a8", parents: ["f83b0e6", "a16d8f2"], title: "Merge nested terminal improvements"),
            commit("a16d8f2", parents: ["b92c4d5"], title: "Fix dispatch in nested terminals"),
            commit("d90a4b2", parents: ["c18f7a3"], title: "Keep a window snapshot when one pane closes, including a long description that must stay clear of the branch graph"),
            commit("c18f7a3", parents: ["f83b0e6"], title: "Stop tab rename editor from pinning the command"),
            commit("b92c4d5", parents: ["f83b0e6"], title: "Preserve alternate screen when clearing scrollback"),
            commit("f83b0e6", parents: ["d31b9e4"], title: "Keep private release recovery local"),
            commit("d31b9e4", parents: ["e28c1f7", "f72a0c9"], title: "Merge documentation updates"),
            commit("f72a0c9", parents: ["a04e6b1"], title: "Ship font licence texts", branches: ["docs/licences"]),
            commit("e28c1f7", parents: ["a04e6b1"], title: "Update contributors"),
            commit("a04e6b1", title: "Initial commit"),
        ]
    }

    func testLinearHistoryKeepsOneLaneAndOneColor() {
        let rows = CommitGraph().positionedCommits([
            commit("c", parents: ["b"]), commit("b", parents: ["a"]), commit("a"),
        ])
        XCTAssertEqual(rows.map(\.column), [0, 0, 0])
        XCTAssertEqual(Set(rows.map(\.colorIndex)).count, 1)
        XCTAssertFalse(rows[0].segments.contains { $0.start == .top })
        XCTAssertFalse(rows[2].segments.contains { $0.start == .node })
    }

    func testNestedMergesReserveLanesUntilTheirParentsAreReached() throws {
        let rows = CommitGraph().positionedCommits(nestedMerges)
        let main = try XCTUnwrap(rows.first { $0.id == "d90a4b2" })
        let feature = try XCTUnwrap(rows.first { $0.id == "c47d019" })
        let nested = try XCTUnwrap(rows.first { $0.id == "a16d8f2" })
        XCTAssertEqual(main.column, 0)
        XCTAssertEqual(feature.column, 1)
        XCTAssertEqual(nested.column, 2)
        XCTAssertEqual(Set([main.colorIndex, feature.colorIndex, nested.colorIndex]).count, 3)
        let ancestor = try XCTUnwrap(rows.first { $0.id == "f83b0e6" })
        XCTAssertEqual(ancestor.column, main.column)
        XCTAssertEqual(ancestor.colorIndex, main.colorIndex)
        for index in 0..<(rows.count - 1) {
            let outgoing = rows[index].segments.filter { $0.end == .bottom }
            let incoming = rows[index + 1].segments.filter { $0.start == .top }
            XCTAssertEqual(Set(outgoing.map(\.toColumn)), Set(incoming.map(\.fromColumn)))
        }
    }

    func testMissingParentsDoNotOccupyPhantomLanesInFilteredHistory() {
        let rows = CommitGraph().positionedCommits([
            commit("c", parents: ["missing"]), commit("b", parents: ["also-missing"]), commit("a"),
        ])
        XCTAssertEqual(rows.map(\.column), [0, 0, 0])
        XCTAssertTrue(rows[0].segments.contains { $0.isBoundary })
        XCTAssertFalse(rows[1].segments.contains { $0.start == .top })
    }

    func testSharedAncestorKeepsSeparateLanesUntilItsNode() {
        let rows = CommitGraph().positionedCommits([
            commit("merge", parents: ["main", "side"]),
            commit("side", parents: ["root"]),
            commit("main", parents: ["root"]),
            commit("root"),
        ])
        XCTAssertEqual(rows.map(\.column), [0, 1, 0, 0])
        let sideEdge = rows[1].segments.first { $0.start == .node }
        XCTAssertEqual(sideEdge?.toColumn, 1)
        let sideContinuation = rows[2].segments.first { $0.fromColumn == 1 && $0.start == .top }
        XCTAssertEqual(sideContinuation?.toColumn, 1)
        XCTAssertEqual(sideContinuation?.end, .bottom)
        XCTAssertEqual(rows[2].segments.first { $0.start == .node }?.toColumn, 0)
        let incoming = rows[3].segments.filter { $0.start == .top }
        XCTAssertEqual(incoming.map(\.fromColumn), [0, 1])
        XCTAssertTrue(incoming.allSatisfy { $0.end == .node && $0.toColumn == rows[3].column })
    }

    func testMergeParentWithAnExistingLaneGetsItsOwnEdge() {
        let rows = CommitGraph().positionedCommits([
            commit("tip", parents: ["main", "side"]),
            commit("side", parents: ["side-base", "main"]),
            commit("side-base", parents: ["main"]),
            commit("main", parents: ["root"]),
            commit("root"),
        ])
        XCTAssertEqual(rows[1].segments.filter { $0.start == .node }.map(\.toColumn), [1, 2])
        let incoming = rows[3].segments.filter { $0.start == .top }
        XCTAssertEqual(incoming.map(\.fromColumn), [0, 1, 2])
        XCTAssertTrue(incoming.allSatisfy { $0.end == .node && $0.toColumn == rows[3].column })
        XCTAssertEqual(rows[4].segments.filter { $0.start == .top }.map(\.fromColumn), [0])
    }

    func testEveryVisibleParentEdgeReachesItsCommitBeforeJoining() throws {
        let rows = CommitGraph().positionedCommits(nestedMerges)
        for (index, row) in rows.enumerated() {
            let edges = row.segments.filter { $0.start == .node && !$0.isBoundary }
            XCTAssertEqual(edges.count, row.commit.parentHashes.count)
            for (parent, edge) in zip(row.commit.parentHashes, edges) {
                var reachedParent = false
                for next in rows.dropFirst(index + 1) {
                    let continuation = try XCTUnwrap(next.segments.first {
                        $0.start == .top && $0.fromColumn == edge.toColumn
                    })
                    XCTAssertEqual(continuation.colorIndex, edge.colorIndex)
                    if next.id == parent {
                        XCTAssertEqual(continuation.end, .node)
                        XCTAssertEqual(continuation.toColumn, next.column)
                        reachedParent = true
                        break
                    }
                    XCTAssertEqual(continuation.end, .bottom)
                    XCTAssertEqual(continuation.toColumn, edge.toColumn)
                }
                XCTAssertTrue(reachedParent, "Edge from \(row.id) must reach \(parent)")
            }
        }
    }

    func testOctopusMergeUsesDistinctLanes() {
        let rows = CommitGraph().positionedCommits([
            commit("merge", parents: ["a", "b", "c"]), commit("c", parents: ["root"]),
            commit("b", parents: ["root"]), commit("a", parents: ["root"]), commit("root"),
        ])
        XCTAssertEqual(rows[0].segments.filter { $0.start == .node }.map(\.toColumn), [0, 1, 2])
        XCTAssertEqual(Set(rows.dropFirst().prefix(3).map(\.column)), Set([0, 1, 2]))
        XCTAssertEqual(rows.last?.column, 0)
        XCTAssertEqual(rows.last?.colorIndex, rows.first?.colorIndex)
    }

    func testEmptyHistoryAndRootWithEmptyParentField() {
        XCTAssertTrue(CommitGraph().positionedCommits([]).isEmpty)
        let rows = CommitGraph().positionedCommits([commit("root", parents: [""])])
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].segments.isEmpty)
    }

    func testReusedColorsDoNotMatchTheLiveMainTrack() {
        var commits: [Commit] = []
        for index in 0..<20 {
            commits.append(commit("main-\(index)", parents: ["main-\(index + 1)", "side-\(index)"]))
            commits.append(commit("side-\(index)", parents: ["main-\(index + 1)"]))
        }
        commits.append(commit("main-20"))
        let rows = CommitGraph().positionedCommits(commits)
        let mainColor = rows[0].colorIndex % CommitGraph.colorCount
        for row in rows {
            if row.id.hasPrefix("side-") {
                XCTAssertNotEqual(row.colorIndex % CommitGraph.colorCount, mainColor)
            } else {
                XCTAssertEqual(row.column, 0)
                XCTAssertEqual(row.colorIndex % CommitGraph.colorCount, mainColor)
            }
        }
    }

    @MainActor
    func testRoundedRoutesStayInsideTheGraphGutter() {
        let rows = CommitGraph().positionedCommits(nestedMerges)
        let width = CommitGraphStyle.gutterWidth(columnCount: rows.map(\.columnCount).max()!)
        var curvedEdges = 0
        for row in rows {
            for segment in row.segments {
                let path = CommitGraphStyle.path(for: segment)
                XCTAssertGreaterThanOrEqual(path.boundingRect.minX, 0)
                XCTAssertLessThan(path.boundingRect.maxX, width)
                XCTAssertGreaterThanOrEqual(path.boundingRect.minY, 0)
                XCTAssertLessThanOrEqual(path.boundingRect.maxY, CommitGraphStyle.rowHeight)
                if segment.fromColumn != segment.toColumn {
                    path.forEach { element in
                        if case .quadCurve = element { curvedEdges += 1 }
                    }
                }
            }
        }
        XCTAssertGreaterThan(curvedEdges, 0)
    }

    func testLargeLinearHistoryLayoutPerformance() {
        let commits = (0..<10_000).map { index in
            commit(String(index), parents: index < 9_999 ? [String(index + 1)] : [])
        }
        measure {
            let rows = CommitGraph().positionedCommits(commits)
            XCTAssertEqual(rows.count, 10_000)
            XCTAssertEqual(rows.last?.column, 0)
        }
    }

    @MainActor
    func testLabelsFollowEachRowsLanesAndStayClearOfAllBranchPaths() throws {
        let rows = CommitGraph().positionedCommits(nestedMerges)
        let first = try XCTUnwrap(rows.first)
        let nested = try XCTUnwrap(rows.first { $0.id == "a16d8f2" })
        XCTAssertLessThan(CommitGraphStyle.textLeading(for: first), CommitGraphStyle.textLeading(for: nested))
        for row in rows {
            let textX = CommitGraphStyle.textLeading(for: row)
            XCTAssertGreaterThanOrEqual(textX - CommitGraphStyle.x(column: row.column), 18)
            for segment in row.segments {
                let rightEdge = CommitGraphStyle.path(for: segment).boundingRect.maxX + CommitGraphStyle.lineWidth / 2
                XCTAssertGreaterThanOrEqual(textX - rightEdge, 12)
            }
            if row.column == row.columnCount - 1 {
                XCTAssertEqual(textX - CommitGraphStyle.x(column: row.column), 18)
            }
        }
    }

    @MainActor
    func testGraphRendersAtNarrowAndWideWidthsInBothAppearances() async throws {
        let rows = CommitGraph().positionedHistory(nestedMerges, headHash: nestedMerges.first?.hash, showsWorkingTree: true)
        for width in [320.0, 520.0] {
            for dark in [false, true] {
                let root = ScrollView {
                    CommitGraphContentView(
                        selectionLogID: .constant("e61f2a8"), subSelectionLogID: .constant("d31b9e4"),
                        logStore: HistoryStore(), showing: .constant(RepositoryPresentation()), isRefresh: .constant(false),
                        commits: rows, viewportWidth: width
                    )
                }
                .frame(width: width, height: 840)
                .background(Color(nsColor: .textBackgroundColor))
                let view = NSHostingView(rootView: root)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 840), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.orderBack(nil)
                defer { window.close() }
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                window.displayIfNeeded()
                XCTAssertEqual(view.fittingSize.width, width, accuracy: 1)
                if let directory = ProcessInfo.processInfo.environment["GRAPH_SNAPSHOT_DIRECTORY"] {
                    let url = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: image)
                    let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    try png.write(to: url.appendingPathComponent("graph-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @MainActor
    func testWorkingTreeAttachesToLocalHeadBelowIncomingHistory() throws {
        let history = [commit("remote", parents: ["head"]), commit("head", parents: ["root"]), commit("root")]
        let rows = CommitGraph().positionedHistory(history, headHash: "head", showsWorkingTree: true)
        XCTAssertEqual(rows.map(\.id), ["remote", Log.notCommitted.id, "head", "root"])
        let workingTree = try XCTUnwrap(rows.first { $0.id == Log.notCommitted.id })
        XCTAssertEqual(workingTree.commit.parentHashes, ["head"])
        XCTAssertTrue(workingTree.segments.contains { $0.start == .top && $0.end == .bottom })
        let head = try XCTUnwrap(rows.first { $0.id == "head" })
        XCTAssertTrue(head.segments.contains { $0.start == .top && $0.end == .node && $0.fromColumn == workingTree.column })
        XCTAssertEqual(CommitGraphStyle.textLeading(for: rows[0]), 34)
    }

}
