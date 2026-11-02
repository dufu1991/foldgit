import FoldGitCore
import Testing

struct CommitListBodyTests {
    @Test func attributionOnlyBodyHasNoListPreview() {
        let body = "Co-authored-by: Cursor <cursoragent@cursor.com>"
        let commit = makeCommit(body: body)
        #expect(commit.listBody.isEmpty)
        #expect(commit.body == body)
        #expect(commit.rawBody == "Fix rendering\n\n" + body)
    }

    @Test func removesMultipleCoauthorsAndPreservesDescription() {
        let commit = makeCommit(body: """
        Keep the chart labels visible.

        Preserve the existing scale.

        Co-authored-by: Cursor <cursoragent@cursor.com>
        CO-AUTHORED-BY: Developer <developer@example.com>
        Co-developed-by: Collaborator <collaborator@example.com>
        Co-committed-by: Contributor <contributor@example.com>
        """)
        #expect(commit.listBody == "Keep the chart labels visible.\n\nPreserve the existing scale.")
    }

    @Test func handlesCRLFWhitespaceAndFoldedAttribution() {
        let commit = makeCommit(body: "Description.\r\n\r\n  Co-authored-by : Cursor\r\n\t<cursoragent@cursor.com>\r\n")
        #expect(commit.listBody == "Description.")
    }

    @Test func preservesNormalBodyAndInlineMentions() {
        for body in ["", "Description.\n\nMore details.", "Document the Co-authored-by: trailer.", "Fixes: #123"] {
            #expect(makeCommit(body: body).listBody == body)
        }
    }

    private func makeCommit(body: String) -> Commit {
        Commit(hash: "1234567", parentHashes: [], author: "Developer", authorEmail: "developer@example.com",
               authorDate: "2026-11-02T17:00:00+08:00", title: "Fix rendering", body: body, branches: [], tags: [])
    }
}
