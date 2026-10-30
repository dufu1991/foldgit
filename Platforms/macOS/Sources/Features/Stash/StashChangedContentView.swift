import FoldGitCore
import SwiftUI

struct StashChangedContentView: View {
    @AppStorage(PreferenceKey.diffFileExpansion.rawValue) private var fileExpansion = AppPreferences.defaultDiffFileExpansion
    
    var folder: WorkspaceEntry
    @Binding var showingStashChanged: Bool
    var stashList: [Stash]?
    var onTapDropButton: ((Stash) -> Void)?
    @State private var selectionStashID: Int?
    @State private var fileDiffs: [ExpandableModel<FileDiff>] = []
    @State private var error: Error?
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectionStashID) {
                Text("Stashed Changes")
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(2)
                if let stashList {
                    if stashList.isEmpty {
                        Text("No Content")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        ForEach(stashList) { stash in
                            Text(stash.message)
                                .lineLimit(3)
                                .contextMenu {
                                    Button("Drop") {
                                        onTapDropButton?(stash)
                                        selectionStashID = nil
                                    }
                                }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            Group {
                if selectionStashID != nil {
                    ScrollView {
                        VStack(spacing: 0) {
                            StashChangedDetailContentView(fileDiffs: $fileDiffs)
                                .environment(\.folder, folder.url)
                                .environment(\.imageDiffContext, selectionStashID.map {
                                    ImageDiffContext(old: .revision("stash@{\($0)}^1"), new: .revision("stash@{\($0)}"))
                                })
                            Spacer(minLength: 0)
                        }
                    }
                    .scrollEdgeEffectStyle(.hard, for: .vertical)
                } else {
                    Text("No Selection")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaBar(edge: .bottom, content: {
                VStack (spacing: 0) {
                    PixelDivider()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            displayControls
                            Spacer(minLength: 12)
                            stashActions
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 10) {
                            displayControls
                            HStack {
                                Spacer()
                                stashActions
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding()
                }
            })
        }
        .background(Color(NSColor.textBackgroundColor))
        .task(id: selectionStashID, {
            await updateDiff()
        })
        .presentationSizing(.fitted)
        .frame(
            minWidth: 650,
            idealWidth: 800,
            maxWidth: .infinity,
            minHeight: 500,
            idealHeight: 700,
            maxHeight: .infinity
        )
        .errorSheet($error, operation: "Load Stash Changes")
    }

    private var displayControls: some View {
        DiffDisplayControls(onExpandAll: {
            fileDiffs = fileDiffs.settingExpansion(true)
        }, onCollapseAll: {
            fileDiffs = fileDiffs.settingExpansion(false)
        })
    }

    private var stashActions: some View {
        HStack(spacing: 8) {
            Button("Cancel") { showingStashChanged = false }
            Button("Apply") {
                Task {
                    do {
                        try await GitRuntime.run(GitStashApply(directory: folder.url, index: selectionStashID!))
                        showingStashChanged = false
                    } catch {
                        self.error = OperationFailure("Apply Stash", error)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.init(.defaultAction))
            .disabled(selectionStashID == nil)
        }
        .fixedSize()
    }

    private func updateDiff() async {
        do {
            if let index = selectionStashID {
                let diff = try await GitRuntime.run(GitStashShowDiff(directory: folder.url, index: index))
                fileDiffs = try Diff(raw: diff).fileDiffs.map { ExpandableModel(isExpanded: fileExpansion.isExpanded, model: $0) }
            } else {
                fileDiffs = []
            }
        } catch {
            self.error = OperationFailure("Load Stash Changes", error)
        }
    }
    

}

#Preview {
    @Previewable @State var showingStashChanged = false
    return StashChangedContentView(folder: .init(url: URL(string: "file:///tmp/FoldGit/")!), showingStashChanged: $showingStashChanged)
}
