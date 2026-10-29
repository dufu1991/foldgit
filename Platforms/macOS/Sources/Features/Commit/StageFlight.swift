import FoldGitCore
import SwiftUI

/// A file name that flies between the unstaged and staged panes while Git updates the index.
struct StageFlightItem: Equatable {
    var path: String
    var title: String
    var change: FileChange?
}

enum StageFlightPane: Hashable {
    case unstaged, staged

    var other: StageFlightPane { self == .staged ? .unstaged : .staged }
}

struct StageFlight: Identifiable {
    let id = UUID()
    var item: StageFlightItem
    var from: CGRect
    var to: CGRect
    var destination: StageFlightPane
    var isSettled = false
}

extension EnvironmentValues {
    @Entry var stageFlights: StageFlightCoordinator?
    @Entry var stageFlightPane: StageFlightPane?
}

/// Flies a file's name to its row in the other pane. The row only exists after Git updates the index and the
/// lists refresh, so a flight heads for the pane's heading first and turns towards the row once it appears.
@MainActor @Observable
final class StageFlightCoordinator {
    static let coordinateSpace = "stageFlight"

    private(set) var flights: [StageFlight] = []
    private var departing: [StageFlightPane: Set<String>] = [:]
    private var arrived: [StageFlightPane: Set<String>] = [:]
    @ObservationIgnored var paneFrames: [StageFlightPane: CGRect] = [:]
    @ObservationIgnored var reduceMotion = false
    // Rows report their frames as they scroll. Keeping them unobserved avoids redrawing the lists.
    @ObservationIgnored private var rowFrames: [StageFlightPane: [String: CGRect]] = [:]

    func isDeparting(_ path: String, from pane: StageFlightPane) -> Bool {
        departing[pane]?.contains(path) == true
    }

    func hasArrived(_ path: String, in pane: StageFlightPane) -> Bool {
        arrived[pane]?.contains(path) == true
    }

    func report(_ path: String, frame: CGRect?, in pane: StageFlightPane) {
        rowFrames[pane, default: [:]][path] = frame
    }

    func launch(_ item: StageFlightItem, from source: CGRect, leaving pane: StageFlightPane) {
        departing[pane, default: []].insert(item.path)
        let destination = pane.other
        guard !reduceMotion, !source.isEmpty, let paneFrame = paneFrames[destination], !paneFrame.isEmpty else {
            highlight(item.path, in: destination, after: .milliseconds(400))
            return
        }
        let flight = StageFlight(item: item, from: source, to: estimate(for: item, in: destination, from: source),
                                 destination: destination)
        flights.append(flight)
        // A failed update never refreshes the lists, so the flight settles on its own.
        Task {
            try? await Task.sleep(for: .seconds(2))
            settle(flight.id)
        }
    }

    /// The index changed and the lists are refreshing; give the new rows a moment to report where they are.
    func indexDidUpdate() {
        departing = [:]
        let pending = flights.filter { !$0.isSettled }.map(\.id)
        guard !pending.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            pending.forEach(settle)
        }
    }

    private func settle(_ id: StageFlight.ID) {
        guard let index = flights.firstIndex(where: { $0.id == id }), !flights[index].isSettled else { return }
        flights[index].isSettled = true
        let flight = flights[index]
        let (target, landingPath) = landing(for: flight)
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
            flights[index].to = target
        } completion: { [self] in
            withAnimation(.easeOut(duration: 0.2)) {
                flights.removeAll { $0.id == id }
            }
            if let landingPath { highlight(landingPath, in: flight.destination, after: .zero) }
        }
    }

    private func landing(for flight: StageFlight) -> (CGRect, String?) {
        let pane = flight.destination
        let frames = rowFrames[pane] ?? [:]
        let paneFrame = paneFrames[pane] ?? .zero
        let source = flight.from
        if let row = frames[flight.item.path] {
            return (clamped(row, source: source, in: pane), flight.item.path)
        }
        // A collapsed folder in the tree hides the file, so land on the nearest folder row that is showing.
        var directory = flight.item.path
        while let slash = directory.lastIndex(of: "/") {
            directory = String(directory[..<slash])
            if let row = frames[directory] {
                return (clamped(row, source: source, in: pane), directory)
            }
        }
        // Lazy lists never draw rows far outside the visible area. Both lists sort by path,
        // so the rows on screen tell which edge the file lies beyond.
        let visible = frames.filter { paneFrame.intersects($0.value) }.keys
        if let first = visible.min(), let last = visible.max() {
            if flight.item.path > last {
                return (edge(of: pane, top: false, source: source), nil)
            }
            if flight.item.path < first {
                return (edge(of: pane, top: true, source: source), nil)
            }
        }
        return (flight.to, nil)
    }

    /// Where the row will most likely appear before it exists. Both lists sort by path, so the new row takes the
    /// place of the first row on screen that sorts after it. Aiming there from the start keeps the flight from
    /// passing its row and turning back once the lists refresh.
    private func estimate(for item: StageFlightItem, in pane: StageFlightPane, from source: CGRect) -> CGRect {
        let frames = rowFrames[pane] ?? [:]
        // A partly staged file already has a row in the other pane.
        if let row = frames[item.path] {
            return clamped(row, source: source, in: pane)
        }
        let paneFrame = paneFrames[pane] ?? .zero
        let visible = frames.filter { paneFrame.intersects($0.value) }
        if let next = visible.filter({ $0.key > item.path }).min(by: { $0.value.minY < $1.value.minY }) {
            return clamped(next.value, source: source, in: pane)
        }
        if let last = visible.values.max(by: { $0.maxY < $1.maxY }) {
            return clamped(last.offsetBy(dx: 0, dy: last.height), source: source, in: pane)
        }
        return heading(of: pane, from: source)
    }

    private func clamped(_ row: CGRect, source: CGRect, in pane: StageFlightPane) -> CGRect {
        let target = CGRect(x: row.minX, y: row.minY, width: source.width, height: source.height)
        let top = edge(of: pane, top: true, source: source)
        let bottom = edge(of: pane, top: false, source: source)
        return target.offsetBy(dx: 0, dy: min(max(target.minY, top.minY), bottom.minY) - target.minY)
    }

    private func heading(of pane: StageFlightPane, from source: CGRect) -> CGRect {
        let paneFrame = paneFrames[pane] ?? .zero
        // The staged pane has a slim top inset; the unstaged list starts below its scroll padding.
        return CGRect(x: source.minX, y: paneFrame.minY + (pane == .staged ? 8 : 16),
                      width: source.width, height: source.height)
    }

    private func edge(of pane: StageFlightPane, top: Bool, source: CGRect) -> CGRect {
        if top { return heading(of: pane, from: source) }
        let paneFrame = paneFrames[pane] ?? .zero
        return CGRect(x: source.minX, y: paneFrame.maxY - source.height - 4, width: source.width, height: source.height)
    }

    private func highlight(_ path: String, in pane: StageFlightPane, after delay: Duration) {
        Task {
            try? await Task.sleep(for: delay)
            arrived[pane, default: []].insert(path)
            try? await Task.sleep(for: .milliseconds(900))
            arrived[pane]?.remove(path)
        }
    }
}

extension View {
    /// Lets a row in a change pane launch and receive flights, and marks it while one leaves or reaches it.
    func stageFlightRow(path: String, frame: StageFlightFrame? = nil) -> some View {
        modifier(StageFlightRowModifier(path: path, frame: frame))
    }
}

/// Holds a row's latest frame without redrawing the row when it scrolls.
final class StageFlightFrame {
    var rect = CGRect.zero
}

private struct StageFlightRowModifier: ViewModifier {
    @Environment(\.stageFlights) private var coordinator
    @Environment(\.stageFlightPane) private var pane
    var path: String
    var frame: StageFlightFrame?

    func body(content: Content) -> some View {
        if let coordinator, let pane {
            let isDeparting = coordinator.isDeparting(path, from: pane)
            let hasArrived = coordinator.hasArrived(path, in: pane)
            // Rows paint an opaque background, so the arrival highlight sits on top of it.
            content
                .opacity(isDeparting ? 0.3 : 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(hasArrived ? 0.18 : 0))
                        .allowsHitTesting(false)
                }
                .animation(.easeOut(duration: 0.25), value: isDeparting)
                .animation(.easeOut(duration: 0.4), value: hasArrived)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(StageFlightCoordinator.coordinateSpace))
                } action: {
                    frame?.rect = $0
                    coordinator.report(path, frame: $0, in: pane)
                }
                .onDisappear { coordinator.report(path, frame: nil, in: pane) }
        } else {
            content
        }
    }
}

struct StageFlightGhost: View {
    @Environment(\.colorScheme) private var colorScheme
    var flight: StageFlight
    @State private var hasDeparted = false

    var body: some View {
        let rect = hasDeparted ? flight.to : flight.from
        HStack {
            if let change = flight.item.change {
                FileChangeBadge(change: change)
            }
            Image(nsImage: FileIconTheme.bundled.image(filePath: flight.item.path, isDark: colorScheme == .dark))
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text(verbatim: flight.item.title)
                .fontWeight(.bold)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .frame(width: flight.from.width, height: max(22, flight.from.height), alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.5)))
        .shadow(color: .black.opacity(0.18), radius: flight.isSettled ? 3 : 8, y: flight.isSettled ? 1 : 4)
        .scaleEffect(hasDeparted ? 1 : 1.03)
        .position(x: rect.minX + flight.from.width / 2, y: rect.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.spring(duration: 0.45, bounce: 0.15)) {
                hasDeparted = true
            }
        }
    }
}
