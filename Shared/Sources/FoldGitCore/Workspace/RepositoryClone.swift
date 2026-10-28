import Foundation
internal import Subprocess

public struct RepositoryCloneRequest: Sendable {
    public let parent: URL
    public let remote: String
    public let directoryName: String

    public init(parent: URL, remote: String, directoryName: String) {
        self.parent = parent.standardizedFileURL.resolvingSymlinksInPath()
        self.remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        self.directoryName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var destination: URL { parent.appendingPathComponent(directoryName, isDirectory: true) }

    public static func suggestedName(for remote: String) -> String {
        let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = URLComponents(string: remote).flatMap { $0.scheme == nil ? nil : $0.path } ?? remote
        var name = path.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.removingPercentEncoding ?? name
    }

    public func validate() throws {
        guard !remote.isEmpty, !remote.hasPrefix("-"), !remote.contains("::"),
              !remote.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GitExecutionError(description: NSLocalizedString("Enter a valid repository address.", comment: ""))
        }
        let scheme = URLComponents(string: remote)?.scheme?.lowercased()
        let isURL = ["https", "http", "ssh", "git", "file"].contains(scheme ?? "")
        let isSCP = remote.range(of: #"^[^\s/:]+@[^\s/:]+:.+$"#, options: .regularExpression) != nil
        #if os(Windows)
        let isLocalPath = remote.hasPrefix("/") || remote.hasPrefix("\\\\") ||
            remote.range(of: #"^[A-Za-z]:[/\\]"#, options: .regularExpression) != nil
        #else
        let isLocalPath = remote.hasPrefix("/")
        #endif
        guard isURL || isSCP || isLocalPath else {
            throw GitExecutionError(description: NSLocalizedString("Enter a valid repository address.", comment: ""))
        }
        guard !directoryName.isEmpty, directoryName != ".", directoryName != "..",
              !directoryName.contains("/"), !directoryName.contains("\\"),
              !directoryName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GitExecutionError(description: NSLocalizedString("Enter a valid folder name.", comment: ""))
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw GitExecutionError(description: NSLocalizedString("The destination folder already exists. Choose another folder name.", comment: ""))
        }
    }
}

public enum RepositoryClone {
    /// A private staging folder keeps retries and cancellation away from existing user folders.
    public static func run(_ request: RepositoryCloneRequest,
                           onProgress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        try request.validate()
        let staging = request.parent.appendingPathComponent(".FoldGit-clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let result = try await Subprocess.run(
            .name("git"), arguments: ["clone", "--progress", "--", request.remote, staging.path],
            environment: .inherit.updating([
                "LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8", "GIT_TERMINAL_PROMPT": "0",
            ]), workingDirectory: .init(request.parent.path),
            input: .none, output: .discarded, error: .sequence
        ) { execution in
            var recentLines: [String] = []
            for try await line in execution.standardError.strings() {
                try Task.checkCancellation()
                let line = line.replacingOccurrences(of: staging.path, with: request.destination.path)
                recentLines.append(line)
                if recentLines.count > 40 { recentLines.removeFirst() }
                await onProgress(line)
            }
            return recentLines.joined(separator: "\n")
        }
        try Task.checkCancellation()
        guard result.terminationStatus.isSuccess else {
            throw GitExecutionError(description: result.closureResult)
        }
        // FileManager refuses to replace a destination created while the clone was running.
        try FileManager.default.moveItem(at: staging, to: request.destination)
        return request.destination
    }
}
