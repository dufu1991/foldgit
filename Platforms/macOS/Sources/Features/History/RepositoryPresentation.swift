import FoldGitCore
import Foundation

struct RepositoryPresentation {
    var branches = false
    var mergeResolution = false
    var createNewBranchFrom: Branch?
    var renameBranch: Branch?
    var stashChanged = false
    var compareRevisions = false
    var tags = false
    var createNewTagAt: Commit?
    var amendCommitAt: Commit?
}
