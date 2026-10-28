import FoldGitCore
import Foundation

struct RepositoryPresentation {
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

    var isPresented: Bool {
        branches || mergeResolution || mergeBranch || stashChanged || compareRevisions || tags
            || createNewBranchFrom != nil || renameBranch != nil || createNewTagAt != nil || amendCommitAt != nil
    }
}
