import SwiftUI

struct OpenWorkspaceFileAction: Sendable {
    var directory: URL
    var perform: @MainActor @Sendable (String) -> Void

    @MainActor func callAsFunction(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) else { return false }
        perform(path)
        return true
    }
}

private struct OpenWorkspaceFileKey: EnvironmentKey {
    static let defaultValue: OpenWorkspaceFileAction? = nil
}

extension EnvironmentValues {
    var openWorkspaceFile: OpenWorkspaceFileAction? {
        get { self[OpenWorkspaceFileKey.self] }
        set { self[OpenWorkspaceFileKey.self] = newValue }
    }
}
