import Foundation

/// Commit objects cannot contain NUL bytes, so this format cannot collide with message text.
enum CommitRecord {
    static let fieldCount = 7
    static let format = "%H%x00%P%x00%an%x00%aE%x00%aI%x00%B%x00%D%x00"

    static func decode(_ fields: [String]) throws -> Commit {
        guard fields.count == fieldCount else { throw GitExecutionError(description: "Invalid commit fields from Git.") }
        let hash = fields[0].trimmingCharacters(in: .newlines)
        guard hash.count == 40 || hash.count == 64 else { throw GitExecutionError(description: "Invalid commit identifier from Git.") }
        let references = fields[6].isEmpty ? [] : fields[6].components(separatedBy: ", ")
        // Git's %s folds the first paragraph. Derive the title from the original first line instead.
        let message = fields[5].trimmingCharacters(in: .newlines)
        let lines = message.components(separatedBy: "\n")
        let title = lines[0].trimmingCharacters(in: .newlines)
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
        return Commit(hash: hash, parentHashes: fields[1].split(separator: " ").map(String.init),
                      author: fields[2], authorEmail: fields[3], authorDate: fields[4], title: title, body: body,
                      branches: references.filter { !$0.hasPrefix("tag: ") },
                      tags: references.filter { $0.hasPrefix("tag: ") }.map { String($0.dropFirst(5)) }, rawMessage: message)
    }
}
