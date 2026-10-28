import Foundation
import FoldGitTestSupport
import Testing
@testable import FoldGitCore

struct FileChangeTests {
    private func change(_ raw: String) throws -> FileChange {
        try #require(try Diff(raw: raw).fileDiffs.first).change
    }

    @Test func headerLinesDetermineTheKind() throws {
        #expect(try change("""
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        """) == FileChange(kind: .added, newMode: "100644"))
        #expect(try change("""
        diff --git a/old.txt b/old.txt
        deleted file mode 100755
        index 3333333..0000000
        --- a/old.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -hello
        """) == FileChange(kind: .deleted, oldMode: "100755"))
        #expect(try change("""
        diff --git a/a.txt b/b.txt
        similarity index 92%
        rename from a.txt
        rename to b.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -one
        +two
        """) == FileChange(kind: .renamed, similarity: 92))
        #expect(try change("""
        diff --git a/a.txt b/c.txt
        similarity index 100%
        copy from a.txt
        copy to c.txt
        """) == FileChange(kind: .copied, similarity: 100))
        #expect(try change("""
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        """) == FileChange(kind: .modeChanged, oldMode: "100644", newMode: "100755"))
        #expect(try change("""
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        index 1111111..2222222
        --- a/run.sh
        +++ b/run.sh
        @@ -1 +1 @@
        -echo one
        +echo two
        """) == FileChange(kind: .modified, oldMode: "100644", newMode: "100755"))
        #expect(try change("""
        diff --git a/image.png b/image.png
        index 4444444..5555555 100644
        Binary files a/image.png and b/image.png differ
        """) == FileChange(kind: .modified, isBinary: true))
        #expect(try change("""
        diff --cc file.txt
        index 1111111,2222222..0000000
        --- a/file.txt
        +++ b/file.txt
        @@@ -1,1 -1,1 +1,5 @@@
        ++<<<<<<< HEAD
        """).kind == .conflicted)
    }

    @Test func realGitOutputProducesEveryKind() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let body = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try repository.write("moved.txt", body)
        try repository.write("removed.txt", "remove me\n")
        try repository.write("script.sh", "echo hi\n")
        try await repository.commit("feat: files")

        try await repository.git(["mv", "moved.txt", "renamed.txt"])
        try await repository.git(["rm", "-q", "removed.txt"])
        try repository.write("added.txt", "new\n")
        try repository.write("example.swift", "let value = 42\n")
        try Data([0, 1, 2, 3]).write(to: repository.url.appendingPathComponent("data.bin"))
        // Set the index mode directly, including on filesystems without POSIX permissions.
        try await repository.git(["add", "--all"])
        try await repository.git(["update-index", "--chmod=+x", "script.sh"])
        try await repository.git(["commit", "-m", "feat: change every kind"])

        // Commit details keep Git's rename detection; the working tree view uses --no-renames.
        let detail = try await GitRuntime.run(GitShow(directory: repository.url, object: "HEAD"))
        let kinds = Dictionary(uniqueKeysWithValues: detail.diff.fileDiffs.map { ($0.toFilePath, $0.change) })
        #expect(kinds["added.txt"]?.kind == .added)
        #expect(kinds["removed.txt"]?.kind == .deleted)
        #expect(kinds["renamed.txt"] == FileChange(kind: .renamed, similarity: 100))
        #expect(kinds["example.swift"]?.kind == .modified)
        #expect(kinds["script.sh"] == FileChange(kind: .modeChanged, oldMode: "100644", newMode: "100755"))
        #expect(kinds["data.bin"] == FileChange(kind: .added, newMode: "100644", isBinary: true))
    }
}
