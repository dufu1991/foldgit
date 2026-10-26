import FoldGitCore

extension GitRef {
    var systemImage: String {
        kind == .tag ? "tag" : "arrow.triangle.branch"
    }
}
