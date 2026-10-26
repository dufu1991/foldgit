import Foundation

public struct GitRef: Hashable, Identifiable, Sendable {
    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    public enum Kind: Hashable, Sendable {
        case head
        case localBranch
        case remoteBranch
        case tag
    }

    public let name: String
    public let kind: Kind

    public var id: String {
        revision
    }

    public var revision: String {
        switch kind {
        case .head:
            "HEAD"
        case .localBranch:
            "refs/heads/\(name)"
        case .remoteBranch:
            "refs/remotes/\(name)"
        case .tag:
            "refs/tags/\(name)"
        }
    }

}
