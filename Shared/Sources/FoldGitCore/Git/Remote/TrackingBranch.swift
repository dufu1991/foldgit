import Foundation

public struct TrackingBranch: Sendable {
    public init(remote: String, remoteBranch: String, upstream: String? = nil, ahead: Int, behind: Int) {
        self.remote = remote
        self.remoteBranch = remoteBranch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }

    public let remote: String
    public let remoteBranch: String
    public let upstream: String?
    public let ahead: Int
    public let behind: Int

    public static func inspect(in directory: URL, branch: String) async throws -> TrackingBranch? {
        let refs = try await GitRuntime.run(arguments: [
            "git", "for-each-ref", "--format=%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream)",
            "refs/heads/\(branch)",
        ], currentDirectoryURL: directory, readOnly: true)
        let fields = refs.standardOutput.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
        if fields.count == 3, !fields[0].isEmpty, !fields[2].isEmpty {
            let counts = try await GitRuntime.run(arguments: [
                "git", "rev-list", "--left-right", "--count", "HEAD...\(fields[2])",
            ], currentDirectoryURL: directory, readOnly: true)
            let values = counts.standardOutput.split(whereSeparator: \.isWhitespace)
            guard values.count == 2, let ahead = Int(values[0]), let behind = Int(values[1]) else {
                throw GitExecutionError(description: "Invalid ahead/behind counts from Git.")
            }
            return TrackingBranch(remote: fields[0], remoteBranch: String(fields[1].dropFirst("refs/heads/".count)),
                                  upstream: fields[2], ahead: ahead, behind: behind)
        }
        let output = try await GitRuntime.run(arguments: ["git", "remote"], currentDirectoryURL: directory, readOnly: true)
        let remotes = output.standardOutput.split(separator: "\n").map(String.init)
        let branchRemote = try? await GitRuntime.run(arguments: ["git", "config", "--get", "branch.\(branch).pushRemote"], currentDirectoryURL: directory, readOnly: true)
        let pushDefault = try? await GitRuntime.run(arguments: ["git", "config", "--get", "remote.pushDefault"], currentDirectoryURL: directory, readOnly: true)
        let configuredRemote = (branchRemote ?? pushDefault)?.standardOutput.trimmingCharacters(in: .newlines)
        let remote: String?
        if let configuredRemote, remotes.contains(configuredRemote) { remote = configuredRemote }
        else if remotes.contains("origin") { remote = "origin" }
        else if remotes.count == 1 { remote = remotes[0] }
        else { remote = nil }
        guard let remote else { return nil }
        let unpublished = try await GitRuntime.run(arguments: [
            "git", "rev-list", "--count", "HEAD", "--not", "--remotes=\(remote)",
        ], currentDirectoryURL: directory, readOnly: true)
        guard let ahead = Int(unpublished.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw GitExecutionError(description: "Invalid unpublished commit count from Git.")
        }
        return TrackingBranch(remote: remote, remoteBranch: branch, upstream: nil, ahead: ahead, behind: 0)
    }
}
