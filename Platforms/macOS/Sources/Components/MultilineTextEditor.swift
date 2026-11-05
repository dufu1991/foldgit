import AppKit
import SwiftUI

/// A bounded plain-text editor with the same insets, wrapping and optional frame in every input surface.
struct MultilineTextEditor: View {
    /// Shared by the text container and the placeholder, so both start at the same point.
    static let inset = NSSize(width: 12, height: 8)

    @Binding var text: String
    var isFocused: Binding<Bool>? = nil
    var drawsBackground = true
    var bordered = false
    var placeholder: LocalizedStringKey? = nil
    var accessibilityIdentifier: String? = nil
    var accessibilityLabel = String(localized: "Commit Message")
    /// Tracks focus for the placeholder when the caller does not observe focus itself.
    @State private var placeholderFocus = false

    var body: some View {
        let focus = isFocused ?? (placeholder == nil ? nil : $placeholderFocus)
        let editor = MultilineTextView(
            text: $text, isFocused: focus, drawsBackground: drawsBackground,
            accessibilityIdentifier: accessibilityIdentifier, accessibilityLabel: accessibilityLabel
        )
        .overlay(alignment: .topLeading) {
            if let placeholder, text.isEmpty, focus?.wrappedValue != true {
                Text(placeholder)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Self.inset.width)
                    .padding(.top, Self.inset.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        if bordered {
            editor
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(.separator) }
        } else {
            editor
        }
    }
}

private struct MultilineTextView: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Binding<Bool>?
    var drawsBackground: Bool
    var accessibilityIdentifier: String?
    var accessibilityLabel: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MultilineEditorScrollView, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 120))
        return CGSize(width: size.width.isFinite ? size.width : 320, height: size.height.isFinite ? size.height : 120)
    }

    func makeNSView(context: Context) -> MultilineEditorScrollView {
        let scroll = MultilineEditorScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        let editor = FocusReportingTextView(usingTextLayoutManager: true)
        editor.onFocusChange = { [weak coordinator = context.coordinator] focused in coordinator?.focusDidChange(focused) }
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = MultilineTextEditor.inset
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        context.coordinator.editor = editor
        editor.delegate = context.coordinator
        scroll.documentView = editor
        configure(scroll, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: MultilineEditorScrollView, context: Context) {
        context.coordinator.parent = self
        configure(scroll, coordinator: context.coordinator)
    }

    private func configure(_ scroll: MultilineEditorScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        scroll.drawsBackground = drawsBackground
        scroll.backgroundColor = .textBackgroundColor
        editor.drawsBackground = drawsBackground
        editor.isEditable = isEnabled
        editor.isSelectable = true
        editor.setAccessibilityIdentifier(accessibilityIdentifier)
        editor.setAccessibilityLabel(accessibilityLabel)
        // Apply focus first, so text inserted together with a focus request stays undoable.
        // Only act on a new focus request, so a stale binding never pulls focus back from another control.
        if let isFocused, !coordinator.isReportingFocus, isFocused.wrappedValue != coordinator.appliedFocus,
            let window = editor.window
        {
            coordinator.appliedFocus = isFocused.wrappedValue
            if isFocused.wrappedValue && window.firstResponder !== editor { window.makeFirstResponder(editor) }
            if !isFocused.wrappedValue && window.firstResponder === editor { window.makeFirstResponder(nil) }
        }
        if editor.string != text, !editor.hasMarkedText() {
            let previousSelection = editor.selectedRange()
            let whole = NSRange(location: 0, length: editor.string.utf16.count)
            if editor.window?.firstResponder === editor, editor.shouldChangeText(in: whole, replacementString: text) {
                // Changes made while the user is editing (such as inserting a snippet) stay undoable.
                editor.replaceCharacters(in: whole, with: text)
                editor.didChangeText()
            } else {
                editor.string = text
                editor.undoManager?.removeAllActions()
            }
            editor.setSelectedRange(
                NSRange(location: min(previousSelection.location, editor.string.utf16.count), length: 0))
        }
        scroll.resizeEditor()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineTextView
        var isUpdating = false
        /// The focus state last applied to or reported by the editor.
        var appliedFocus: Bool?
        /// True while a reported focus change has not reached the binding yet.
        var isReportingFocus = false
        private let history = UndoManager()
        weak var editor: NSTextView?

        init(_ parent: MultilineTextView) {
            self.parent = parent
            super.init()
            // Undo and redo restore text without posting textDidChange, so they report through the undo manager.
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(historyDidChange), name: name, object: history)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func historyDidChange(_ notification: Notification) {
            guard !isUpdating, let editor, parent.text != editor.string else { return }
            parent.text = editor.string
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let editor = notification.object as? NSTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { history }

        /// Reported from first-responder changes, which also cover focus moves without any typing.
        func focusDidChange(_ focused: Bool) {
            appliedFocus = focused
            guard let binding = parent.isFocused, binding.wrappedValue != focused else { return }
            isReportingFocus = true
            // Defer the binding write so it never happens during a SwiftUI view update.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isReportingFocus = false
                guard self.appliedFocus == focused, self.parent.isFocused?.wrappedValue != focused else { return }
                self.parent.isFocused?.wrappedValue = focused
            }
        }
    }
}

final class FocusReportingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}

final class MultilineEditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        resizeEditor()
    }

    func resizeEditor() {
        guard let editor = documentView as? NSTextView else { return }
        let width = max(1, contentSize.width)
        if editor.frame.width != width {
            editor.setFrameSize(NSSize(width: width, height: max(editor.frame.height, contentSize.height)))
        }
        let containerSize = NSSize(
            width: max(1, width - editor.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
        if editor.textContainer?.containerSize != containerSize { editor.textContainer?.containerSize = containerSize }
        editor.minSize = NSSize(width: width, height: contentSize.height)
    }
}
