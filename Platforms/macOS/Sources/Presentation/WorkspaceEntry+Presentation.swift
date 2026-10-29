import AppKit
import FoldGitCore
import SwiftUI

extension WorkspaceEntry {
    var symbol: String { isRepository ? "book.closed" : "folder" }

    var repositoryIconColor: Color {
        var hash = identity.path.utf8.reduce(UInt64(14695981039346656037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1099511628211
        }
        hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
        hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
        hash ^= hash >> 31
        let hue = Double(hash % 360) / 360
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(calibratedHue: hue, saturation: 0.5, brightness: isDark ? 0.85 : 0.62, alpha: 1)
        })
    }
}
