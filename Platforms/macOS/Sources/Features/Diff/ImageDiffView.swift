import FoldGitCore
import SwiftUI

struct ImageDiffView: View {
    private let oldPath: String
    private let newPath: String
    private let oldVersion: GitFileVersion
    private let newVersion: GitFileVersion
    private let contentID: String

    init(fileDiff: FileDiff, context: ImageDiffContext) {
        oldPath = fileDiff.fromFilePath
        newPath = fileDiff.toFilePath
        oldVersion = context.version(for: fileDiff, oldSide: true)
        newVersion = context.version(for: fileDiff, oldSide: false)
        contentID = fileDiff.raw
    }

    init(untrackedPath: String) {
        oldPath = untrackedPath
        newPath = untrackedPath
        oldVersion = .absent
        newVersion = .workingTree
        contentID = untrackedPath
    }
    @Environment(\.folder) private var folder
    @Environment(\.imageDiffRefreshID) private var refreshID
    @AppStorage(PreferenceKey.diffLayout.rawValue) private var layout = DiffLayout.automatic
    @State private var viewportWidth: CGFloat = 0
    @State private var oldImage = DiffImageState.loading
    @State private var newImage = DiffImageState.loading
    @State private var zoom: CGFloat?
    @State private var oldFitZoom: CGFloat = 1
    @State private var newFitZoom: CGFloat = 1

    private var currentZoom: CGFloat { zoom ?? min(oldFitZoom, newFitZoom) }

    private var comparisonLayout: AnyLayout {
        if layout.resolved(for: viewportWidth) == .unified {
            return AnyLayout(VStackLayout(spacing: 0))
        }
        return AnyLayout(HStackLayout(alignment: .top, spacing: 0))
    }

    private struct Request: Hashable {
        let directory: URL?
        let contentID: String
        let refreshID: Int
        let oldVersion: GitFileVersion
        let newVersion: GitFileVersion
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            comparisonLayout {
                ImageDiffColumn(title: "Before", state: oldImage, zoom: currentZoom, fitZoom: $oldFitZoom)
                Divider()
                ImageDiffColumn(title: "After", state: newImage, zoom: currentZoom, fitZoom: $newFitZoom)
            }
        }
        .font(.system(.callout))
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(.vertical, 8)
        .textSelection(.disabled)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .task(id: Request(directory: folder, contentID: contentID, refreshID: refreshID, oldVersion: oldVersion, newVersion: newVersion)) {
            oldImage = .loading
            newImage = .loading
            guard let folder else { return }
            async let old = DiffImageState.load(directory: folder, path: oldPath, version: oldVersion)
            async let new = DiffImageState.load(directory: folder, path: newPath, version: newVersion)
            let results = await (old, new)
            guard !Task.isCancelled else { return }
            oldImage = results.0
            newImage = results.1
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Label("Image Comparison", systemImage: "photo.on.rectangle")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                zoomControls
            }
            zoomControls.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(10)
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button("Fit") { zoom = nil }
                .help("Fit Images to the Preview Area")
                .accessibilityAddTraits(zoom == nil ? .isSelected : [])
            Button("Actual Size") { zoom = 1 }
                .help("Show One Image Pixel per Screen Pixel")
                .accessibilityAddTraits(zoom == 1 ? .isSelected : [])
            Button {
                zoom = max(0.125, currentZoom / 2)
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass").labelStyle(.iconOnly)
            }
            .help("Zoom Out")
            .disabled(currentZoom <= 0.125)
            Text(zoom.map { Double($0).formatted(.percent.precision(.fractionLength(0))) } ?? String(localized: "Fit"))
                .monospacedDigit()
                .frame(minWidth: 42)
            Button {
                zoom = min(8, max(0.125, currentZoom * 2))
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass").labelStyle(.iconOnly)
            }
            .help("Zoom In")
            .disabled(zoom.map { $0 >= 8 } == true)
        }
        .fixedSize()
    }
}

private struct ImageDiffColumn: View {
    let title: LocalizedStringKey
    let state: DiffImageState
    let zoom: CGFloat?
    @Binding var fitZoom: CGFloat
    @Environment(\.displayScale) private var displayScale

    private var pixelSize: CGSize {
        if case .loaded(let image) = state {
            return CGSize(width: image.pixelWidth, height: image.pixelHeight)
        }
        return .zero
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.medium)
                if case .loaded(let image) = state {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            dimensions(image)
                            Text(verbatim: "·")
                            details(image)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            dimensions(image)
                            details(image)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 80, alignment: .topLeading)
            Divider()
            GeometryReader { geometry in
                ZStack {
                    ImageCheckerboard()
                    switch state {
                    case .loaded(let image):
                        let scale = ImageDiffZoom.scale(
                            pixelSize: CGSize(width: image.pixelWidth, height: image.pixelHeight),
                            viewport: geometry.size, displayScale: displayScale, zoom: zoom)
                        let width = CGFloat(image.pixelWidth) * scale
                        let height = CGFloat(image.pixelHeight) * scale
                        ScrollView([.horizontal, .vertical]) {
                            Image(decorative: image.image, scale: 1)
                                .resizable()
                                .interpolation(zoom.map { $0 > 1 } == true ? .none : .high)
                                .frame(width: width, height: height)
                                .padding(16)
                                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        }
                        .defaultScrollAnchor(.center)
                        .accessibilityLabel(title)
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .absent:
                        placeholder("No Image in This Version", systemImage: "photo")
                    case .failed(let message):
                        VStack(spacing: 8) {
                            Label("Image Preview Unavailable", systemImage: "exclamationmark.triangle")
                            Text(verbatim: message).font(.caption).textSelection(.enabled)
                        }
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                    }
                }
                .clipped()
                .onChange(of: [geometry.size, pixelSize, CGSize(width: displayScale, height: displayScale)], initial: true) { _, _ in
                    guard pixelSize.width > 0, pixelSize.height > 0 else { return }
                    fitZoom = ImageDiffZoom.scale(pixelSize: pixelSize, viewport: geometry.size,
                                                 displayScale: displayScale, zoom: nil) * displayScale
                }
            }
            .frame(height: 300)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private func dimensions(_ image: DiffImage) -> some View {
        Text(verbatim: "\(image.pixelWidth) × \(image.pixelHeight) px")
    }

    private func details(_ image: DiffImage) -> some View {
        Text(verbatim: "\(ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file)) · \(image.format)")
    }

    private func placeholder(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }
}

private struct ImageCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 12
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .textBackgroundColor)))
            var squares = Path()
            for row in 0..<Int(ceil(size.height / tile)) {
                for column in 0..<Int(ceil(size.width / tile)) where (row + column).isMultiple(of: 2) {
                    squares.addRect(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile))
                }
            }
            context.fill(squares, with: .color(.secondary.opacity(0.1)))
        }
        .accessibilityHidden(true)
    }
}
