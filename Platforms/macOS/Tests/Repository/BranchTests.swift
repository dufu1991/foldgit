import AppKit
import FoldGitCore
import SwiftUI
import XCTest
@testable import FoldGit

final class BranchTests: XCTestCase {
    func testPoint() throws {
        let branch = Branch(name: "main", isCurrent: true)
        XCTAssertEqual(branch.point, "main")
    }

    func testPointForDetached() throws {
        let branch = Branch(name: "(HEAD detached at a036829)", isCurrent: true)
        XCTAssertEqual(branch.point, "a036829")
    }

    func testCurrentBranchIsPinnedWhileOtherBranchesKeepTheirOrder() throws {
        let branches = try GitBranch(directory: URL(fileURLWithPath: "/tmp")).parse(for: "  feature/recent\n* main\n  feature/older\n")
        XCTAssertEqual(branches.currentFirst.map(\.name), ["main", "feature/recent", "feature/older"])
        XCTAssertEqual(branches.currentFirst.first?.isCurrent, true)
        XCTAssertEqual(branches.current?.name, "main")
    }

    func testRemoteSymbolicHeadIsNotListedAsABranch() throws {
        let branches = try GitBranch(directory: URL(fileURLWithPath: "/tmp"), isRemote: true).parse(for: "  origin/HEAD -> origin/main\n  origin/main\n  upstream/main\n")
        XCTAssertEqual(branches.map(\.name), ["origin/main", "upstream/main"])
        XCTAssertNil(branches.current)
    }

    func testDetachedHeadRemainsTheCurrentEntry() throws {
        let branches = try GitBranch(directory: URL(fileURLWithPath: "/tmp")).parse(for: "  main\n* (HEAD detached at a036829)\n")
        XCTAssertEqual(branches.currentFirst.first?.point, "a036829")
        XCTAssertEqual(branches.currentFirst.first?.isDetached, true)
    }

    @MainActor
    func testGroupedBranchesRenderCollapsedAndExpanded() async throws {
        let local = [
            Branch(name: "feature/long-branch-name-for-layout-verification", isCurrent: false),
            Branch(name: "main", isCurrent: true),
            Branch(name: "develop", isCurrent: false),
        ]
        let remote = [Branch(name: "origin/main", isCurrent: false), Branch(name: "upstream/develop", isCurrent: false)]
        for expanded in [false, true] {
            for dark in [false, true] {
                let root = BranchListContentView(
                    localBranches: local,
                    remoteBranches: remote,
                    filterText: "",
                    isRemoteExpanded: .constant(expanded),
                    onSelect: { _ in },
                    onSelectRemote: { _ in }
                ) { _, _ in EmptyView() }
                .frame(width: 360, height: 420)
                .background(Color(nsColor: .windowBackgroundColor))
                let view = NSHostingView(rootView: root)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.orderBack(nil)
                defer { window.close() }
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                window.displayIfNeeded()
                XCTAssertEqual(view.fittingSize.width, 360, accuracy: 1)
                if let directory = ProcessInfo.processInfo.environment["BRANCH_SNAPSHOT_DIRECTORY"] {
                    let url = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: image)
                    let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    try png.write(to: url.appendingPathComponent("branches-\(expanded ? "expanded" : "collapsed")-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
