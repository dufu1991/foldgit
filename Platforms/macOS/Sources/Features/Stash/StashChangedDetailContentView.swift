import FoldGitCore
import SwiftUI

struct StashChangedDetailContentView: View {
    @Binding var fileDiffs: [ExpandableModel<FileDiff>]

    var body: some View {
        VStack {
            FileDiffsView(expandableFileDiffs: $fileDiffs)
                    .padding()
        }
        .textSelection(.enabled)
    }
}

