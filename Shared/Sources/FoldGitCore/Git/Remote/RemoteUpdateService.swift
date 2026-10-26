import Foundation

public actor RemoteUpdateService {
    public init() {}

    public static let shared = RemoteUpdateService()
    private struct FetchKey: Hashable {
        let repository: String
        let tags: Bool
    }
    private var successfulFetches: [String: Date] = [:]
    private var inFlight: [FetchKey: (UUID, Task<Date, Error>)] = [:]

    public func execute(_ command: GitFetch) async throws { _ = try await fetch(command) }

    public func executeScheduled(_ command: GitFetch, since: Date) async throws -> Date {
        let key = RepositoryLocation.key(for: command.directory)
        if let last = successfulFetches[key], last >= since { return last }
        return try await fetch(command)
    }

    private func fetch(_ command: GitFetch) async throws -> Date {
        let repository = RepositoryLocation.key(for: command.directory)
        let key = FetchKey(repository: repository, tags: command.tags)
        if let task = inFlight[key]?.1 { return try await task.value }
        let token = UUID()
        // The service owns shared fetches; canceling an observer does not cancel other observers.
        let task = Task {
            try await GitRuntime.run(command)
            return Date()
        }
        inFlight[key] = (token, task)
        defer { if inFlight[key]?.0 == token { inFlight[key] = nil } }
        let date = try await task.value
        successfulFetches[repository] = date
        return date
    }

    public func execute(_ command: GitPull) async throws {
        try await GitRuntime.run(command)
        successfulFetches[RepositoryLocation.key(for: command.directory)] = Date()
    }
}
