import Foundation

/// Commit objects cannot contain NUL bytes, so this format cannot collide with message text.
enum CommitRecord {
    static let format = "%H%x00%P%x00%an%x00%aE%x00%aI%x00%s%x00%b%x00%D%x00"

    static func decode(_ fields: [String]) throws -> Commit {
        guard fields.count == 8 else { throw GitExecutionError(description: "Invalid commit fields from Git.") }
        let hash = fields[0].trimmingCharacters(in: .newlines)
        guard hash.count == 40 || hash.count == 64 else { throw GitExecutionError(description: "Invalid commit identifier from Git.") }
        let references = fields[7].isEmpty ? [] : fields[7].components(separatedBy: ", ")
        return Commit(hash: hash, parentHashes: fields[1].split(separator: " ").map(String.init),
                      author: fields[2], authorEmail: fields[3], authorDate: fields[4], title: fields[5], body: fields[6],
                      branches: references.filter { !$0.hasPrefix("tag: ") },
                      tags: references.filter { $0.hasPrefix("tag: ") }.map { String($0.dropFirst(5)) })
    }
}
