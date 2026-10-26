import FoldGitCore
import SwiftUI

struct ErrorTextSheet: View {
    @Binding var error: Error?

    var body: some View {
        VStack {
            Text("Error")
                .font(.headline)
            ScrollView {
                HStack(spacing: 0) {
                    Text(error?.localizedDescription ?? "")
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }

            HStack {
                Spacer()
                Button("OK") {
                    error = nil
                }
            }
        }
        .padding()
        .cornerRadius(8)
        .frame(width: 480, height: 240)
        .background(Color(NSColor.textBackgroundColor))
    }
}

#Preview {
    @Previewable @State var error: Error? = GitExecutionError(description: "Hello")

    ErrorTextSheet(error: $error)
}

#Preview {
    @Previewable @State var error: Error? = GitExecutionError(description: """
Swift’s enumerations are well suited to represent simple errors. Create an enumeration that conforms to the Error protocol with a case for each possible error. If there are additional details about the error that could be helpful for recovery, use associated values to include that information.
The following example shows an IntParsingError enumeration that captures two different kinds of errors that can occur when parsing an integer from a string: overflow, where the value represented by the string is too large for the integer data type, and invalid input, where nonnumeric characters are found within the input.
""")

    ErrorTextSheet(error: $error)
}
