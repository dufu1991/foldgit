import SwiftUI

struct AuthorInitialIcon: View {
    var initial: String
    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color(white: 0.70), Color(white: 0.50)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Text(initial)
                .fontDesign(.rounded)
                .foregroundColor(.white)
                .textSelection(.disabled)
        }
    }
}

#Preview {
    AuthorInitialIcon(initial: "A")
        .frame(width: 40, height: 40)
}

#Preview {
    AuthorInitialIcon(initial: "AA")
        .frame(width: 40, height: 40)
}

#Preview {
    AuthorInitialIcon(initial: "AAAAAAAAA")
        .frame(width: 40, height: 40)
}
