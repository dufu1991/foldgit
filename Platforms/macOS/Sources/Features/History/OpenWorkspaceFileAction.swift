import SwiftUI

struct OpenWorkspaceFileAction: Sendable {
    var perform: @MainActor @Sendable (String) -> Void
    @MainActor func callAsFunction(_ path: String) { perform(path) }
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
