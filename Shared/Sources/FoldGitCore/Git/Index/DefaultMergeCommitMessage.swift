import Foundation

public struct DefaultMergeCommitMessage: Sendable {
    public init(directory: URL) {
        self.directory = directory
    }

    public var directory: URL

    public func get() async throws -> String {
        let path = try await GitRuntime.run(GitRevParse(directory: directory, gitPath: "MERGE_MSG"))
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
