import FoldGitCore
import Foundation
import XCTest
@testable import FoldGit

private actor AutoFetchClock {
    private var waiters: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    var durations: [Duration] { waiters.values.map(\.0) }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = (duration, continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance() {
        let current = waiters.values.map(\.1)
        waiters.removeAll()
        for continuation in current { continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
    }
}

private actor AutoFetchRecorder {
    enum Failure: Error { case offline }
    private(set) var calls: [URL] = []
    var fails = false
    var holds = false
    private var continuation: CheckedContinuation<Void, Never>?

    func setFails(_ value: Bool) { fails = value }
    func setHolds(_ value: Bool) { holds = value }
    func release() {
        continuation?.resume()
        continuation = nil
        holds = false
    }

    func fetch(_ directory: URL, since: Date) async throws -> Date {
        calls.append(directory)
        if holds {
            await withCheckedContinuation { continuation = $0 }
        }
        if fails { throw Failure.offline }
        return Date()
    }
}

@MainActor
final class ProjectAutoFetchTests: XCTestCase {
    @MainActor private struct Harness {
        let name: String
        let defaults: UserDefaults
        let manager: AutoFetchScheduler
        let clock: AutoFetchClock
        let recorder: AutoFetchRecorder

        func close() {
            manager.stop()
            defaults.removePersistentDomain(forName: name)
        }
    }

    private let first = WorkspaceEntry(url: URL(fileURLWithPath: "/tmp/changes-project-a"))
    private let second = WorkspaceEntry(url: URL(fileURLWithPath: "/tmp/changes-project-b"))
    private let third = WorkspaceEntry(url: URL(fileURLWithPath: "/tmp/changes-project-c"))

    private func harness(_ folders: [WorkspaceEntry]) throws -> Harness {
        let name = "ProjectAutoFetchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(try JSONEncoder().encode(folders), forKey: PreferenceKey.folder.rawValue)
        let clock = AutoFetchClock()
        let recorder = AutoFetchRecorder()
        let manager = AutoFetchScheduler(defaults: defaults, sleep: { try await clock.sleep($0) },
                                       fetch: { try await recorder.fetch($0, since: $1) })
        return Harness(name: name, defaults: defaults, manager: manager, clock: clock, recorder: recorder)
    }

    private func eventually(_ condition: @MainActor () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    func testRequestedIntervalsAndTwentyFourHourDuration() {
        XCTAssertEqual(AutoFetchInterval.allCases.map(\.rawValue), [0, 5, 10, 30, 60, 1440])
        XCTAssertEqual(AutoFetchInterval.twentyFourHours.duration, .seconds(86_400))
    }

    func testPreferencesAreIndependentAndRestored() throws {
        let harness = try harness([first, second])
        defer { harness.close() }
        XCTAssertEqual(harness.manager.interval(for: first), .off)
        harness.manager.setInterval(.fiveMinutes, for: first)
        harness.manager.setInterval(.twentyFourHours, for: second)
        let restored = AutoFetchScheduler(defaults: harness.defaults)
        XCTAssertEqual(restored.interval(for: first), .fiveMinutes)
        XCTAssertEqual(restored.interval(for: second), .twentyFourHours)
        harness.manager.setInterval(.off, for: first)
        XCTAssertEqual(harness.manager.interval(for: first), .off)
        XCTAssertEqual(harness.manager.interval(for: second), .twentyFourHours)
    }

    func testAllEnabledProjectsRunWithoutAnySelectedProject() async throws {
        let harness = try harness([first, second, third])
        defer { harness.close() }
        harness.manager.setInterval(.fiveMinutes, for: first)
        harness.manager.setInterval(.twentyFourHours, for: second)
        harness.manager.start()
        harness.manager.start()
        try await eventually { await harness.clock.durations.count == 2 }
        let durations = await harness.clock.durations
        XCTAssertEqual(Set(durations), Set([.seconds(300), .seconds(86_400)]))
        await harness.clock.advance()
        try await eventually { await harness.recorder.calls.count == 2 }
        let fetched = await harness.recorder.calls
        XCTAssertEqual(Set(fetched), Set([first.url, second.url]))
        try await eventually { await harness.clock.durations.count == 2 }
    }

    func testChangingIntervalsAndTurningOffCancelsTimers() async throws {
        let harness = try harness([first, second])
        defer { harness.close() }
        harness.manager.setInterval(.fiveMinutes, for: first)
        harness.manager.setInterval(.tenMinutes, for: second)
        harness.manager.start()
        try await eventually { await harness.clock.durations.count == 2 }
        harness.manager.setInterval(.thirtyMinutes, for: first)
        try await eventually { Set(await harness.clock.durations) == Set([.seconds(600), .seconds(1800)]) }
        harness.manager.setInterval(.off, for: first)
        harness.manager.setInterval(.off, for: second)
        try await eventually { await harness.clock.durations.isEmpty }
        await harness.clock.advance()
        let calls = await harness.recorder.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testRemovingProjectStopsItsTimer() async throws {
        let harness = try harness([first])
        defer { harness.close() }
        harness.manager.setInterval(.fiveMinutes, for: first)
        harness.manager.start()
        try await eventually { await harness.clock.durations.count == 1 }
        harness.defaults.set(try JSONEncoder().encode([WorkspaceEntry]()), forKey: PreferenceKey.folder.rawValue)
        harness.manager.reload()
        try await eventually { await harness.clock.durations.isEmpty }
        await harness.clock.advance()
        let calls = await harness.recorder.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testGroupedRepositoriesAreScheduledIndividuallyAndStopWhenGroupIsRemoved() async throws {
        var group = WorkspaceEntry(url: URL(fileURLWithPath: "/tmp/changes-group"), children: [first, second])
        group.setInfrequent(true, repository: second)
        let harness = try harness([group, third])
        defer { harness.close() }
        harness.manager.setInterval(.fiveMinutes, for: first)
        harness.manager.setInterval(.tenMinutes, for: second)
        harness.manager.setInterval(.thirtyMinutes, for: third)
        harness.manager.start()
        try await eventually { await harness.clock.durations.count == 3 }
        await harness.clock.advance()
        try await eventually { await harness.recorder.calls.count == 3 }
        let calls = await harness.recorder.calls
        XCTAssertEqual(Set(calls), Set([first.url, second.url, third.url]))
        XCTAssertFalse(calls.contains(group.url))
        try await eventually { await harness.clock.durations.count == 3 }
        harness.defaults.set(try JSONEncoder().encode([third]), forKey: PreferenceKey.folder.rawValue)
        harness.manager.reload()
        try await eventually { await harness.clock.durations == [.seconds(1800)] }
    }

    func testFailureIsRecordedAndNextIntervalRetries() async throws {
        let harness = try harness([first])
        defer { harness.close() }
        let key = AutoFetchScheduler.key(for: first.url)
        harness.manager.setInterval(.fiveMinutes, for: first)
        await harness.recorder.setFails(true)
        harness.manager.start()
        try await eventually { await harness.clock.durations.count == 1 }
        await harness.clock.advance()
        try await eventually { harness.manager.errors[key] != nil }
        try await eventually { await harness.clock.durations.count == 1 }
        await harness.recorder.setFails(false)
        await harness.clock.advance()
        try await eventually { harness.manager.lastSuccess[key] != nil }
        XCTAssertNil(harness.manager.errors[key])
        let calls = await harness.recorder.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testReconfigurationDoesNotOverlapAnInFlightFetch() async throws {
        let harness = try harness([first])
        defer { harness.close() }
        await harness.recorder.setHolds(true)
        harness.manager.setInterval(.fiveMinutes, for: first)
        harness.manager.start()
        try await eventually { await harness.clock.durations.count == 1 }
        await harness.clock.advance()
        try await eventually { await harness.recorder.calls.count == 1 }
        harness.manager.setInterval(.tenMinutes, for: first)
        try await eventually { await harness.clock.durations == [.seconds(600)] }
        await harness.clock.advance()
        try await eventually { await harness.clock.durations.count == 1 }
        let calls = await harness.recorder.calls
        XCTAssertEqual(calls.count, 1)
        await harness.recorder.release()
        try await eventually { harness.manager.fetching.isEmpty }
        await harness.clock.advance()
        try await eventually { await harness.recorder.calls.count == 2 }
    }

    func testBackgroundCommandDisablesInteractiveCredentialPrompts() {
        let command = GitFetch(directory: first.url, isBackground: true)
        XCTAssertEqual(command.environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(command.environment["GCM_INTERACTIVE"], "Never")
        XCTAssertEqual(GitFetch(directory: first.url).arguments, ["git", "fetch"])
    }

    func testRecentManualFetchSatisfiesScheduledFetch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("auto-fetch-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = directory.appendingPathComponent("remote.git")
        let local = directory.appendingPathComponent("local")
        _ = try await GitRuntime.run(arguments: ["git", "init", "--bare", remote.path], currentDirectoryURL: directory)
        _ = try await GitRuntime.run(arguments: ["git", "init", local.path], currentDirectoryURL: directory)
        _ = try await GitRuntime.run(arguments: ["git", "remote", "add", "origin", remote.path], currentDirectoryURL: local)
        let executor = RemoteUpdateService()
        let since = Date()
        try await executor.execute(GitFetch(directory: local))
        try FileManager.default.removeItem(at: remote)
        let date = try await executor.executeScheduled(GitFetch(directory: local, isBackground: true), since: since)
        XCTAssertGreaterThanOrEqual(date, since)
        do {
            _ = try await executor.executeScheduled(GitFetch(directory: local, isBackground: true), since: .distantFuture)
            XCTFail("A new interval must attempt the fetch")
        } catch {
            XCTAssertTrue(error is GitExecutionError)
        }
    }
}
