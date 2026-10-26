import AppKit
import SwiftUI

enum ApplicationRelauncher {
    /// The helper waits for the existing PID to exit before opening the same application path.
    static func makeRestartProcess(waitingFor processIdentifier: Int32, applicationURL: URL,
                                   openerURL: URL = URL(fileURLWithPath: "/usr/bin/open")) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"""
        remaining=300
        while /bin/kill -0 "$1" 2>/dev/null; do
            if [ "$remaining" -le 0 ]; then exit 1; fi
            /bin/sleep 0.1
            remaining=$((remaining - 1))
        done
        exec "$3" "$2"
        """#, "foldgit-relaunch", String(processIdentifier), applicationURL.path, openerURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    @MainActor
    static func restart() throws {
        let process = makeRestartProcess(waitingFor: ProcessInfo.processInfo.processIdentifier,
                                         applicationURL: Bundle.main.bundleURL)
        try process.run()
        NSApp.terminate(nil)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    private let navigation = SettingsNavigation()

    static func show(tab: SettingsTab? = nil) {
        if shared == nil { shared = SettingsWindowController() }
        shared?.navigation.select(tab)
        shared?.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = String(localized: "Settings")
        window.toolbar = NSToolbar(identifier: "FoldGitSettingsToolbar")
        window.toolbarStyle = .automatic
        window.minSize = NSSize(width: 720, height: 520)
        window.setFrameAutosaveName("FoldGitSettingsWindow")
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsView(navigation: navigation))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}
