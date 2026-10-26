import SwiftUI

struct PixelDivider: View {
    @Environment(\.pixelLength) private var pixelLength

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: pixelLength)
            .accessibilityHidden(true)
    }
}

struct FileDiffDivider: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.2))
            .frame(height: 1)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
    }
}
