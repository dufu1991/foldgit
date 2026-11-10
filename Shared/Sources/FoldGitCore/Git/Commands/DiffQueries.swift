import Foundation

/// Patch options that keep output parseable and appliable whatever the user's diff configuration:
/// no external diff or textconv filters, and the standard `a/` and `b/` path prefixes.
public enum GitPatchOptions {
    public static let stable = ["--full-index", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/"]
}

public struct GitDiff: GitTextQuery {
    public var directory: URL
    public var noRenames = true
    public var shortstat = false
    public var cached = false
    public var commitRange = ""

    public init(directory: URL, noRenames: Bool = true, shortstat: Bool = false, cached: Bool = false, commitRange: String = "") {
        self.directory = directory
        self.noRenames = noRenames
        self.shortstat = shortstat
        self.cached = cached
        self.commitRange = commitRange
    }

    public var arguments: [String] {
        var arguments = ["git", "diff"] + GitPatchOptions.stable
        if noRenames { arguments.append("--no-renames") }
        if shortstat { arguments.append("--shortstat") }
        if cached { arguments.append("--cached") }
        if !commitRange.isEmpty { arguments.append(commitRange) }
        return arguments
    }
}
