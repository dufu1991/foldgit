import FoldGitCore
import Testing
@testable import FoldGit

struct FileChangePresentationTests {
    @Test func lettersFollowGitStatusCodes() {
        let letters: [(FileChange.Kind, String)] = [
            (.added, "A"), (.modified, "M"), (.modeChanged, "M"), (.deleted, "D"),
            (.renamed, "R"), (.copied, "C"), (.conflicted, "U"),
        ]
        for (kind, letter) in letters {
            #expect(FileChange(kind: kind).letter == letter)
        }
    }

    @Test func detailsExplainWhatTheLetterCannotShow() {
        let rename = FileChange(kind: .renamed, similarity: 92).detail.split(separator: "\n")
        #expect(rename.count == 2)
        #expect(rename[1].contains("92"))
        let mode = FileChange(kind: .modeChanged, oldMode: "100644", newMode: "100755").detail
        #expect(mode.contains("100644") && mode.contains("100755"))
        #expect(FileChange(kind: .added, newMode: "100644", isBinary: true).detail.split(separator: "\n").count == 2)
        #expect(!FileChange(kind: .modified).detail.contains("\n"))
    }
}
