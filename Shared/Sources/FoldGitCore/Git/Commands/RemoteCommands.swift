import Foundation

public struct GitFetch: GitAction {
    public var directory: URL
    public var tags = false
    public var isBackground = false
    public init(directory: URL, tags: Bool = false, isBackground: Bool = false) {
        self.directory = directory
        self.tags = tags
        self.isBackground = isBackground
    }

    public var arguments: [String] { ["git", "fetch"] + (tags ? ["--tags"] : []) }
    public var environment: [String: String] {
        isBackground ? ["GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "Never"] : [:]
    }
}

public struct GitPull: GitAction {
    public var directory: URL
    public var refspec: String
    public var remote: String
    public init(directory: URL, refspec: String, remote: String) {
        self.directory = directory
        self.refspec = refspec
        self.remote = remote
    }
    public var arguments: [String] { ["git", "pull", remote, refspec] }
}

public struct GitPush: GitAction {
    public var directory: URL
    public var refspec = "HEAD"
    public var remote: String
    public var setUpstream = false
    public init(directory: URL, refspec: String = "HEAD", remote: String, setUpstream: Bool = false) {
        self.directory = directory
        self.refspec = refspec
        self.remote = remote
        self.setUpstream = setUpstream
    }
    public var arguments: [String] { ["git", "push"] + (setUpstream ? ["--set-upstream"] : []) + [remote, refspec] }
}
