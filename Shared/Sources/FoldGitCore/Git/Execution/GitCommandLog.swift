import Foundation

public struct GitCommandLogEntry: Identifiable, Sendable, Equatable {
    public enum Status: Sendable {
        case running, succeeded, failed, cancelled, timedOut
    }

    public struct Output: Sendable, Equatable {
        public let text: String
        public let byteCount: Int
        public let isBinary: Bool
        public let isTruncated: Bool
    }

    public let id: UUID
    public let directory: URL
    public let command: String
    public let startedAt: Date
    public let isReadOnly: Bool
    public var status: Status = .running
    public var duration: TimeInterval?
    public var exitCode: Int?
    public var standardOutput: Output?
    public var standardError: Output?
    public var failure: String?

    public var isFailure: Bool { status == .failed || status == .timedOut }

    fileprivate var retainedBytes: Int {
        command.utf8.count + (standardOutput?.text.utf8.count ?? 0)
            + (standardError?.text.utf8.count ?? 0) + (failure?.utf8.count ?? 0)
    }
}

/// Session-only history. Repository identities and subscriptions never combine unrelated worktrees.
public actor GitCommandLog {
    public static let shared = GitCommandLog()

    private struct Observer {
        let directory: URL
        let continuation: AsyncStream<[GitCommandLogEntry]>.Continuation
    }

    private var entries: [GitCommandLogEntry] = []
    private var observers: [UUID: Observer] = [:]
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let outputLimit: Int

    public init(maximumEntries: Int = 500, maximumBytes: Int = 8 * 1_024 * 1_024, outputLimit: Int = 32 * 1_024) {
        precondition(maximumEntries > 0 && maximumBytes > 0 && outputLimit > 0)
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
        self.outputLimit = outputLimit
    }

    public func records(in directory: URL) -> [GitCommandLogEntry] {
        let identity = RepositoryLocation.canonical(directory)
        return entries.filter { $0.directory == identity }.reversed()
    }

    public func updates(in directory: URL) -> AsyncStream<[GitCommandLogEntry]> {
        let id = UUID()
        let identity = RepositoryLocation.canonical(directory)
        let (stream, continuation) = AsyncStream<[GitCommandLogEntry]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = Observer(directory: identity, continuation: continuation)
        continuation.yield(records(in: identity))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    public func clear(in directory: URL) {
        let identity = RepositoryLocation.canonical(directory)
        entries.removeAll { $0.directory == identity && $0.status != .running }
        publish()
    }

    func begin(arguments: [String], directory: URL?, readOnly: Bool) -> UUID? {
        guard let directory, let executable = arguments.first,
              ["git", "git.exe"].contains(URL(fileURLWithPath: executable).lastPathComponent) else { return nil }
        let id = UUID()
        let command = GitLogRedaction.command(arguments)
        let displayedCommand = command.utf8.count > 8 * 1_024 ? limited(command, to: 8 * 1_024) + " …" : command
        entries.append(GitCommandLogEntry(id: id, directory: RepositoryLocation.canonical(directory),
            command: displayedCommand, startedAt: Date(), isReadOnly: readOnly))
        trim()
        publish()
        return id
    }

    /// Summarizes off the actor so large outputs never stall the bookkeeping of concurrent commands.
    nonisolated func capture(_ id: UUID?, output: some Collection<UInt8> & Sendable, error: some Collection<UInt8> & Sendable,
                             exitCode: Int?, binaryOutput: Bool) async {
        guard let id else { return }
        let standardOutput = summarize(output, binary: binaryOutput)
        let standardError = summarize(error, binary: false)
        await record(id, output: standardOutput, error: standardError, exitCode: exitCode)
    }

    private func record(_ id: UUID, output: GitCommandLogEntry.Output, error: GitCommandLogEntry.Output, exitCode: Int?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].standardOutput = output
        entries[index].standardError = error
        entries[index].exitCode = exitCode
        trim()
    }

    func finish(_ id: UUID?, status: GitCommandLogEntry.Status, duration: TimeInterval, failure: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        entries[index].duration = duration
        entries[index].failure = failure.map { limited(GitLogRedaction.text($0), to: outputLimit) }
        trim()
        publish()
    }

    /// Only the retained prefix is copied and decoded; the rest of a large output is counted, never scanned.
    private nonisolated func summarize(_ data: some Collection<UInt8>, binary: Bool) -> GitCommandLogEntry.Output {
        // runData reads file blobs. Never retain their contents in a command history.
        if binary { return .init(text: "", byteCount: data.count, isBinary: true, isTruncated: false) }
        let prefix = Array(data.prefix(outputLimit))
        // A cut may split the last UTF-8 scalar. Drop only that incomplete scalar before deciding the output is binary.
        var end = prefix.count
        if data.count > prefix.count {
            var start = end
            while start > 0, end - start < 3, prefix[start - 1] & 0xC0 == 0x80 { start -= 1 }
            if start > 0 {
                let lead = prefix[start - 1]
                let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
                if end - (start - 1) < length { end = start - 1 }
            }
        }
        guard let decoded = String(bytes: prefix[..<end], encoding: .utf8) else {
            return .init(text: "", byteCount: data.count, isBinary: true, isTruncated: false)
        }
        let text = decoded.replacingOccurrences(of: "\0", with: "\\0")
        return .init(text: limited(GitLogRedaction.text(text), to: outputLimit), byteCount: data.count,
                     isBinary: false, isTruncated: data.count > end || text.utf8.count > outputLimit)
    }

    private nonisolated func limited(_ text: String, to count: Int) -> String {
        guard text.utf8.count > count else { return text }
        var bytes = Data(text.utf8.prefix(count))
        while !bytes.isEmpty && String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func trim() {
        var bytes = entries.reduce(0) { $0 + $1.retainedBytes }
        while entries.count > maximumEntries || bytes > maximumBytes {
            guard !entries.isEmpty else { break }
            let index = entries.firstIndex { $0.status != .running } ?? entries.startIndex
            bytes -= entries.remove(at: index).retainedBytes
        }
    }

    private func publish() {
        for observer in observers.values { observer.continuation.yield(records(in: observer.directory)) }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
}

enum GitLogRedaction {
    static func command(_ arguments: [String]) -> String {
        var redactNext = false
        return arguments.map { argument in
            let value: String
            if redactNext {
                value = "[REDACTED]"
                redactNext = false
            } else {
                value = text(argument)
                redactNext = ["--password", "--token", "--access-token"].contains(argument.lowercased())
            }
            return quote(value)
        }.joined(separator: " ")
    }

    static func text(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"(\b[a-zA-Z][a-zA-Z0-9+.-]*://)[^\s/@]+@"#, with: "$1[REDACTED]@", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)((?:authorization|proxy-authorization)\s*[:=]\s*)[^\r\n]+"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)((?:[?&]|--|\b)(?:access[_-]?token|password|token|private[_-]?token)=)[^\s&#]+"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)((?:http\.[^\s=]*extraheader|http\.extraheader)=).*"#, with: "$1[REDACTED]", options: .regularExpression)
    }

    private static func quote(_ value: String) -> String {
        guard !value.isEmpty, value.range(of: #"[^a-zA-Z0-9_./:=+@%-]"#, options: .regularExpression) == nil else {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }
}
