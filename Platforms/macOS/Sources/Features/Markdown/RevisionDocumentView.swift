import FoldGitCore
import SwiftUI

struct RevisionDocumentView: View {
    let directory: URL
    let version: GitFileVersion
    @State var path: String
    @Environment(\.dismiss) private var dismiss
    @State private var document: FileContentDocument?
    @State private var failure: String?
    @State private var history = [String]()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !history.isEmpty {
                    Button { path = history.removeLast() } label: { Image(systemName: "chevron.backward") }
                        .accessibilityLabel(Text("Back"))
                }
                Text(verbatim: path).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            if let failure {
                ContentUnavailableView { Label("Cannot Preview File", systemImage: "doc") } description: { Text(verbatim: failure) }
            } else if let document, let kind = PreviewDocumentKind(path: path) {
                MarkdownPreview(document: document, kind: kind, location: .init(directory: directory, path: path, version: version)) {
                    history.append(path)
                    path = $0
                }.id(document.id)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 480, idealWidth: 760, minHeight: 320, idealHeight: 560)
        .task(id: path) {
            document = nil
            failure = nil
            do {
                guard let data = try await GitFileContent.read(at: directory, path: path, version: version,
                                                              maximumBytes: FileContentReader.automaticLimit),
                      case let .text(source, plain, layout) = try FileContentReader.decode(data, plain: false) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                try Task.checkCancellation()
                document = .init(text: source, plain: plain, layout: layout)
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}
