import AppKit
import SwiftUI

struct RestoreDefaultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var restore: () throws -> Void = {
        try SettingsReset.restore()
        AutoFetchScheduler.shared.reload()
        AppDelegate.applyAppearance()
        NotificationCenter.default.post(name: .settingsDidRestoreDefaults, object: nil)
    }
    var onRestored: () -> Void = {}
    @State private var isRestoring = false
    @State private var error: Error?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Restore All Default Settings?")
                    .font(.title2.weight(.semibold))
                Text("The settings below will be restored. Custom snippets and custom application entries will be replaced. Repositories, groups, names, and local files are kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(SettingsReset.groups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.title).font(.headline)
                            ForEach(group.items) { item in
                                HStack(alignment: .top, spacing: 24) {
                                    Text(item.title)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(verbatim: item.value)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRestoring)
                    .accessibilityIdentifier("cancelRestoreDefaultsButton")
                Button("Restore Defaults", role: .destructive) { confirmRestore() }
                    .disabled(isRestoring)
                    .accessibilityIdentifier("confirmRestoreDefaultsButton")
            }
            .padding(16)
        }
        .frame(width: 600, height: 620)
        .buttonStyle(.bordered)
        .errorSheet($error, operation: "Restore Defaults")
    }

    private func confirmRestore() {
        guard !isRestoring else { return }
        isRestoring = true
        do {
            try restore()
            onRestored()
            dismiss()
        } catch {
            isRestoring = false
            self.error = error
        }
    }
}
