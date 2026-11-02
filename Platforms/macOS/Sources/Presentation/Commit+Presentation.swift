import AppKit
import Combine
import FoldGitCore
import Foundation
import Observation
import SwiftUI

enum CommitTimeDisplayMode: String, CaseIterable, Identifiable {
    case relative, absolute, hybrid
    var id: Self { self }

    var title: String {
        switch self {
        case .relative: String(localized: "Relative Time")
        case .absolute: String(localized: "Absolute Time")
        case .hybrid: String(localized: "Hybrid")
        }
    }

    func usesAbsoluteTime(for date: Date, now: Date) -> Bool {
        self == .absolute || (self == .hybrid && (date > now || now.timeIntervalSince(date) >= 7 * 24 * 60 * 60))
    }
}

struct CommitTimeDisplay {
    let text: String
    let tooltip: String
    let timeZone: String
    let isAbsolute: Bool
}

@MainActor
enum CommitTimeFormatter {
    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private static let relativeFormatter = RelativeDateTimeFormatter()

    static func display(_ date: Date, mode: CommitTimeDisplayMode, now: Date,
                        locale: Locale, timeZone: TimeZone) -> CommitTimeDisplay {
        absoluteFormatter.timeZone = timeZone
        let absolute = absoluteFormatter.string(from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let zone = String(format: "UTC%@%02d:%02d", offset < 0 ? "−" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
        let isAbsolute = mode.usesAbsoluteTime(for: date, now: now)
        relativeFormatter.locale = locale
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        relativeFormatter.calendar = calendar
        relativeFormatter.dateTimeStyle = .named
        relativeFormatter.unitsStyle = .full
        var text = isAbsolute ? absolute : relativeFormatter.localizedString(for: date, relativeTo: now)
        if !isAbsolute && locale.language.languageCode?.identifier == "zh" {
            text = text.replacingOccurrences(of: #"(?<=\p{Han})(?=[0-9A-Za-z])|(?<=[0-9A-Za-z])(?=\p{Han})"#,
                                            with: " ", options: .regularExpression)
        }
        return CommitTimeDisplay(text: text,
                                 tooltip: "\(absolute) \(zone)", timeZone: zone, isAbsolute: isAbsolute)
    }
}

/// One clock serves every commit view and stops ticking in absolute mode.
@MainActor
@Observable
final class CommitTimeClock {
    static let shared = CommitTimeClock()
    private(set) var now = Date.now
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: AnyCancellable?
    @ObservationIgnored private var observers: [AnyCancellable] = []
    var isTicking: Bool { timer != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for name in [UserDefaults.didChangeNotification, NSApplication.didBecomeActiveNotification,
                     NSNotification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            observers.append(NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }

    func refresh(now: Date = .now) {
        self.now = now
        if AppPreferences.commitTimeDisplayMode(in: defaults) == .absolute {
            timer?.cancel()
            timer = nil
        } else if timer == nil {
            timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] date in
                Task { @MainActor [weak self] in self?.now = date }
            }
        }
    }
}

struct CommitTimeView: View {
    let commit: Commit
    var showsTimeZone = false
    @AppStorage(PreferenceKey.commitTimeDisplayMode.rawValue) private var mode = AppPreferences.defaultCommitTimeDisplayMode
    @Environment(\.locale) private var locale

    var body: some View {
        if let date = commit.date {
            let display = CommitTimeFormatter.display(date, mode: mode,
                now: CommitTimeClock.shared.now, locale: locale, timeZone: .current)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: display.text)
                    .monospacedDigit()
                if showsTimeZone && display.isAbsolute {
                    Text(verbatim: display.timeZone)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .help(Text(verbatim: display.tooltip))
            .accessibilityElement(children: .combine)
            .onChange(of: mode) { CommitTimeClock.shared.refresh() }
        }
    }
}

struct CommitAccessibilityModifier: ViewModifier {
    let commit: Commit
    @AppStorage(PreferenceKey.commitTimeDisplayMode.rawValue) private var mode = AppPreferences.defaultCommitTimeDisplayMode
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        let time = commit.date.map {
            CommitTimeFormatter.display($0, mode: mode, now: CommitTimeClock.shared.now,
                                        locale: locale, timeZone: .current).text
        }
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: commit.title))
            .accessibilityValue(Text(verbatim: ([String(commit.hash.prefix(7)), commit.author] + [time].compactMap { $0 }).joined(separator: ", ")))
    }
}

extension Commit {
    /// Merge commits, including octopus merges, revert against their first parent.
    var revertMainline: Int? { parentHashes.count > 1 ? 1 : nil }
}
