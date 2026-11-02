import Foundation

public struct Commit: Hashable, Identifiable, Sendable {
    public init(hash: String, parentHashes: [String], author: String, authorEmail: String, authorDate: String, title: String, body: String, branches: [String], tags: [String]) {
        self.hash = hash
        self.parentHashes = parentHashes
        self.author = author
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.date = try? Date(authorDate, strategy: .iso8601)
        self.title = title
        self.body = body
        self.branches = branches
        self.tags = tags
    }

    public var id: String { hash }
    public var hash: String
    public var parentHashes: [String]
    public var author: String
    public var authorEmail: String
    public var authorDate: String {
        didSet { date = try? Date(authorDate, strategy: .iso8601) }
    }
    /// Parsed once, because history rows format dates on every update.
    public private(set) var date: Date?
    public var title: String
    public var body: String
    /// List previews omit coauthor attribution while the original message stays intact.
    public var listBody: String {
        body.replacingOccurrences(
            of: #"(?im)^[\t ]*co-(?:authored|developed|committed)-by[\t ]*:[^\r\n]*(?:\r?\n[\t ]+[^\r\n]+)*(?:\r?\n|$)"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var rawBody: String {
        guard !body.isEmpty else {
            return title
        }
        return title + "\n\n" + body
    }
    public var branches: [String]
    public var tags: [String]
}
