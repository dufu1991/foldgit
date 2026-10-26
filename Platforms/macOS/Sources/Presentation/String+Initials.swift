import Foundation

extension String {

    var initial: String {
        self.components(separatedBy: .whitespaces).map { $0.prefix(1).uppercased() }.joined()
    }
}
