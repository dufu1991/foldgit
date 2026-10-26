import FoldGitTestSupport
import Foundation
import Testing
@testable import FoldGitCore

struct GitStatusTests {

    @Test func allConflictFormsAndRenamePathsAreParsed() throws {
        let states = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        let records = states.map { "u \($0) N... 100644 100644 100644 100644 a b c 中文 \($0).swift\0" }.joined()
            + "2 R. N... 100644 100644 100644 a b R100 new.swift\0? original.swift\0? actual.swift\0"
        let status = try GitStatus(directory: URL(fileURLWithPath: "/tmp")).parse(for: records)
        #expect(status.unmergedFiles == states.map { "中文 \($0).swift" })
        #expect(status.untrackedFiles == ["actual.swift"])
    }
}
