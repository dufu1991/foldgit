import Foundation

/// A foreground syntax scope over the caller's unchanged UTF-16 source text.
public struct SyntaxSpan: Sendable {
    public let range: NSRange
    public let scopes: [String]

    public init(range: NSRange, scopes: [String]) {
        self.range = range
        self.scopes = scopes
    }
}
