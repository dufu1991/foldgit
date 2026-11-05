import FoldGitCore
import Foundation

/// A commit operation that the context menu and the menu bar both confirm before running.
enum CommitOperationRequest: Identifiable, Equatable {
    case checkout(Commit)
    case revert(Commit)
    case cherryPick(Commit)
    case reset(Commit, GitResetMode)

    var id: String {
        switch self {
        case .checkout(let commit): "checkout-" + commit.hash
        case .revert(let commit): "revert-" + commit.hash
        case .cherryPick(let commit): "cherryPick-" + commit.hash
        case .reset(let commit, let mode): "reset-\(mode.rawValue)-" + commit.hash
        }
    }

    var commit: Commit {
        switch self {
        case .checkout(let commit), .revert(let commit), .cherryPick(let commit), .reset(let commit, _): commit
        }
    }

    /// Checkout only moves HEAD; every other request writes commits or discards changes.
    var requiresCommitOperations: Bool {
        if case .checkout = self { return false }
        return true
    }
}

struct RepositoryPresentation {
    var squashCommits = false
    var branches = false
    var mergeResolution = false
    var mergeBranch = false
    var createNewBranchFrom: Branch?
    var renameBranch: Branch?
    var stashChanged = false
    var compareRevisions = false
    var tags = false
    var createNewTagAt: Commit?
    var amendCommitAt: Commit?
    var commitOperation: CommitOperationRequest?
    var remoteCheckout: Branch?

    var isPresented: Bool {
        squashCommits || branches || mergeResolution || mergeBranch || stashChanged || compareRevisions || tags
            || createNewBranchFrom != nil || renameBranch != nil || createNewTagAt != nil || amendCommitAt != nil
            || commitOperation != nil || remoteCheckout != nil
    }
}
