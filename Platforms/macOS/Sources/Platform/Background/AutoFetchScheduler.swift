import FoldGitCore
import Foundation
import Observation

struct AutoFetchEvent: Sendable {
    let directory: URL
    let error: String?
}

@MainActor
@Observable final class AutoFetchScheduler {
    static let shared = AutoFetchScheduler()

    private(set) var intervals: [String: AutoFetchInterval] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var lastSuccess: [String: Date] = [:]
    private(set) var fetching: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let fetch: @Sendable (URL, Date) async throws -> Date
    @ObservationIgnored private var jobs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var scheduledIntervals: [String: AutoFetchInterval] = [:]
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var scheduledSettings: ScheduledSettings?

    init(defaults: UserDefaults = .standard,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         fetch: @escaping @Sendable (URL, Date) async throws -> Date = { directory, since in
             try await RemoteUpdateService.shared.executeScheduled(GitFetch(directory: directory, isBackground: true), since: since)
         }) {
        self.defaults = defaults
        self.sleep = sleep
        self.fetch = fetch
        intervals = Self.readIntervals(defaults)
    }

    nonisolated static func key(for directory: URL) -> String {
        RepositoryLocation.key(for: directory)
    }

    func interval(for folder: WorkspaceEntry) -> AutoFetchInterval {
        intervals[Self.key(for: folder.url)] ?? .off
    }

    func setInterval(_ interval: AutoFetchInterval, for folder: WorkspaceEntry) {
        let key = Self.key(for: folder.url)
        var saved = Self.readIntervals(defaults)
        saved[key] = interval == .off ? nil : interval
        defaults.set(saved.mapValues(\.rawValue), forKey: PreferenceKey.projectAutoFetch.rawValue)
        reload()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
        reload()
    }

    func stop() {
        isRunning = false
        scheduledSettings = nil
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        scheduledIntervals.removeAll()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = nil
    }

    func reload() {
        let updated = Self.readIntervals(defaults)
        if intervals != updated { intervals = updated }
        guard isRunning else { return }
        // Any preference change posts a notification; most of them leave the schedule unchanged.
        let settings = ScheduledSettings(folders: defaults.data(forKey: PreferenceKey.folder.rawValue), intervals: updated)
        guard settings != scheduledSettings else { return }
        scheduledSettings = settings
        let folders = settings.folders.flatMap { try? JSONDecoder().decode([WorkspaceEntry].self, from: $0) } ?? []
        var desired: [String: (WorkspaceEntry, AutoFetchInterval)] = [:]
        for folder in folders.flatMap(\.repositories) {
            let interval = interval(for: folder)
            if interval != .off { desired[Self.key(for: folder.url)] = (folder, interval) }
        }
        for key in Array(jobs.keys) where desired[key]?.1 != scheduledIntervals[key] {
            jobs.removeValue(forKey: key)?.cancel()
            scheduledIntervals.removeValue(forKey: key)
        }
        for (key, (folder, interval)) in desired where jobs[key] == nil {
            scheduledIntervals[key] = interval
            let sleep = sleep
            jobs[key] = Task { [weak self] in
                while !Task.isCancelled {
                    let since = Date()
                    do {
                        try await sleep(interval.duration)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, let self else { return }
                    await self.fetchProject(folder, key: key, interval: interval, since: since)
                }
            }
        }
    }

    private func fetchProject(_ folder: WorkspaceEntry, key: String, interval: AutoFetchInterval, since: Date) async {
        guard isRunning, scheduledIntervals[key] == interval, !fetching.contains(key) else { return }
        fetching.insert(key)
        defer { fetching.remove(key) }
        do {
            let date = try await fetch(folder.url, since)
            guard !Task.isCancelled else { return }
            lastSuccess[key] = date
            errors.removeValue(forKey: key)
            NotificationCenter.default.post(name: .projectAutoFetchDidFinish, object: AutoFetchEvent(directory: folder.url, error: nil))
        } catch {
            guard !Task.isCancelled else { return }
            errors[key] = error.localizedDescription
            NotificationCenter.default.post(name: .projectAutoFetchDidFinish,
                                            object: AutoFetchEvent(directory: folder.url, error: error.localizedDescription))
        }
    }

    private static func readIntervals(_ defaults: UserDefaults) -> [String: AutoFetchInterval] {
        let saved = defaults.dictionary(forKey: PreferenceKey.projectAutoFetch.rawValue) as? [String: Int] ?? [:]
        return saved.compactMapValues { AutoFetchInterval(rawValue: $0) }
    }
}

private struct ScheduledSettings: Equatable {
    let folders: Data?
    let intervals: [String: AutoFetchInterval]
}
