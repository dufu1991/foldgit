import AppKit
import FoldGitCore
import SwiftUI

struct CommandLogPanel: View {
    let directory: URL
    @Binding var isPresented: Bool
    @Binding var selectedID: UUID?
    @State private var expandedID: UUID?
    @State private var entries: [GitCommandLogEntry] = []
    @State private var searchText = ""
    @State private var onlyFailures = false
    @State private var includeReads = false
    @State private var error: Error?

    private var visibleEntries: [GitCommandLogEntry] {
        CommandLogPresentation.filtered(entries, search: searchText, onlyFailures: onlyFailures, includeReads: includeReads)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 8) {
                TextField("Search Commands", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("commandLogSearch")
                Menu {
                    Toggle("Only Failures", isOn: $onlyFailures)
                    Toggle("Include Read Commands", isOn: $includeReads)
                } label: {
                    Image(systemName: onlyFailures || !includeReads ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter Commands")
                Menu {
                    Button("Copy Log") { CommandLogPresentation.copy(CommandLogPresentation.transcript(visibleEntries)) }
                        .disabled(visibleEntries.isEmpty)
                    Button("Export Log", action: export)
                        .disabled(visibleEntries.isEmpty)
                    Divider()
                    Button("Clear Log") { Task { await GitCommandLog.shared.clear(in: directory) } }
                        .disabled(!entries.contains { $0.status != .running })
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Log Actions")
            }
            .padding(12)
            Divider()
            if visibleEntries.isEmpty {
                ContentUnavailableView {
                    Label(entries.isEmpty ? "No Commands" : "No Matching Commands", systemImage: "terminal")
                } description: {
                    Text(entries.isEmpty ? "Git commands for this repository appear here." : "Try another search or change the filters.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleEntries) { entry in
                                CommandLogRow(entry: entry, isExpanded: Binding(
                                    get: { expandedID == entry.id },
                                    set: { expandedID = $0 ? entry.id : nil }
                                ))
                                .id(entry.id)
                                Divider()
                            }
                        }
                    }
                    .onChange(of: expandedID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .top) }
                    }
                    .onChange(of: entries.contains { $0.id == selectedID }) { _, available in
                        if available, let id = selectedID { proxy.scrollTo(id, anchor: .top) }
                    }
                }
            }
            Divider()
            Text("Logs are kept for this session. Older entries and long output are limited.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commandLogPanel")
        .task(id: directory) {
            for await records in await GitCommandLog.shared.updates(in: directory) {
                guard !Task.isCancelled else { return }
                entries = records
            }
        }
        .onChange(of: selectedID, initial: true) {
            // A failure opened from an error sheet must remain visible regardless of previous filters.
            if let selectedID {
                searchText = ""
                onlyFailures = false
                includeReads = true
                expandedID = selectedID
            }
        }
        .errorSheet($error, operation: "Export Command Log")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark") { isPresented = false }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                    .accessibilityIdentifier("closeCommandLog")
            }
            Text(verbatim: directory.lastPathComponent)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(directory.path)
        }
        .padding(12)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(directory.lastPathComponent)-git.log"
        let text = CommandLogPresentation.transcript(visibleEntries)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = error }
        }
    }
}

/// Covers the workspace without participating in its column layout.
struct CommandLogOverlay: View {
    let directory: URL
    @Binding var isPresented: Bool
    @Binding var selectedID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                if isPresented {
                    Color.black.opacity(0.025)
                        .contentShape(Rectangle())
                        .onTapGesture { isPresented = false }
                        .accessibilityHidden(true)
                        .transition(.opacity)

                    CommandLogPanel(directory: directory, isPresented: $isPresented, selectedID: $selectedID)
                        .frame(width: min(460, max(0, geometry.size.width - 24)), height: max(0, geometry.size.height - 24))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                                .allowsHitTesting(false)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 6)
                        .padding(12)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .offset(x: 32).combined(with: .opacity),
                            removal: .offset(x: 24).combined(with: .opacity)
                        ))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(reduceMotion ? nil : isPresented ? .easeOut(duration: 0.24) : .easeIn(duration: 0.16), value: isPresented)
        }
        .allowsHitTesting(isPresented)
    }
}

private struct CommandLogRow: View {
    let entry: GitCommandLogEntry
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Copy Command") { CommandLogPresentation.copy(entry.command) }
                    Button("Copy Log") { CommandLogPresentation.copy(CommandLogPresentation.transcript([entry])) }
                }
                .controlSize(.small)
                if let code = entry.exitCode {
                    LabeledContent("Exit Code") { Text(verbatim: String(code)).monospacedDigit() }
                }
                Text(verbatim: entry.directory.path)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                output(entry.standardOutput, title: "Standard Output")
                output(entry.standardError, title: "Standard Error")
                if let failure = entry.failure {
                    Text(verbatim: failure).foregroundStyle(.red).textSelection(.enabled)
                }
                if entry.status != .running, entry.failure == nil,
                   entry.standardOutput?.byteCount == 0, entry.standardError?.byteCount == 0 {
                    Text("No Output").foregroundStyle(.secondary)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if entry.status == .running {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: entry.status == .succeeded ? "checkmark.circle" : entry.isFailure ? "exclamationmark.circle" : "minus.circle")
                            .foregroundStyle(entry.isFailure ? .red : .secondary)
                    }
                    Text(entry.status.title)
                    Spacer(minLength: 0)
                    Text(entry.startedAt, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(verbatim: entry.command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(isExpanded ? nil : 2)
                    .textSelection(.enabled)
                if let duration = entry.duration {
                    Text(verbatim: CommandLogPresentation.duration(duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .padding(12)
        .contextMenu {
            Button("Copy Command") { CommandLogPresentation.copy(entry.command) }
            Button("Copy Log") { CommandLogPresentation.copy(CommandLogPresentation.transcript([entry])) }
        }
    }

    @ViewBuilder private func output(_ output: GitCommandLogEntry.Output?, title: LocalizedStringKey) -> some View {
        if let output, output.byteCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.semibold))
                if output.isBinary {
                    Text("Binary output (\(output.byteCount) bytes)").foregroundStyle(.secondary)
                } else {
                    Text(verbatim: output.text).textSelection(.enabled)
                    if output.isTruncated { Text("Output Truncated").foregroundStyle(.secondary) }
                }
            }
        }
    }
}

enum CommandLogPresentation {
    static func filtered(_ entries: [GitCommandLogEntry], search: String, onlyFailures: Bool, includeReads: Bool) -> [GitCommandLogEntry] {
        entries.filter { entry in
            (!onlyFailures || entry.isFailure) && (includeReads || !entry.isReadOnly)
                && (search.isEmpty || [entry.command, entry.standardOutput?.text, entry.standardError?.text, entry.failure]
                    .compactMap { $0 }.contains { $0.localizedStandardContains(search) })
        }
    }

    static func duration(_ value: TimeInterval) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " s"
    }

    static func transcript(_ entries: [GitCommandLogEntry]) -> String {
        entries.map { entry in
            var lines = [entry.startedAt.ISO8601Format(), entry.directory.path, "$ " + entry.command, entry.status.title]
            if let time = entry.duration { lines.append(String(localized: "Duration") + "  " + duration(time)) }
            if let code = entry.exitCode { lines.append(String(localized: "Exit Code") + "  \(code)") }
            for (title, output) in [(String(localized: "Standard Output"), entry.standardOutput), (String(localized: "Standard Error"), entry.standardError)] {
                guard let output, output.byteCount > 0 else { continue }
                lines.append(title)
                lines.append(output.isBinary ? String(localized: "Binary output (\(output.byteCount) bytes)") : output.text)
                if output.isTruncated { lines.append(String(localized: "Output Truncated")) }
            }
            if let failure = entry.failure { lines.append(failure) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension GitCommandLogEntry.Status {
    var title: String {
        switch self {
        case .running: String(localized: "Running")
        case .succeeded: String(localized: "Succeeded")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        case .timedOut: String(localized: "Timed Out")
        }
    }
}
