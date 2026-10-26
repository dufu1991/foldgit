import Foundation

public struct Status: Hashable, Sendable {
    public init(untrackedFiles: [String], unmergedFiles: [String]) {
        self.untrackedFiles = untrackedFiles
        self.unmergedFiles = unmergedFiles
    }

    public var untrackedFiles: [String]
    public var unmergedFiles: [String]
}
