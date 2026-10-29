import AppKit
import FoldGitCore
import FoldGitTestSupport
import Foundation
import SwiftUI
import Testing
import XCTest
@testable import FoldGit

struct ChangeFileTreeTests {
    @Test func preservesEveryDirectoryAndSortsFoldersBeforeFilesNaturally() {
        let tree = ChangeFileTree(untrackedFiles: [
            "z.txt", "Sources/file10.swift", "Sources/file2.swift", "Sources/Nested/Deep/main.swift",
            "Folder10/a.txt", "Folder2/a.txt", ".gitignore",
        ])
        #expect(tree.rows.map(\.path) == [
            "Folder2", "Folder2/a.txt", "Folder10", "Folder10/a.txt", "Sources", "Sources/Nested",
            "Sources/Nested/Deep", "Sources/Nested/Deep/main.swift", "Sources/file2.swift", "Sources/file10.swift",
            ".gitignore", "z.txt",
        ])
        #expect(tree.rows.first { $0.path == "Sources/Nested/Deep/main.swift" }?.depth == 3)
        #expect(tree.directoryPaths == ["Folder2", "Folder10", "Sources", "Sources/Nested", "Sources/Nested/Deep"])
    }

    @Test func preservesLiteralPathsAndDistinguishesSameNamedFiles() {
        let paths = ["文档/说明 文件.md", "Sources/main.swift", "Tests/main.swift", "a\\b/name.txt", "file\nname.txt"]
        let tree = ChangeFileTree(untrackedFiles: paths)
        #expect(Set(tree.rows.compactMap(\.fileID)) == Set(paths))
        #expect(tree.rows.filter { $0.name == "main.swift" }.count == 2)
        #expect(tree.directoryPaths.contains("a\\b"))
        #expect(tree.rows.first { $0.path == "文档/说明 文件.md" }?.name == "说明 文件.md")
        #expect(Set(tree.rows.map(\.id)).count == tree.rows.count)
    }

    @Test func aDeletedFileAndItsReplacementDirectoryHaveDistinctIdentities() {
        let tree = ChangeFileTree(entries: [.init(id: "deleted", path: "item"), .init(id: "added", path: "item/child")])
        #expect(tree.rows.map(\.id) == [.directory("item"), .file("added"), .file("deleted")])
        #expect(tree.visibleRows(collapsedDirectories: ["item"]).map(\.id) == [.directory("item"), .file("deleted")])
    }

    @Test func collapsingOnlyHidesDescendantsAndRetainsNestedExpansionChoices() {
        let tree = ChangeFileTree(untrackedFiles: ["a/b/one", "a/two", "another/three", "root"])
        #expect(tree.visibleRows(collapsedDirectories: []).count == tree.rows.count)
        #expect(tree.visibleRows(collapsedDirectories: ["a", "a/b"]).map(\.path) == ["a", "another", "another/three", "root"])
        #expect(tree.visibleRows(collapsedDirectories: ["a/b"]).map(\.path) == ["a", "a/b", "a/two", "another", "another/three", "root"])
        #expect(tree.visibleRows(collapsedDirectories: tree.directoryPaths).map(\.path) == ["a", "another", "root"])
        #expect(ChangeFileTree().rows.isEmpty)
    }

    @Test func renameAndDeletionUseGitPathsWithoutReadingTheFilesystem() throws {
        let rename = try FileDiff(raw: """
        diff --git a/Old/name.swift b/New/renamed.swift
        similarity index 100%
        rename from Old/name.swift
        rename to New/renamed.swift
        """)
        let deletion = try FileDiff(raw: """
        diff --git a/Removed/old.swift b/Removed/old.swift
        deleted file mode 100644
        index aaaaaaa..0000000
        --- a/Removed/old.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -old
        """)
        let tree = ChangeFileTree(fileDiffs: [deletion, rename])
        #expect(tree.directoryPaths == ["New", "Removed"])
        #expect(tree.rows.compactMap(\.fileID) == [rename.id, deletion.id])
        #expect(rename.changeTreeTitle == "Old/name.swift → New/renamed.swift")
        #expect(deletion.changeTreeTitle == "old.swift")
    }

    @Test func refreshAndLayoutProjectionPreserveDiffIdentityAndExpansion() throws {
        let old = try modifiedFile("Sources/example.swift", content: "first")
        let fresh = try modifiedFile("Sources/example.swift", content: "second")
        let before = [ExpandableModel(isExpanded: false, model: old)]
        let refreshed = [fresh].withExpansionState(from: before)
        let tree = ChangeFileTree(fileDiffs: refreshed.map(\.model))
        let fileID = try #require(tree.rows.compactMap(\.fileID).first)
        #expect(fileID == old.id)
        #expect(refreshed.first { $0.model.id == fileID }?.isExpanded == false)
        #expect(refreshed.first { $0.model.id == fileID }?.model.raw.contains("second") == true)
        #expect(tree.visibleRows(collapsedDirectories: ["Sources"]).compactMap(\.fileID).isEmpty)
        #expect(tree.visibleRows(collapsedDirectories: []).compactMap(\.fileID) == [fileID])
    }

    @Test func binaryAndEmptyAddedFilesRemainActionableLeaves() throws {
        let binary = try FileDiff(raw: """
        diff --git a/Images/photo.png b/Images/photo.png
        index aaaaaaa..bbbbbbb 100644
        Binary files a/Images/photo.png and b/Images/photo.png differ
        """)
        let empty = try FileDiff(raw: """
        diff --git a/Data/empty.txt b/Data/empty.txt
        new file mode 100644
        index 0000000..e69de29
        """)
        let tree = ChangeFileTree(fileDiffs: [binary, empty])
        #expect(Set(tree.rows.compactMap(\.fileID)) == [binary.id, empty.id])
        #expect(binary.change.isBinary)
        #expect(empty.chunks.isEmpty)
        #expect(binary.changeTreeTitle == "photo.png")
    }

    @MainActor
    @Test func layoutDefaultsToTreePersistsAndResets() throws {
        let name = "FoldGit.ChangeFileLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preference = AppStorage(wrappedValue: AppPreferences.defaultChangeFileLayout, PreferenceKey.changeFileLayout.rawValue, store: defaults)
        #expect(preference.wrappedValue == .tree)
        preference.wrappedValue = .list
        let restored = AppStorage(wrappedValue: AppPreferences.defaultChangeFileLayout, PreferenceKey.changeFileLayout.rawValue, store: defaults)
        #expect(restored.wrappedValue == .list)
        #expect(SettingsReset.preferenceKeys.contains(.changeFileLayout))
        try SettingsReset.restore(in: defaults, ensureLoginAtDefault: {})
        #expect(restored.wrappedValue == .tree)
    }

    @Test func directoryStagingIncludesDescendantsAndUntrackedFilesWithoutTouchingNeighbors() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let directory = "目录 [1]"
        let edited = directory + "/edited.txt"
        let removed = directory + "/Deep/removed.txt"
        let partial = directory + "/Deep/partial.txt"
        let binary = directory + "/New/deep.bin"
        let empty = directory + "/New/empty.txt"
        let neighbor = "目录 1/neighbor.txt"
        try repository.write(edited, "before\n")
        try repository.write(removed, "remove\n")
        try repository.write(partial, "first\nlast\n")
        try repository.write(neighbor, "neighbor before\n")
        try await repository.commit("Add directory staging fixtures")
        try repository.write(edited, "after\n")
        try FileManager.default.removeItem(at: repository.url.appendingPathComponent(removed))
        try repository.write(partial, "staged first\nlast\n")
        try await repository.git(["--literal-pathspecs", "add", "--", partial])
        try repository.write(partial, "staged first\nunstaged last\n")
        try repository.write(empty, "")
        try Data([0, 1, 255]).write(to: repository.url.appendingPathComponent(binary))
        try repository.write(neighbor, "neighbor after\n")
        try repository.write("Elsewhere/new.txt", "outside\n")

        let before = try await WorktreeSnapshot.read(in: repository.url)
        let selection = ChangeDirectoryStaging.selection(in: directory, diff: try Diff(raw: before.unstaged),
                                                        untrackedFiles: before.status.untrackedFiles, staging: true)
        #expect(Set(selection.paths) == [edited, removed, partial, binary, empty])
        #expect(selection.patch.isEmpty)
        try await IndexStaging.apply(selection, staging: true, in: repository.url)
        let after = try await WorktreeSnapshot.read(in: repository.url)
        #expect(Set(try Diff(raw: after.staged).fileDiffs.map(\.changeTreePath)) == [edited, removed, partial, binary, empty])
        #expect(try await repository.git(["show", ":" + partial]) == "staged first\nunstaged last")
        #expect(try Diff(raw: after.unstaged).fileDiffs.map(\.changeTreePath) == [neighbor])
        #expect(after.status.untrackedFiles == ["Elsewhere/new.txt"])

        let undo = ChangeDirectoryStaging.selection(in: directory, diff: try Diff(raw: after.staged),
                                                   untrackedFiles: after.status.untrackedFiles, staging: false)
        try await IndexStaging.apply(undo, staging: false, in: repository.url)
        #expect(try await WorktreeSnapshot.read(in: repository.url).staged.isEmpty)
        #expect(try String(contentsOf: repository.url.appendingPathComponent(partial), encoding: .utf8) == "staged first\nunstaged last\n")
        #expect(try Data(contentsOf: repository.url.appendingPathComponent(binary)) == Data([0, 1, 255]))
        #expect(FileManager.default.fileExists(atPath: repository.url.appendingPathComponent(empty).path))
        #expect(!FileManager.default.fileExists(atPath: repository.url.appendingPathComponent(removed).path))
    }

    @Test func directoryUnstagingTreatsCrossDirectoryRenamesAsWholeFiles() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        try repository.write("Outside/original.txt", "rename\n")
        try repository.write("Outside/other.txt", "before\n")
        try repository.write("Destination/keep.txt", "keep\n")
        try await repository.commit("Add rename staging fixtures")
        try await repository.git(["mv", "Outside/original.txt", "Destination/renamed.txt"])
        try repository.write("Outside/other.txt", "after\n")
        try await repository.git(["add", "Outside/other.txt"])
        let diff = try Diff(raw: await repository.git(["diff", "--cached", "--find-renames"]))
        let selection = ChangeDirectoryStaging.selection(in: "Destination", diff: diff, staging: false)
        #expect(Set(selection.paths) == ["Outside/original.txt", "Destination/renamed.txt"])
        try await IndexStaging.apply(selection, staging: false, in: repository.url)
        let remaining = try await WorktreeSnapshot.read(in: repository.url)
        #expect(try Diff(raw: remaining.staged).fileDiffs.map(\.changeTreePath) == ["Outside/other.txt"])
        #expect(FileManager.default.fileExists(atPath: repository.url.appendingPathComponent("Destination/renamed.txt").path))
        #expect(ChangeDirectoryStaging.selection(in: "Missing", diff: diff, staging: true).isEmpty)
    }

    private func modifiedFile(_ path: String, content: String) throws -> FileDiff {
        try FileDiff(raw: """
        diff --git a/\(path) b/\(path)
        index aaaaaaa..bbbbbbb 100644
        --- a/\(path)
        +++ b/\(path)
        @@ -1 +1 @@
        -old
        +\(content)
        """)
    }
}

final class ChangeFileTreePresentationTests: XCTestCase {
    @MainActor
    func testTreeFitsCompactAndWidePanesInBothAppearances() async throws {
        let raw = """
        diff --git a/Sources/Features/Commit/Example.swift b/Sources/Features/Commit/Example.swift
        index aaaaaaa..bbbbbbb 100644
        --- a/Sources/Features/Commit/Example.swift
        +++ b/Sources/Features/Commit/Example.swift
        @@ -1 +1 @@
        -let old = true
        +let updated = true
        """
        let diff = try FileDiff(raw: raw)
        let files = [ExpandableModel(isExpanded: true, model: diff)]
        let untracked = ["Resources/Images/new.png", "文档/说明 文件.md"]
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "FoldGit.TreePresentationTests"))
        defer { preferences.removePersistentDomain(forName: "FoldGit.TreePresentationTests") }

        for dark in [false, true] {
            for width: CGFloat in [360, 900] {
                let root = VStack(spacing: 0) {
                    ScrollView {
                        UnstagedView(
                            fileDiffs: .constant(files), status: "", untrackedFiles: untracked,
                            onSelectFileDiff: { _ in }, onSelectChunk: { _, _ in }, onSelectUntrackedFile: { _ in },
                            layout: .tree, tree: ChangeFileTree(fileDiffs: [diff]),
                            untrackedTree: ChangeFileTree(untrackedFiles: untracked),
                            collapsedDirectories: .constant([]), collapsedUntrackedDirectories: .constant([]),
                            isExpanded: .constant(true), isUntrackedExpanded: .constant(true),
                            expandedUntrackedImages: .constant([]), onSelectDirectory: { _ in }
                        )
                    }
                    Divider()
                    StagedView(
                        fileDiffs: .constant([ExpandableModel(isExpanded: false, model: diff)]), status: "",
                        onSelectFileDiff: { _ in }, layout: .tree, tree: ChangeFileTree(fileDiffs: [diff]),
                        collapsedDirectories: .constant([]), isExpanded: .constant(true), onSelectDirectory: { _ in }
                    )
                    .frame(height: 200)
                    Divider()
                    DiffDisplayControls(changeFileLayout: .constant(.tree),
                                        onExpandDirectories: {}, onCollapseDirectories: {},
                                        onExpandAll: {}, onCollapseAll: {})
                        .padding(12)
                }
                .defaultAppStorage(preferences)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .background(Color(nsColor: .textBackgroundColor))
                .frame(width: width, height: 900)
                let view = NSHostingView(rootView: root)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.orderBack(nil)
                defer { window.close() }
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                window.displayIfNeeded()
                XCTAssertLessThanOrEqual(view.fittingSize.width, width)
                let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                let name = "change-tree-\(Int(width))-\(dark ? "dark" : "light")"
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".png"))
            }
        }
    }
}
