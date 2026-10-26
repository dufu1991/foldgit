import Testing
@testable import FoldGitCore

struct ExpandableModelTests {

    struct Dummy: Hashable {
        let id: Int
        let name: String
    }

    @Test
    func testPreservesExpansionState() {
        let old: [ExpandableModel<Dummy>] = [
            ExpandableModel(isExpanded: false, model: Dummy(id: 1, name: "one")),
            ExpandableModel(isExpanded: false, model: Dummy(id: 2, name: "two"))
        ]
        let new: [Dummy] = [
            Dummy(id: 1, name: "one"),
            Dummy(id: 3, name: "three")
        ]

        let result = new.withExpansionState(from: old)

        #expect(result.count == 2)
        #expect(result[0].model == Dummy(id: 1, name: "one"))
        #expect(result[0].isExpanded == false)
        #expect(result[1].model == Dummy(id: 3, name: "three"))
        #expect(result[1].isExpanded == true) // default
    }

    @Test
    func testAllNewModelsDefaultToExpanded() {
        let old: [ExpandableModel<Dummy>] = []
        let new: [Dummy] = [
            Dummy(id: 10, name: "ten"),
            Dummy(id: 20, name: "twenty")
        ]

        let result = new.withExpansionState(from: old)

        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.isExpanded })
    }

    @Test
    func testEmptyUpdateReturnsEmpty() {
        let old: [ExpandableModel<Dummy>] = [
            ExpandableModel(isExpanded: true, model: Dummy(id: 1, name: "one"))
        ]
        let new: [Dummy] = []

        let result = new.withExpansionState(from: old)
        #expect(result.isEmpty)
    }

    @Test func collapsedDefaultAppliesToAllNewFiles() {
        let files = [Dummy(id: 1, name: "one"), Dummy(id: 2, name: "two")]
        let result = files.withExpansionState(from: [], defaultIsExpanded: false)
        #expect(result.map(\.model) == files)
        #expect(result.allSatisfy { !$0.isExpanded })
    }

    @Test func changedFileDiffKeepsItsExpansionState() throws {
        let old = try FileDiff(raw: "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b")
        let new = try FileDiff(raw: "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+c")
        #expect(old.id == new.id)
        #expect(old.chunks[0].id == new.chunks[0].id)
        let result = [new].withExpansionState(from: [ExpandableModel(isExpanded: false, model: old)])
        #expect(result.map(\.isExpanded) == [false])
        #expect(result[0].model == new)
    }

    @Test func refreshedFilesKeepManualStateWhileNewFilesUseTheDefault() {
        let files = [Dummy(id: 1, name: "one"), Dummy(id: 2, name: "two"), Dummy(id: 3, name: "three")]
        let old = [ExpandableModel(isExpanded: true, model: files[0]),
                   ExpandableModel(isExpanded: false, model: files[1])]
        for defaultIsExpanded in [false, true] {
            let result = files.withExpansionState(from: old, defaultIsExpanded: defaultIsExpanded)
            #expect(result.map(\.isExpanded) == [true, false, defaultIsExpanded])
        }
    }
}
