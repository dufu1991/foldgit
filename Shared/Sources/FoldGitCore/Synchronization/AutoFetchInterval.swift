import Foundation

public enum AutoFetchInterval: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case fiveMinutes = 5
    case tenMinutes = 10
    case thirtyMinutes = 30
    case sixtyMinutes = 60
    case twentyFourHours = 1440

    public var id: Int { rawValue }
    public var duration: Duration { .seconds(rawValue * 60) }

}
