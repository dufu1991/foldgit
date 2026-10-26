import SwiftUI

struct BarBackButton: View {
    @Binding var path: [String]

    var body: some View {
        HStack {
            Button {
                path = path.dropLast()
            } label: {
                Label("Back", systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Back")
            .background(Color(NSColor.textBackgroundColor).opacity(1))
            .padding(.horizontal)
            .padding(.vertical, 8)
            Spacer()
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.98))    }
}
