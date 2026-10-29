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
    var changeFileLayout: Binding<ChangeFileLayout>? = nil
    var onExpandDirectories: (() -> Void)? = nil
    var onCollapseDirectories: (() -> Void)? = nil
    var onExpandAll: () -> Void
    var onCollapseAll: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                if let changeFileLayout {
                    ChangeFileLayoutPicker(layout: changeFileLayout)
                }
                DiffLayoutPicker()
                fileControls
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                if let changeFileLayout {
                    ChangeFileLayoutPicker(layout: changeFileLayout)
                }
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
                HStack(spacing: 16) {
                    directoryButtons
                    diffButtons
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    directoryButtons
                    diffButtons
                }
            }
        }
    }

    @ViewBuilder
    private var directoryButtons: some View {
        if changeFileLayout?.wrappedValue == .tree,
           let onExpandDirectories, let onCollapseDirectories {
            ExpansionButtonPair(expandTitle: "Expand Directories", collapseTitle: "Collapse Directories",
                                identifier: "Directories", onExpand: onExpandDirectories, onCollapse: onCollapseDirectories)
        }
    }

    private var diffButtons: some View {
        ExpansionButtonPair(expandTitle: "Expand Diffs", collapseTitle: "Collapse Diffs",
                            identifier: "Diffs", onExpand: onExpandAll, onCollapse: onCollapseAll)
    }
}

private struct ExpansionButtonPair: View {
    var expandTitle: LocalizedStringKey
    var collapseTitle: LocalizedStringKey
    var identifier: String
    var onExpand: () -> Void
    var onCollapse: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
    }

    private var buttons: some View {
        Group {
            Button(expandTitle, action: onExpand)
                .accessibilityIdentifier("expand" + identifier + "Button")
            Button(collapseTitle, action: onCollapse)
                .accessibilityIdentifier("collapse" + identifier + "Button")
        }
        .fixedSize()
    }
}
