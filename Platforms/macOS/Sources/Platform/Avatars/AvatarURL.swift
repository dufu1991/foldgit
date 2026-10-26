import CryptoKit
import Foundation

extension URL {
    static func gravater(email: String, size: CGFloat=80) -> URL? {
        guard let data = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().data(using: .utf8) else {
            return nil
        }
        let hashedData = SHA256.hash(data: data)
        let hashString = hashedData.compactMap { String(format: "%02x", $0) }.joined()
        return URL(string: "https://gravatar.com/avatar/" + hashString + "?d=404&size=\(size)") // https://docs.gravatar.com/api/avatars/images/
    }
}
