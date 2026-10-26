import Foundation
import Testing
@testable import FoldGit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["FOLDGIT_AI_TESTS"] == "1"))
struct IntelligenceIntegrationTests {
    @Test func diffSummaryStreamsStructuredOutput() async throws {
        let stream = IntelligenceClient().diffSummary("diff --git a/a.swift b/a.swift\n@@ -1 +1 @@\n-let x = 1\n+let x = 2")
        var summary = ""
        for try await update in stream { if let value = update.content.summary { summary = value } }
        #expect(!summary.isEmpty)
    }
}
