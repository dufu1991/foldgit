import FoldGitCore
import Foundation

enum PreferenceKey: String, CaseIterable {
    case folder
    case folderBeforeLogicalGroups
    case repositoryDisplayNames
    case sidebarSort
    case sidebarSortAscending
    case sidebarDates
    case commitMessageSnippet
    case commitMessageSnippetEntries
    case searchTokenHisrtory
    case diffLayout
    case diffFileExpansion
    case toolbarLabelStyle
    case projectAutoFetch
    case openInPinnedApplications
    case openInRecentApplications
    case openInCustomApplications
    case interfaceLanguage
    case launchAtLoginConfigured
    case appAppearance
    case restoreSession
    case lastSelectedRepository
    case quitAfterLastWindow
    case showCommitGraph
    case showWorktreeInformation
    case repositoryWorktreeVisibility
    case codeFontSize
    case wrapLongLines
}

