import Foundation

public struct SquashPlan: Identifiable, Sendable {
    public var id: String { head }
    public let head: String
    public let branch: String
    public let commits: [Commit]
    public let followingCount: Int
    public let message: String
}

/// Squashing always validates the actual parent chain and freshly fetched publication state.
public enum GitSquash {
    private struct Git: InteractiveRepositoryCommand {
        var directory: URL
        var args: [String]
        var environment: [String: String] = [:]
        var inputs: [String] = []
        var arguments: [String] { ["git"] + args }
        var isReadOnly: Bool {
            guard let command = args.first else { return false }
            return ["rev-parse", "for-each-ref", "rev-list", "show", "remote"].contains(command)
        }
        func parse(for output: String) -> String { output.trimmingCharacters(in: .newlines) }
    }

    private struct Recovery: Codable {
        let head: String
        let branch: String
        let tree: String
        let backup: String
    }

    private static func failure(_ message: String) -> GitExecutionError {
        GitExecutionError(description: NSLocalizedString(message, comment: "Squash commits"))
    }

    public static func selectionError(_ hashes: Set<String>, commits: [Commit], head: String?) -> String? {
        guard hashes.count >= 2 else { return "Select at least two consecutive commits." }
        let chain = commits.firstParentChain(from: head)
        let indices = chain.indices.filter { hashes.contains(chain[$0].hash) }
        guard indices.count == hashes.count, let first = indices.first, let last = indices.last,
            last - first + 1 == hashes.count
        else { return "Select consecutive commits on the current branch." }
        guard chain[...last].allSatisfy({ $0.parentHashes.count <= 1 }) else {
            return "The affected history contains a merge commit."
        }
        return nil
    }

    public static func prepare(in directory: URL, hashes: Set<String>) async throws -> SquashPlan {
        try await GitRuntime.read(at: directory) { session in
            try await recover(using: session)
            return try await prepare(using: session, hashes: hashes).plan
        }
    }

    /// Returns the plan with the first-parent chain from HEAD it was validated against.
    private static func prepare(using session: GitRuntime.Session, hashes: Set<String>) async throws -> (
        plan: SquashPlan, chain: [Commit]
    ) {
        let directory = session.directory
        let gitDirectory = try await session.run(GitAbsoluteGitDirectory(directory: directory))
        guard !FileManager.default.fileExists(atPath: URL(fileURLWithPath: gitDirectory).appendingPathComponent("index.lock").path) else {
            throw failure("The Git index is locked. Wait for other Git operations to finish. If the lock remains, check for an interrupted Git process.")
        }
        guard let branch = try await session.run(GitCurrentBranch(directory: directory)) else {
            throw failure("Switch to a local branch before squashing commits.")
        }
        guard
            try await session.run(Git(directory: directory, args: ["rev-parse", "--is-shallow-repository"])) == "false"
        else {
            throw failure("The repository history is incomplete. Fetch the complete history before squashing.")
        }
        guard try await GitPendingOperation.detect(using: session) == nil else {
            throw failure("Finish the current Git operation before squashing commits.")
        }
        let status = try await session.run(GitWorkingTreeStatusQuery(directory: directory, untracked: .all))
        guard status.changes.isClean else { throw failure("Commit or stash all changes before squashing commits.") }
        // %P still lists every parent under --first-parent, so merge commits are still detected.
        let commits = try await session.run(GitLog(directory: directory, firstParent: true, revisionRange: ["HEAD"]))
        if let error = selectionError(hashes, commits: commits, head: status.head) { throw failure(error) }
        let chain = commits.firstParentChain(from: status.head)
        let selected = chain.filter { hashes.contains($0.hash) }
        let last = chain.firstIndex(where: { $0.hash == selected.last!.hash })!
        try await checkPublication(using: session, oldest: chain[last].hash)
        let plan = SquashPlan(
            head: status.head!, branch: branch, commits: selected.reversed(),
            followingCount: chain.firstIndex(where: { hashes.contains($0.hash) })!,
            message: selected.reversed().map(\.title).joined(separator: " | "))
        return (plan, chain)
    }

    /// The affected commits form one first-parent chain, so the history is published exactly when its oldest commit is.
    private static func checkPublication(using session: GitRuntime.Session, oldest: String) async throws {
        let directory = session.directory
        let remotes = try await session.run(Git(directory: directory, args: ["remote"]))
        guard !remotes.isEmpty else { return }
        let namespace = "refs/foldgit/squash-check/" + UUID().uuidString.lowercased()
        do {
            var targets = Set<String>()
            for remote in remotes.split(separator: "\n").map(String.init) {
                for mode in [
                    ["remote", "get-url", "--all", remote], ["remote", "get-url", "--push", "--all", remote],
                ] {
                    let urls = try await session.run(Git(directory: directory, args: mode))
                    targets.formUnion(urls.split(separator: "\n").map(String.init))
                }
            }
            for (index, target) in targets.sorted().enumerated() {
                _ = try await session.run(
                    Git(
                        directory: directory,
                        args: [
                            "fetch", "--no-tags", "--no-write-fetch-head", "--", target,
                            "+refs/heads/*:\(namespace)/\(index)/heads/*", "+refs/tags/*:\(namespace)/\(index)/tags/*",
                        ], environment: ["GIT_TERMINAL_PROMPT": "0"]))
            }
            let published = try await session.run(
                Git(
                    directory: directory,
                    args: ["for-each-ref", "--count=1", "--format=%(refname)", "--contains", oldest, namespace]))
            guard published.isEmpty else {
                throw failure("The affected history includes commits that have already been pushed.")
            }
            try await removeRefs(namespace, using: session)
        } catch {
            try? await removeRefs(namespace, using: session)
            throw error
        }
    }

    private static func removeRefs(_ namespace: String, using session: GitRuntime.Session) async throws {
        let refs = try await session.run(
            Git(directory: session.directory, args: ["for-each-ref", "--format=%(refname)", namespace]))
        guard !refs.isEmpty else { return }
        // One transaction instead of one process per fetched ref.
        _ = try await session.run(
            Git(
                directory: session.directory, args: ["update-ref", "--stdin"],
                inputs: refs.split(separator: "\n").map { "delete " + $0 }))
    }

    private static func recoveryURL(using session: GitRuntime.Session) async throws -> URL {
        let path = try await session.run(GitAbsoluteGitDirectory(directory: session.directory))
        return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("foldgit-squash.json")
    }

    public static func recover(in directory: URL) async throws {
        try await GitRuntime.read(at: directory) { try await recover(using: $0) }
    }

    private static func recover(using session: GitRuntime.Session) async throws {
        let url = try await recoveryURL(using: session)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let record = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: url))
        let gitDirectory = url.deletingLastPathComponent()
        if try await GitPendingOperation.detect(using: session) == .rebase {
            let rebase = gitDirectory.appendingPathComponent("rebase-merge")
            guard
                let original = try? String(contentsOf: rebase.appendingPathComponent("orig-head"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                let branch = try? String(contentsOf: rebase.appendingPathComponent("head-name"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                throw failure(
                    "Squash recovery needs attention. The original history is saved under refs/foldgit/squash-backups.")
            }
            guard original == record.head, branch == "refs/heads/" + record.branch else {
                throw failure("The repository changed. Review its Git operation before recovering the squash.")
            }
            _ = try await session.run(Git(directory: session.directory, args: ["rebase", "--abort"]))
        }
        let head = try await session.run(Git(directory: session.directory, args: ["rev-parse", "HEAD"]))
        let tree = try await session.run(Git(directory: session.directory, args: ["rev-parse", "HEAD^{tree}"]))
        guard head == record.head || tree == record.tree else {
            throw failure(
                "Squash recovery needs attention. The original history is saved under refs/foldgit/squash-backups.")
        }
        try FileManager.default.removeItem(at: url)
    }

    public static func execute(_ plan: SquashPlan, message: String, in directory: URL) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("A commit message is required.")
        }
        return try await GitRuntime.read(at: directory) { session in
            let (current, chain) = try await prepare(using: session, hashes: Set(plan.commits.map(\.hash)))
            guard current.head == plan.head, current.branch == plan.branch else {
                throw failure("The repository changed. Select the commits again.")
            }
            let tree = try await session.run(Git(directory: directory, args: ["rev-parse", "HEAD^{tree}"]))
            let backup = "refs/foldgit/squash-backups/" + UUID().uuidString.lowercased()
            _ = try await session.run(Git(directory: directory, args: ["update-ref", backup, plan.head]))
            let journal = try await recoveryURL(using: session)
            try JSONEncoder().encode(Recovery(head: plan.head, branch: plan.branch, tree: tree, backup: backup)).write(
                to: journal, options: .atomic)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
                "FoldGit-Squash-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let selected = Set(plan.commits.map(\.hash))
            let oldest = chain.firstIndex(where: { $0.hash == plan.commits.first!.hash })!
            let todo =
                chain[...oldest].reversed().map { commit in
                    (selected.contains(commit.hash) && commit.hash != plan.commits.first!.hash ? "squash " : "pick ")
                        + commit.hash
                }.joined(separator: "\n") + "\n"
            try todo.write(to: temporary.appendingPathComponent("todo"), atomically: true, encoding: .utf8)
            try message.write(to: temporary.appendingPathComponent("message"), atomically: true, encoding: .utf8)
            let helper = temporary.appendingPathComponent("editor.sh")
            try "cp -- \"$FOLDGIT_SQUASH_FILES/$1\" \"$2\"\n".write(to: helper, atomically: true, encoding: .utf8)
            let quoted = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let environment = [
                "GIT_SEQUENCE_EDITOR": "sh " + quoted + " todo", "GIT_EDITOR": "sh " + quoted + " message",
                "FOLDGIT_SQUASH_FILES": temporary.path,
            ]
            let base = plan.commits.first!.parentHashes.first
            let args =
                [
                    "-c", "rebase.abbreviateCommands=false", "-c", "rebase.instructionFormat=%s", "rebase", "-i",
                    "--no-autosquash", "--no-autostash", "--no-update-refs", "--no-rebase-merges", "--keep-empty",
                    "--empty=keep", "--reapply-cherry-picks",
                ]
                + (base.map { [$0] } ?? ["--root"])
            do {
                // Check again after file preparation, before Git starts changing history.
                guard try await session.run(Git(directory: directory, args: ["rev-parse", "HEAD"])) == plan.head,
                    try await session.run(GitCurrentBranch(directory: directory)) == plan.branch,
                    try await session.run(GitWorkingTreeStatusQuery(directory: directory, untracked: .all)).changes
                        .isClean
                else {
                    throw failure("The repository changed. Select the commits again.")
                }
                _ = try await session.run(Git(directory: directory, args: args, environment: environment))
                guard try await session.run(Git(directory: directory, args: ["rev-parse", "HEAD^{tree}"])) == tree
                else {
                    // Restore the original history so recovery finds HEAD unchanged and clears the journal.
                    _ = try? await session.run(Git(directory: directory, args: ["reset", "--keep", backup]))
                    throw failure(
                        "Squash verification failed. The original history is saved under refs/foldgit/squash-backups.")
                }
                try FileManager.default.removeItem(at: journal)
                _ = try? await session.run(Git(directory: directory, args: ["update-ref", "-d", backup]))
                return try await session.run(
                    Git(directory: directory, args: ["rev-parse", "HEAD~\(plan.followingCount)"]))
            } catch {
                let recovery = Task.detached { try await recover(using: session) }
                _ = try? await recovery.value
                throw error
            }
        }
    }
}
