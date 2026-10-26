import Foundation

public struct Stash: Identifiable, Hashable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var message: String
    public var raw: String

    public init(index: Int, raw: String) {
        self.index = index
        self.raw = raw
        self.message = String(raw.split(separator: ":", maxSplits: 1).map { String($0) }[safe: 1]?.dropFirst() ?? "")
    }
}
