import Foundation
import Testing
@testable import FoldGitCore

struct SharedFixtureTests {
    private struct Fixtures: Decodable {
        struct DiffCase: Decodable { let raw: String; let path: String; let added: Int; let removed: Int }
        struct GraphCase: Decodable { let hash: String; let parents: [String]; let column: Int }
        struct InlineCase: Decodable { let old: String; let new: String; let oldSpans: [[Int]]; let newSpans: [[Int]] }
        let diffs: [DiffCase]
        let graph: [GraphCase]
        let inline: [InlineCase]
    }

    @Test func portableBehaviorFixtures() throws {
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: shared.appendingPathComponent("Fixtures/behavior.json")))
        for item in fixtures.diffs {
            let diff = try Diff(raw: item.raw)
            #expect(diff.fileDiffs.count == 1)
            #expect(diff.fileDiffs.first?.toFilePath == item.path)
        }
        let commits = fixtures.graph.map {
            Commit(hash: $0.hash, parentHashes: $0.parents, author: "Developer", authorEmail: "dev@example.com",
                   authorDate: "2026-10-26T00:00:00Z", title: $0.hash, body: "", branches: [], tags: [])
        }
        #expect(CommitGraph().positionedCommits(commits).map(\.column) == fixtures.graph.map(\.column))
        for item in fixtures.inline {
            var budget = InlineDiff.Budget()
            let result = InlineDiff.ranges(old: item.old, new: item.new, budget: &budget)
            #expect(result.old.map { [$0.lowerBound, $0.count] } == item.oldSpans)
            #expect(result.new.map { [$0.lowerBound, $0.count] } == item.newSpans)
        }
    }
}
