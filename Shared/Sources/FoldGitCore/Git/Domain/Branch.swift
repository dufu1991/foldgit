import Foundation

public struct Branch: Hashable, Identifiable, Sendable {
    public init(name: String, isCurrent: Bool) {
        self.name = name
        self.isCurrent = isCurrent
    }

    public let detachedPrefix = "(HEAD detached at "

    public var id: String {
        name
    }
    public var name: String
    public var isCurrent: Bool
    public var point: String {
        if isDetached {
            return String(name.dropFirst(detachedPrefix.count).dropLast(1))
        }
        return name
    }
    public var isDetached: Bool {
        return name.hasPrefix(detachedPrefix)
    }
}

extension [Branch] {
    public var currentFirst: [Branch] {
        filter { $0.isCurrent } + filter { !$0.isCurrent }
    }

    public var current: Branch? {
        first { $0.isCurrent }
    }
}
