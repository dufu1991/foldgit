import FoldGitCore
import Foundation

extension AutoFetchInterval {
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .fiveMinutes: String(localized: "Every 5 Minutes")
        case .tenMinutes: String(localized: "Every 10 Minutes")
        case .thirtyMinutes: String(localized: "Every 30 Minutes")
        case .sixtyMinutes: String(localized: "Every 60 Minutes")
        case .twentyFourHours: String(localized: "Every 24 Hours")
        }
    }
}
