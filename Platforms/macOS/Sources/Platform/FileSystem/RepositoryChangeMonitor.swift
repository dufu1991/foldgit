import CoreServices
import FoldGitCore
import Foundation

/// Reports which repository roots had working-tree file events, so activity scans run only for changed repositories.
enum RepositoryChangeMonitor {
    /// Worktrees whose status must be read again, and worktrees whose family's worktree list may have changed
    /// because a HEAD moved or a worktree was added, removed or locked.
    struct StatusChange: Sendable, Equatable {
        var paths: Set<String> = []
        var listPaths: Set<String> = []
        var isEmpty: Bool { paths.isEmpty && listPaths.isEmpty }

        mutating func formUnion(_ other: Self) {
            paths.formUnion(other.paths)
            listPaths.formUnion(other.listPaths)
        }
    }

    struct StatusWatchPlan: Sendable {
        enum Kind: Sendable, Equatable { case files, metadata, sharedMetadata }
        struct Root: Sendable {
            let path: String
            let targets: Set<String>
            let kind: Kind
            var owner: String? = nil
        }
        let roots: [Root]
        let families: [String: Set<String>]

        /// Entries of a linked worktree's own Git directory that change its status.
        private static let markerNames: [String] = GitPendingOperation.markerNames
        private static let metadataNames = Set<String>(["", "HEAD", "index", "locked", "commondir"]).union(markerNames)
        /// Entries of the common Git directory. HEAD, index and operation markers belong to the main worktree only.
        private static let ownedNames = Set<String>(["HEAD", "index"]).union(markerNames)
        private static let sharedNames = ownedNames.union(["", "config", "refs", "packed-refs", "shallow", "worktrees"])
        /// A moved HEAD or a changed worktree set alters `git worktree list`; edits, staging and ref updates do not.
        private static let listNames: Set<String> = ["", "HEAD", "locked", "worktrees"]

        func affected(by paths: [String]) -> StatusChange {
            var change = StatusChange()
            for path in paths {
                guard let root = roots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else { continue }
                if path.hasSuffix(".lock") { continue }
                let relative = String(path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let name = relative.split(separator: "/").first.map(String.init) ?? ""
                var targets = root.targets
                switch root.kind {
                case .files:
                    guard !relative.split(separator: "/").contains(".git") else { continue }
                case .metadata:
                    guard Self.metadataNames.contains(name) else { continue }
                case .sharedMetadata:
                    guard Self.sharedNames.contains(name) else { continue }
                    if Self.ownedNames.contains(name), let owner = root.owner { targets = [owner] }
                }
                change.paths.formUnion(targets)
                if root.kind != .files && Self.listNames.contains(name) { change.listPaths.formUnion(targets) }
            }
            return change
        }
    }

    static func statusWatchPlan(for families: [[GitWorktree]]) async throws -> StatusWatchPlan {
        var roots: [StatusWatchPlan.Root] = []
        var memberships: [String: Set<String>] = [:]
        for trees in families {
            let usable = trees.filter { !$0.isBare && !$0.isPrunable && FileManager.default.fileExists(atPath: $0.url.path) }
            let targets = Set(usable.map(\.id.path))
            var commonDirectories = Set<String>()
            var owners: [String: String] = [:]
            for tree in usable {
                memberships[tree.id.path] = targets
                roots.append(.init(path: tree.id.path, targets: [tree.id.path], kind: .files))
                guard let directories = try? await GitRuntime.run(GitMetadataDirectories(directory: tree.url)) else { continue }
                if directories.git != directories.common {
                    roots.append(.init(path: directories.git, targets: [tree.id.path], kind: .metadata))
                }
                if directories.git == directories.common { owners[directories.common] = tree.id.path }
                commonDirectories.insert(directories.common)
            }
            for common in commonDirectories {
                roots.append(.init(path: common, targets: targets, kind: .sharedMetadata, owner: owners[common]))
            }
        }
        return StatusWatchPlan(roots: roots.sorted { $0.path.count > $1.path.count }, families: memberships)
    }

    /// File events and app mutations accumulate until the consumer takes them, so a slow refresh never queues
    /// a backlog: each tick hands over everything that changed since the previous one.
    final class StatusChangeFeed: Sendable {
        let ticks: AsyncStream<Void>
        fileprivate let receiver: StatusEventReceiver

        fileprivate init(ticks: AsyncStream<Void>, receiver: StatusEventReceiver) {
            self.ticks = ticks
            self.receiver = receiver
        }

        func take() -> StatusChange { receiver.take() }
    }

    static func statusChanges(in plan: StatusWatchPlan, latency: TimeInterval = 1) -> StatusChangeFeed {
        let (ticks, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let receiver = StatusEventReceiver(plan: plan, continuation: continuation)
        let handle = eventStream(roots: Array(Set(plan.roots.map(\.path))), latency: latency) { receiver.receive($0) }
        guard let handle else {
            continuation.finish()
            return StatusChangeFeed(ticks: ticks, receiver: receiver)
        }
        receiver.observeMutations()
        continuation.onTermination = { _ in receiver.stop(); handle.stop() }
        return StatusChangeFeed(ticks: ticks, receiver: receiver)
    }

    static func changes(in roots: [String], latency: TimeInterval = 2) -> AsyncStream<Set<String>> {
        AsyncStream { continuation in
            // Longer roots first, so a nested repository wins over its parent.
            let receiver = ActivityEventReceiver(roots: roots.sorted { $0.count > $1.count }, continuation: continuation)
            guard let handle = eventStream(roots: roots, latency: latency, receive: { receiver.receive($0) }) else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in handle.stop() }
        }
    }

    private static func eventStream(roots: [String], latency: TimeInterval,
                                    receive: @escaping @Sendable ([String]) -> Void) -> StreamHandle? {
        guard !roots.isEmpty else { return nil }
        let box = EventCallback(receive)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil,
            release: { Unmanaged<EventCallback>.fromOpaque($0!).release() }, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<EventCallback>.fromOpaque(info).takeUnretainedValue()
            box.receive(Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? [])
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            Unmanaged<EventCallback>.fromOpaque(context.info!).release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "FoldGit.RepositoryChangeMonitor"))
        FSEventStreamStart(stream)
        return StreamHandle(stream)
    }
}

private struct GitMetadataDirectories: RepositoryCommand {
    var directory: URL
    var isReadOnly: Bool { true }
    var arguments: [String] { ["git", "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"] }
    func parse(for standardOutput: String) throws -> (git: String, common: String) {
        let paths = standardOutput.split(whereSeparator: \.isNewline).map { RepositoryLocation.canonical(URL(fileURLWithPath: String($0))).path }
        guard paths.count == 2 else {
            throw GitExecutionError(description: NSLocalizedString("Git returned invalid worktree information.", comment: ""))
        }
        return (paths[0], paths[1])
    }
}

private final class EventCallback: Sendable {
    let receive: @Sendable ([String]) -> Void
    init(_ receive: @escaping @Sendable ([String]) -> Void) { self.receive = receive }
}

private final class ActivityEventReceiver: Sendable {
    private let roots: [String]
    private let continuation: AsyncStream<Set<String>>.Continuation

    init(roots: [String], continuation: AsyncStream<Set<String>>.Continuation) {
        self.roots = roots
        self.continuation = continuation
    }

    func receive(_ paths: [String]) {
        var changed = Set<String>()
        // Git metadata changes, such as fetches, do not change working-tree modification dates.
        for path in paths where !path.contains("/.git/") && !path.hasSuffix("/.git") {
            if let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) { changed.insert(root) }
        }
        if !changed.isEmpty { continuation.yield(changed) }
    }
}

private final class StatusEventReceiver: @unchecked Sendable {
    private let plan: RepositoryChangeMonitor.StatusWatchPlan
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "FoldGit.StatusEventCoalescing")
    private var pending = RepositoryChangeMonitor.StatusChange()
    private var flush: DispatchWorkItem?
    private var observer: NSObjectProtocol?
    private var stopped = false

    init(plan: RepositoryChangeMonitor.StatusWatchPlan, continuation: AsyncStream<Void>.Continuation) {
        self.plan = plan
        self.continuation = continuation
    }

    /// App mutations can change a worktree's branch or HEAD, so they also reload the family's worktree list.
    func observeMutations() {
        observer = NotificationCenter.default.addObserver(forName: GitRuntime.repositoryDidChange, object: nil, queue: nil) { [weak self] event in
            guard let self, let directory = event.object as? URL,
                  let targets = self.plan.families[RepositoryLocation.canonical(directory).path] else { return }
            self.enqueue(.init(paths: targets, listPaths: targets))
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        queue.async { [self] in stopped = true; flush?.cancel(); flush = nil; pending = .init() }
    }

    func receive(_ paths: [String]) { enqueue(plan.affected(by: paths)) }

    func take() -> RepositoryChangeMonitor.StatusChange {
        queue.sync {
            let change = pending
            pending = .init()
            return change
        }
    }

    private func enqueue(_ change: RepositoryChangeMonitor.StatusChange) {
        guard !change.isEmpty else { return }
        queue.async { [self] in
            guard !stopped else { return }
            pending.formUnion(change)
            guard flush == nil else { return }
            let work = DispatchWorkItem { [self] in
                flush = nil
                guard !stopped else { return }
                continuation.yield()
            }
            flush = work
            queue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }
}

private final class StreamHandle: @unchecked Sendable {
    private let stream: FSEventStreamRef

    init(_ stream: FSEventStreamRef) { self.stream = stream }

    func stop() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
