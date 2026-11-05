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

    init(hash: String, parentHashes: [String], author: String, authorEmail: String, authorDate: String, title: String, body: String, branches: [String], tags: [String], rawMessage: String) {
        self.init(hash: hash, parentHashes: parentHashes, author: author, authorEmail: authorEmail,
                  authorDate: authorDate, title: title, body: body, branches: branches, tags: tags)
        // Most messages match the reconstruction, so only keep the exceptions.
        if rawMessage != rawBody { originalMessage = rawMessage }
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
    private var originalMessage: String?
    public var title: String {
        didSet { originalMessage = nil }
    }
    public var body: String {
        didSet { originalMessage = nil }
    }
    /// List previews omit coauthor attribution while the original message stays intact.
    public var listBody: String {
        body.replacingOccurrences(
            of: #"(?im)^[\t ]*co-(?:authored|developed|committed)-by[\t ]*:[^\r\n]*(?:\r?\n[\t ]+[^\r\n]+)*(?:\r?\n|$)"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var rawBody: String {
        if let originalMessage { return originalMessage }
        guard !body.isEmpty else {
            return title
        }
        return title + "\n\n" + body
    }
    public var branches: [String]
    public var tags: [String]
}

extension Array where Element == Commit {
    /// Follows first parents from `head` through the loaded commits, stopping at the first one not loaded.
    public func firstParentChain(from head: String?) -> [Commit] {
        let byHash = Dictionary(map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [Commit] = []
        var next = head
        while let hash = next, let commit = byHash[hash] {
            chain.append(commit)
            next = commit.parentHashes.first
        }
        return chain
    }
}
