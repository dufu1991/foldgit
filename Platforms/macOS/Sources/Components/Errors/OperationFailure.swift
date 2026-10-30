import FoldGitCore
import Foundation

struct OperationFailure: LocalizedError {
    let operation: String
    let underlying: any Error
    let directory: URL?

    init(_ operation: LocalizedStringResource, _ error: any Error, directory: URL? = nil) {
        self.operation = String(localized: operation)
        underlying = (error as? OperationFailure)?.underlying ?? error
        self.directory = directory ?? (error as? OperationFailure)?.directory
    }

    var reason: String { underlying.localizedDescription }
    var errorDescription: String? { operation + "\n" + reason }
    var gitFailure: GitExecutionError? { underlying as? GitExecutionError }
}

enum FileOpening {
    static func open(_ url: URL, using opener: (URL) -> Bool) -> OperationFailure? {
        guard !opener(url) else { return nil }
        return OperationFailure("Open File", GenericError(errorDescription:
            String(localized: "The file could not be opened: \(url.path)")))
    }
}
