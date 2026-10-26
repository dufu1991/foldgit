import Foundation

public enum GitFileVersion: Hashable, Sendable {
    case revision(String)
    case blob(String)
    case index
    case workingTree
    case absent
}

public enum GitFileContent {
    public static func read(at directory: URL, path: String, version: GitFileVersion) async throws -> Data? {
        try Task.checkCancellation()
        switch version {
        case .absent:
            return nil
        case .workingTree:
            return try await Task.detached {
                let url = directory.appendingPathComponent(path)
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size <= GitRuntime.outputLimit else {
                    throw GitExecutionError(description: NSLocalizedString("The image is too large to preview.", comment: ""))
                }
                try Task.checkCancellation()
                return try Data(contentsOf: url)
            }.value
        case .revision(let revision):
            return try await GitRuntime.runData(arguments: ["git", "cat-file", "blob", "\(revision):\(path)"], currentDirectoryURL: directory)
        case .blob(let object):
            return try await GitRuntime.runData(arguments: ["git", "cat-file", "blob", object], currentDirectoryURL: directory)
        case .index:
            return try await GitRuntime.runData(arguments: ["git", "cat-file", "blob", ":\(path)"], currentDirectoryURL: directory)
        }
    }
}
