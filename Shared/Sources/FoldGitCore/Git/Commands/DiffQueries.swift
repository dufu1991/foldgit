import Foundation

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
        var arguments = ["git", "diff", "--full-index"]
        if noRenames { arguments.append("--no-renames") }
        if shortstat { arguments.append("--shortstat") }
        if cached { arguments.append("--cached") }
        if !commitRange.isEmpty { arguments.append(commitRange) }
        return arguments
    }
}
