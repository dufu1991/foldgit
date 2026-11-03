import FoldGitCore
import Foundation

enum PreferenceKey: String, CaseIterable {
    case folder
    case folderBeforeLogicalGroups
    case repositoryDisplayNames
    case sidebarSort
    case sidebarSortAscending
    case sidebarDates
    case showCommitMessageArea
    case commitMessageSnippet
    case commitMessageSnippetEntries
    case searchTokenHisrtory
    case diffLayout
    case diffFileExpansion
    case changeFileLayout
    case toolbarLabelStyle
    case projectAutoFetch
    case defaultAutoFetchInterval
    case lastSettingsTab
    case openInPinnedApplications
    case openInRecentApplications
    case openInCustomApplications
    case interfaceLanguage
    case launchAtLoginConfigured
    case appAppearance
    case commitTimeDisplayMode
    case restoreSession
    case lastSelectedRepository
    case quitAfterLastWindow
    case repositoryHistoryScopes
    case showCommitGraph
    case showWorktreeInformation
    case showWorktreeStatus
    case repositoryWorktreeVisibility
    case codeFontSize
    case wrapLongLines
    case checkForUpdatesAtLaunch
}

