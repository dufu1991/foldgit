import Foundation

public enum GitFileVersion: Hashable, Sendable {
    case revision(String)
    case blob(String)
    case index
    case workingTree
    case absent
}

public enum GitFileContent {
    public static func read(at directory: URL, path: String, version: GitFileVersion,
                            maximumBytes: Int = GitRuntime.outputLimit) async throws -> Data? {
        try Task.checkCancellation()
        let object: String
        switch version {
        case .absent:
            return nil
        case .workingTree:
            return try await Task.detached {
                let url = directory.appendingPathComponent(path)
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size <= maximumBytes else {
                    throw GitExecutionError(description: NSLocalizedString("The image is too large to preview.", comment: ""))
                }
                try Task.checkCancellation()
                return try Data(contentsOf: url)
            }.value
        case .revision(let revision):
            object = "\(revision):\(path)"
        case .blob(let id):
            object = id
        case .index:
            object = ":\(path)"
        }
        return try await GitRuntime.runData(arguments: ["git", "cat-file", "blob", object],
                                            currentDirectoryURL: directory, maximumBytes: maximumBytes)
    }
}
