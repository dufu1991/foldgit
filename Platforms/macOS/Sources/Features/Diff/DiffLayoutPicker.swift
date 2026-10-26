import SwiftUI

enum DiffLayout: String, CaseIterable {
    case automatic
    case unified
    case sideBySide

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .unified: String(localized: "Unified")
        case .sideBySide: String(localized: "Side by Side")
        }
    }

    static let automaticThreshold: CGFloat = 800

    func resolved(for width: CGFloat) -> Self {
        guard self == .automatic else { return self }
        return width > Self.automaticThreshold ? .sideBySide : .unified
    }
}

struct DiffLayoutPicker: View {
    @AppStorage(PreferenceKey.diffLayout.rawValue) private var layout = DiffLayout.automatic

    var body: some View {
        Picker("Diff Layout", selection: $layout) {
            ForEach(DiffLayout.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Diff Layout")
        .accessibilityIdentifier("diffLayoutPicker")
    }
}

struct DiffDisplayControls: View {
    var showsFileControls = true
    var onExpandAll: () -> Void
    var onCollapseAll: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                DiffLayoutPicker()
                fileControls
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                DiffLayoutPicker()
                fileControls
            }
        }
        .font(.callout)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var fileControls: some View {
        if showsFileControls {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { fileButtons }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { fileButtons }
            }
        }
    }

    @ViewBuilder
    private var fileButtons: some View {
        Button("Expand All Files", action: onExpandAll)
            .fixedSize()
        Button("Collapse All Files", action: onCollapseAll)
            .fixedSize()
    }
}
