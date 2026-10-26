import Foundation

public struct GitBranch: RepositoryCommand {
    public var directory: URL
    public var isRemote = false
    public init(directory: URL, isRemote: Bool = false) { self.directory = directory; self.isRemote = isRemote }

    public var isReadOnly: Bool { true }
    public var arguments: [String] { ["git", "branch", "--sort=-authordate"] + (isRemote ? ["-r"] : []) }

    public func parse(for stdOut: String) throws -> [Branch] {
        stdOut.components(separatedBy: .newlines).dropLast()
            .map { Branch(name: String($0.dropFirst(2)), isCurrent: $0.hasPrefix("*")) }
            .filter { !isRemote || !$0.name.contains(" -> ") }
    }
}

public struct GitBranchDelete: GitAction {
    public var directory: URL
    public var isRemote = false
    public var branchName: String
    public init(directory: URL, isRemote: Bool = false, branchName: String) {
        self.directory = directory
        self.isRemote = isRemote
        self.branchName = branchName
    }
    public var arguments: [String] { ["git", "branch", "--delete"] + (isRemote ? ["-r"] : []) + [branchName] }
}

public struct GitBranchRename: GitAction {
    public var directory: URL
    public var oldBranchName: String
    public var newBranchName: String
    public init(directory: URL, oldBranchName: String, newBranchName: String) {
        self.directory = directory
        self.oldBranchName = oldBranchName
        self.newBranchName = newBranchName
    }
    public var arguments: [String] { ["git", "branch", "-m", oldBranchName, newBranchName] }
}

public struct GitCheckout: GitAction {
    public var directory: URL
    public var commitHash: String
    public init(directory: URL, commitHash: String) { self.directory = directory; self.commitHash = commitHash }
    public var arguments: [String] { ["git", "checkout", commitHash] }
}

public struct GitCheckoutB: GitAction {
    public var directory: URL
    public var newBranchName: String
    public var startPoint: String
    public init(directory: URL, newBranchName: String, startPoint: String) {
        self.directory = directory
        self.newBranchName = newBranchName
        self.startPoint = startPoint
    }
    public var arguments: [String] { ["git", "checkout", "-b", newBranchName, startPoint] }
}

public struct GitMerge: GitAction {
    public var directory: URL
    public var branchName: String
    public init(directory: URL, branchName: String) { self.directory = directory; self.branchName = branchName }
    public var arguments: [String] { ["git", "merge", "--no-edit", branchName] }
}

public struct GitRevert: GitAction {
    public var directory: URL
    public var parentNumber: Int?
    public var commit: String
    public init(directory: URL, parentNumber: Int? = nil, commit: String) {
        self.directory = directory
        self.parentNumber = parentNumber
        self.commit = commit
    }
    public var arguments: [String] { ["git", "revert", "--no-edit"] + (parentNumber.map { ["-m", String($0)] } ?? []) + [commit] }
}

public struct GitSwitch: GitAction {
    public var directory: URL
    public var branchName: String
    public var detach = false
    public init(directory: URL, branchName: String, detach: Bool = false) {
        self.directory = directory
        self.branchName = branchName
        self.detach = detach
    }
    public var arguments: [String] { ["git", "switch"] + (detach ? ["-d"] : []) + [branchName] }
}

public struct GitTag: RepositoryCommand {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }

    public var isReadOnly: Bool { true }
    public var arguments: [String] { ["git", "tag", "--no-column", "--sort=-creatordate"] }
    public func parse(for stdOut: String) throws -> [String] { stdOut.components(separatedBy: .newlines).dropLast() }
}

public struct GitTagCreate: GitAction {
    public var directory: URL
    public var tagname: String
    public var object: String
    public init(directory: URL, tagname: String, object: String) {
        self.directory = directory
        self.tagname = tagname
        self.object = object
    }
    public var arguments: [String] { ["git", "tag", tagname, object] }
}

public struct GitTagDelete: GitAction {
    public var directory: URL
    public var tagname: String
    public init(directory: URL, tagname: String) { self.directory = directory; self.tagname = tagname }
    public var arguments: [String] { ["git", "tag", "-d", tagname] }
}
