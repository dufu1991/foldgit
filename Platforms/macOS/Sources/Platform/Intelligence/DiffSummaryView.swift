import FoldGitCore
import FoundationModels
import SwiftUI

struct DiffSummaryView: View {
    var fileDiffs: [ExpandableModel<FileDiff>]
    @State private var summary = ""
    @State private var summaryIsResponding = false
    @State private var summaryGenerationError: Error?
    @State private var generateSummaryTask: Task<(), Never>?
    @Environment(\.systemLanguageModelAvailability) private var systemLanguageModelAvailability
    
    var body: some View {
        VStack {
            if systemLanguageModelAvailability == .available && (!summary.isEmpty || summaryIsResponding || summaryGenerationError != nil) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            HStack(spacing: 2) {
                                Image(systemName: "apple.intelligence")
                                Text("Summary")
                            }
                            .foregroundStyle(.tertiary)
                            Spacer()
                            Button {
                                generateSummaryTask?.cancel()
                                generateSummaryTask = Task {
                                    await generateSummary()
                                }
                            } label: {
                                Label("Regenerate Summary", systemImage: "arrow.clockwise")
                                    .labelStyle(.iconOnly)
                            }
                            .help("Regenerate Summary")
                            Button {
                                generateSummaryTask?.cancel()
                                summary = ""
                                summaryGenerationError = nil
                                summaryIsResponding = false
                            } label: {
                                Label("Dismiss Summary", systemImage: "xmark")
                                    .labelStyle(.iconOnly)
                            }
                            .help("Dismiss Summary")
                        }
                        .padding(.top)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.callout)
                        if summaryGenerationError != nil {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                Text(summaryGenerationError?.localizedDescription ?? "")
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                        }
                        if summaryIsResponding && summary.isEmpty {
                            ProgressView()
                                .scaleEffect(x: 0.4, y: 0.4, anchor: .leading)
                                .frame(height: 16)
                                .padding(.leading, 1)
                        }
                        if !summary.isEmpty {
                            Text(summary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
        }
        .onChange(of: fileDiffs.map { $0.model }, initial: true) {
            generateSummaryTask?.cancel()
            generateSummaryTask = Task {
                await generateSummary()
            }
        }
    }
    
    private func generateSummary() async {
        summary = ""
        summaryIsResponding = true
        summaryGenerationError = nil
        do {
            let diffRaw = fileDiffs.map { fileDiff in
                    fileDiff.model.raw
                }.joined(separator: "\n")
            if !diffRaw.isEmpty {
                 let stream = IntelligenceClient().diffSummary(diffRaw)
                for try await text in stream {
                    if !Task.isCancelled {
                        summary = text.content.summary ?? ""
                    }
                }
            }
        } catch {
            if !Task.isCancelled {
                summaryGenerationError = error
            }
        }
        summaryIsResponding = false
    }

}
