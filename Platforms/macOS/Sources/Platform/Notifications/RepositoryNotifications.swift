import FoldGitCore
import Foundation

extension Notification.Name {
    static let repositoryMergeDidChange = Notification.Name("repositoryMergeDidChange")
    static let projectAutoFetchDidFinish = Notification.Name("projectAutoFetchDidFinish")
    static let didSelectCommitMessageSnippetNotification = Notification.Name("didSelectCommitMessageSnippetNotification")
}
