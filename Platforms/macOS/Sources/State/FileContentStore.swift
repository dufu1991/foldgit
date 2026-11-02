import Foundation
import Observation

struct FileContentDocument: Sendable {
    let id = UUID()
    let text: String
    let plain: Bool
    var layout = FileContentLayout(lineCount: 1, maximumColumns: 0)
}

@MainActor
@Observable final class FileContentStore {
    enum State {
        case idle, loading, requiresLoad, missing
        case text(FileContentDocument)
        case unavailable(FileContentRestriction)
        case failed(String)
    }

    typealias Reader = @Sendable (URL, Bool) async throws -> FileContentSnapshot
    private(set) var state = State.idle
    private(set) var metadata: FileContentMetadata?
    private(set) var url: URL?
    @ObservationIgnored private(set) var readTask: Task<Void, Never>?
    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let reader: Reader
    private var generation = 0
    private var refreshGeneration = 0

    init(reader: @escaping Reader = { url, allowLarge in
        let task = Task.detached(priority: .userInitiated) {
            try FileContentReader.read(url, allowLarge: allowLarge)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }) {
        self.reader = reader
    }

    func show(directory: URL, path: String?) {
        let selected = path.map { directory.appendingPathComponent($0) }
        guard selected != url else { return }
        hide()
        url = selected
        if selected != nil { load() }
    }

    func hide() {
        generation += 1
        refreshGeneration += 1
        readTask?.cancel()
        refreshTask?.cancel()
        readTask = nil
        refreshTask = nil
        url = nil
        metadata = nil
        state = .idle
    }

    func load(allowLarge: Bool = false) {
        guard let url else { return }
        readTask?.cancel()
        generation += 1
        let request = generation
        state = .loading
        readTask = Task {
            do {
                let snapshot = try await reader(url, allowLarge)
                try Task.checkCancellation()
                guard request == generation else { return }
                metadata = snapshot.metadata
                switch snapshot.content {
                case .text(let source, let plain, let layout): state = .text(FileContentDocument(text: source, plain: plain, layout: layout))
                case .requiresLoad: state = .requiresLoad
                case .unavailable(let restriction): state = .unavailable(restriction)
                }
            } catch {
                guard !Task.isCancelled, request == generation else { return }
                receive(error)
            }
        }
    }

    /// Repository events inspect only the selected file, without rereading unchanged content.
    func refresh() {
        guard let url else { return }
        refreshTask?.cancel()
        refreshGeneration += 1
        let request = refreshGeneration
        refreshTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                let task = Task.detached(priority: .utility) { try FileContentReader.inspect(url) }
                let current = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard request == refreshGeneration else { return }
                if current != metadata {
                    // An initial load already owns this snapshot; avoid restarting it on focus events.
                    if metadata == nil, case .loading = state { return }
                    load()
                }
            } catch {
                guard !Task.isCancelled, request == refreshGeneration else { return }
                generation += 1
                readTask?.cancel()
                metadata = nil
                receive(error)
            }
        }
    }

    private func receive(_ error: any Error) {
        let failure = error as NSError
        if (failure.domain == NSPOSIXErrorDomain && [ENOENT, ENOTDIR].contains(Int32(failure.code)))
            || (failure.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(failure.code)) {
            state = .missing
        } else {
            state = .failed(error.localizedDescription)
        }
    }
}
