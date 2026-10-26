import Foundation

public protocol RepositoryCommand: Sendable {
    associatedtype OutputModel: Sendable
    var arguments: [String] { get }
    var environment: [String: String] { get }
    var directory: URL { get set }
    /// Read-only commands may run alongside each other; anything else has exclusive access to the repository.
    var isReadOnly: Bool { get }
    func parse(for standardOutput: String) throws -> OutputModel
}

public protocol InteractiveRepositoryCommand: RepositoryCommand {
    var inputs: [String] { get }
}

/// A command run for its side effects only.
public protocol GitAction: RepositoryCommand where OutputModel == Void {}

/// A read-only command whose standard output is used as is.
public protocol GitTextQuery: RepositoryCommand where OutputModel == String {}

public extension RepositoryCommand {
    var environment: [String: String] { [:] }
    var isReadOnly: Bool { false }
}

public extension GitAction {
    func parse(for standardOutput: String) {}
}

public extension GitTextQuery {
    var isReadOnly: Bool { true }
    func parse(for standardOutput: String) -> String { standardOutput }
}
