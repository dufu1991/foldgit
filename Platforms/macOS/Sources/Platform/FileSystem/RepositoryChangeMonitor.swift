import CoreServices
import Foundation

/// Reports which repository roots had working-tree file events, so activity scans run only for changed repositories.
enum RepositoryChangeMonitor {
    static func changes(in roots: [String], latency: TimeInterval = 2) -> AsyncStream<Set<String>> {
        AsyncStream { continuation in
            // Longer roots first, so a nested repository wins over its parent.
            let receiver = EventReceiver(roots: roots.sorted { $0.count > $1.count }, continuation: continuation)
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passRetained(receiver).toOpaque(), retain: nil,
                release: { Unmanaged<EventReceiver>.fromOpaque($0!).release() }, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
                guard let info else { return }
                let receiver = Unmanaged<EventReceiver>.fromOpaque(info).takeUnretainedValue()
                receiver.receive(Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? [])
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
            guard !roots.isEmpty,
                  let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
                Unmanaged<EventReceiver>.fromOpaque(context.info!).release()
                continuation.finish()
                return
            }
            let handle = StreamHandle(stream)
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "FoldGit.RepositoryChangeMonitor"))
            FSEventStreamStart(stream)
            continuation.onTermination = { _ in handle.stop() }
        }
    }
}

private final class EventReceiver: @unchecked Sendable {
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

private final class StreamHandle: @unchecked Sendable {
    private let stream: FSEventStreamRef

    init(_ stream: FSEventStreamRef) { self.stream = stream }

    func stop() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
