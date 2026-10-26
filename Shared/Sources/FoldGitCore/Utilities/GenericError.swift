import Foundation

public struct GenericError: Error, LocalizedError, Sendable {
    public var errorDescription: String?

    public init(errorDescription: String) {
        self.errorDescription = errorDescription
    }
}
