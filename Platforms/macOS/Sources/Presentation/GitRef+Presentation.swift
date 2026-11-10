import AppKit
import FoldGitCore
import SwiftUI

extension Image {
    static let gitBranch = Image("git.branch")
    /// Toolbar labels drop asset-catalog symbols loaded by name, so load the same symbol through NSImage.
    static let toolbarGitBranch = Image(nsImage: NSImage(named: "git.branch") ?? NSImage())
}

extension GitRef {
    var icon: Image {
        kind == .tag ? Image(systemName: "tag") : .gitBranch
    }
}
