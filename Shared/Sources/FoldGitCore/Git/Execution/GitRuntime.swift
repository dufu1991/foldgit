import Foundation
internal import Subprocess

public struct GitExecutionError: Error, LocalizedError, Sendable {
    public let description: String
    public var errorDescription: String? { description }

    public init(description: String) { self.description = description }
    public init(error: any Error) { description = error.localizedDescription }
}

public struct CommandOutput: Sendable {
    public init(standardOutput: String, standardError: String) {
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public let standardOutput: String
    public let standardError: String
}

private struct BinaryCommandOutput: Sendable {
    let standardOutput: Data
    let standardError: String

    func textOutput() throws -> CommandOutput {
        guard let text = String(data: standardOutput, encoding: .utf8) else {
            throw GitExecutionError(description: NSLocalizedString("Git returned invalid UTF-8 output.", comment: ""))
        }
        return CommandOutput(standardOutput: text, standardError: standardError)
    }
}

/// Each repository gets a read/write queue. Read-only commands run together; any other command waits for
/// exclusive access, so app writes never interleave with a snapshot. Unrelated repositories run concurrently.
private actor RepositoryCommandQueue {
    static let shared = RepositoryCommandQueue()

    private struct Waiter {
        let id: UUID
        let isReadOnly: Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Lane {
        var readers = 0
        var writing = false
        var waiting: [Waiter] = []
        var isIdle: Bool { readers == 0 && !writing && waiting.isEmpty }
    }

    private var lanes: [String: Lane] = [:]

    func execute<Value: Sendable>(at directory: URL?, readOnly: Bool,
                                  operation: @Sendable () async throws -> Value) async throws -> Value {
        let key = directory.map(RepositoryLocation.key) ?? "global"
        try await acquire(key, readOnly: readOnly)
        defer { release(key, readOnly: readOnly) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(_ key: String, readOnly: Bool) async throws {
        var lane = lanes[key, default: Lane()]
        // Waiters keep their order, so a queued write is not starved by later reads.
        if lane.waiting.isEmpty && !lane.writing && (readOnly || lane.readers == 0) {
            if readOnly { lane.readers += 1 } else { lane.writing = true }
            lanes[key] = lane
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation(isolation: self) { (continuation: CheckedContinuation<Void, any Error>) in
                enqueue(Waiter(id: id, isReadOnly: readOnly, continuation: continuation), key: key)
            }
        } onCancel: {
            Task { await self.cancel(id, key: key) }
        }
    }

    private func enqueue(_ waiter: Waiter, key: String) {
        guard !Task.isCancelled else { return waiter.continuation.resume(throwing: CancellationError()) }
        lanes[key, default: Lane()].waiting.append(waiter)
    }

    private func release(_ key: String, readOnly: Bool) {
        guard var lane = lanes[key] else { return }
        if readOnly { lane.readers -= 1 } else { lane.writing = false }
        grant(&lane)
        lanes[key] = lane.isIdle ? nil : lane
    }

    private func cancel(_ id: UUID, key: String) {
        guard var lane = lanes[key], let index = lane.waiting.firstIndex(where: { $0.id == id }) else { return }
        lane.waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        grant(&lane)
        lanes[key] = lane.isIdle ? nil : lane
    }

    private func grant(_ lane: inout Lane) {
        while let next = lane.waiting.first, !lane.writing, next.isReadOnly || lane.readers == 0 {
            lane.waiting.removeFirst()
            if next.isReadOnly { lane.readers += 1 } else { lane.writing = true }
            next.continuation.resume()
        }
    }
}

public enum GitRuntime: Sendable {
    public static let outputLimit = 64 * 1024 * 1024

    public struct Session: Sendable {
        public let directory: URL

        public func run<Command: RepositoryCommand>(_ command: Command) async throws -> Command.OutputModel {
            precondition(command.directory == directory)
            let output = try await GitRuntime.collect(arguments: command.arguments, directory: directory, inputs: [], environment: command.environment, timeout: .seconds(180))
            return try command.parse(for: output.textOutput().standardOutput)
        }
    }

    /// Runs several commands in one queue slot. Pass `readOnly` only when every command in it reads.
    public static func read<Value: Sendable>(at directory: URL, readOnly: Bool = false,
                                             operation: @Sendable (Session) async throws -> Value) async throws -> Value {
        try await RepositoryCommandQueue.shared.execute(at: directory, readOnly: readOnly) {
            try await operation(Session(directory: directory))
        }
    }

    public static func run<Command: RepositoryCommand>(_ command: Command) async throws -> Command.OutputModel {
        let output = try await run(arguments: command.arguments, currentDirectoryURL: command.directory,
                                   environment: command.environment, readOnly: command.isReadOnly)
        return try command.parse(for: output.standardOutput)
    }

    public static func run<Command: InteractiveRepositoryCommand>(_ command: Command) async throws -> Command.OutputModel {
        let output = try await run(arguments: command.arguments, currentDirectoryURL: command.directory, inputs: command.inputs,
                                   environment: command.environment, readOnly: command.isReadOnly)
        return try command.parse(for: output.standardOutput)
    }

    public static func run(arguments: [String], currentDirectoryURL: URL?, inputs: [String] = [], environment: [String: String] = [:],
                           readOnly: Bool = false, timeout: Duration = .seconds(180)) async throws -> CommandOutput {
        try await RepositoryCommandQueue.shared.execute(at: currentDirectoryURL, readOnly: readOnly) {
            try await collect(arguments: arguments, directory: currentDirectoryURL, inputs: inputs, environment: environment, timeout: timeout).textOutput()
        }
    }

    /// Collect bytes without a UTF-8 conversion, preserving image and other blob contents.
    public static func runData(arguments: [String], currentDirectoryURL: URL?, timeout: Duration = .seconds(180)) async throws -> Data {
        try await RepositoryCommandQueue.shared.execute(at: currentDirectoryURL, readOnly: true) {
            try await collect(arguments: arguments, directory: currentDirectoryURL, inputs: [], environment: [:], timeout: timeout).standardOutput
        }
    }

    private static func collect(arguments: [String], directory: URL?, inputs: [String], environment: [String: String], timeout: Duration) async throws -> BinaryCommandOutput {
        try await withThrowingTaskGroup(of: BinaryCommandOutput.self) { group in
            group.addTask { try await launch(arguments: arguments, directory: directory, inputs: inputs, environment: environment) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw GitExecutionError(description: NSLocalizedString("The Git operation timed out.", comment: ""))
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func launch(arguments: [String], directory: URL?, inputs: [String], environment overrides: [String: String]) async throws -> BinaryCommandOutput {
        try Task.checkCancellation()
        guard let executable = arguments.first else {
            throw GitExecutionError(description: NSLocalizedString("The Git command is empty.", comment: ""))
        }
        // Keep machine output stable and preserve readable Unicode paths in patch headers.
        let base: Subprocess.Environment = .inherit.updating([
            "LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8", "GIT_PAGER": "cat",
        ])
        let environment = base.updating(Dictionary(uniqueKeysWithValues: overrides.map {
            (Subprocess.Environment.Key(stringLiteral: $0.key), Optional($0.value))
        }))
        let commandArguments = executable == "git"
            ? ["-c", "core.quotepath=false", "-c", "color.ui=false"] + arguments.dropFirst()
            : Array(arguments.dropFirst())
        let result = try await Subprocess.run(
            (executable.contains("/") || executable.contains("\\")) ? .path(.init(executable)) : .name(executable),
            arguments: .init(commandArguments), environment: environment,
            workingDirectory: directory.map { .init($0.path) },
            input: .string(inputs.isEmpty ? "" : inputs.joined(separator: "\n") + "\n"),
            output: .bytes(limit: outputLimit), error: .bytes(limit: 4 * 1024 * 1024)
        )
        try Task.checkCancellation()
        guard let stderr = String(bytes: result.standardError, encoding: .utf8) else {
            throw GitExecutionError(description: NSLocalizedString("Git returned invalid UTF-8 output.", comment: ""))
        }
        guard result.terminationStatus.isSuccess else {
            throw GitExecutionError(description:
                String(format: NSLocalizedString("An error occurred while executing %@", comment: "Git command failure"), arguments.joined(separator: " "))
                + "\n\n" + String(decoding: result.standardOutput, as: UTF8.self) + "\n" + stderr)
        }
        return BinaryCommandOutput(standardOutput: Data(result.standardOutput), standardError: stderr)
    }
}
