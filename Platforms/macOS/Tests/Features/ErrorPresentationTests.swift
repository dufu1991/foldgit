import FoldGitCore
import Foundation
import XCTest
@testable import FoldGit

final class ErrorPresentationTests: XCTestCase {
    func testOperationContextPreservesGitDetailsAndLogLink() {
        let id = UUID()
        let directory = URL(fileURLWithPath: "/tmp/foldgit-error-tests")
        let original = GitExecutionError(description: "Permission denied (publickey).", commandLogID: id, directory: directory)
        let failure = OperationFailure("Fetch", original, directory: directory)

        XCTAssertEqual(failure.operation, String(localized: "Fetch"))
        XCTAssertEqual(failure.reason, original.localizedDescription)
        XCTAssertEqual(failure.gitFailure?.commandLogID, id)
        XCTAssertEqual(failure.gitFailure?.directory, directory)
        XCTAssertEqual(failure.directory, directory)
    }

    func testPropagatedFailureDoesNotDuplicateOperationInReason() {
        let original = GenericError(errorDescription: "Network is unreachable.")
        let failure = OperationFailure("Fetch", OperationFailure("Automatic Fetch", original))

        XCTAssertEqual(failure.reason, original.localizedDescription)
        XCTAssertEqual(failure.localizedDescription, String(localized: "Fetch") + "\n" + original.localizedDescription)
    }

    func testFailedFileOpeningIncludesTheRequestedPath() throws {
        let file = URL(fileURLWithPath: "/tmp/foldgit-error-tests/missing.txt")
        var requested: URL?
        let failure = FileOpening.open(file) {
            requested = $0
            return false
        }

        XCTAssertEqual(requested, file)
        let details = try XCTUnwrap(failure)
        XCTAssertEqual(details.operation, String(localized: "Open File"))
        XCTAssertTrue(details.reason.contains(file.path))
    }

    func testSuccessfulFileOpeningDoesNotReportAnError() {
        XCTAssertNil(FileOpening.open(URL(fileURLWithPath: "/tmp/example.txt")) { _ in true })
    }
}
