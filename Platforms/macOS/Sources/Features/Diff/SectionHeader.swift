import SwiftUI

struct SectionHeader: View {
    var title: LocalizedStringKey
    var fileCount: Int
    var callout: String
    
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                heading
                Spacer(minLength: 12)
                summary
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                heading
                summary
            }
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
            Text(fileCount, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.title2.bold())
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.disabled)
    }

    private var summary: some View {
        Text(callout)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
