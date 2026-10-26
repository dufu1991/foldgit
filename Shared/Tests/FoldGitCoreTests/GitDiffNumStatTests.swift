import XCTest
@testable import FoldGitCore

final class GitDiffNumStatTests: XCTestCase {
    func testStatisticsCountParsedHunks() throws {
        let raw = """
diff --git a/Jot/Note.swift b/Jot/Note.swift
index 1111111..2222222 100644
--- a/Jot/Note.swift
+++ b/Jot/Note.swift
@@ -1,3 +1,3 @@
 keep
-old
+new
+added
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/new.txt
@@ -0,0 +1 @@
+hello
diff --git a/image.png b/image.png
index 4444444..5555555 100644
Binary files a/image.png and b/image.png differ
"""
        let stat = DiffStat(diff: try Diff(raw: raw))
        XCTAssertEqual(stat.files, ["Jot/Note.swift", "new.txt", "image.png"])
        XCTAssertEqual(stat.insertions, [2, 1, 0])
        XCTAssertEqual(stat.deletions, [1, 0, 0])
        XCTAssertEqual(stat.insertionsTotal, 3)
        XCTAssertEqual(stat.deletionsTotal, 1)
    }

    func testCombinedDiffUsesBothMarkerColumns() throws {
        let raw = """
diff --cc file.txt
index 1111111,2222222..0000000
--- a/file.txt
+++ b/file.txt
@@@ -1,1 -1,1 +1,5 @@@
++<<<<<<< HEAD
 +ours
++=======
+ theirs
++>>>>>>> feature
"""
        let stat = DiffStat(diff: try Diff(raw: raw))
        XCTAssertEqual(stat.insertions, [5])
        XCTAssertEqual(stat.deletions, [0])
    }
}
