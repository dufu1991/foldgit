import AppKit
import SwiftUI

/// A native search field whose editor distinguishes marked text from committed input.
/// The binding only receives committed text; `onChange` also reports input method composition.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityIdentifier: String
    var focusRequest: UUID?
    var onChange: (String, Bool) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = MarkedTextSearchField()
        let cell = field.cell as! MarkedTextSearchCell
        field.isEditable = true
        field.isSelectable = true
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        cell.searchEditor.onChange = { [weak coordinator = context.coordinator] in coordinator?.publish() }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let editor = field.currentEditor() as? MarkedTextSearchEditor
        if editor?.isComposing != true && field.stringValue != text { field.stringValue = text }
        if let focusRequest, coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        weak var field: NSSearchField?
        var lastFocusRequest: UUID?
        private var lastValue = ""
        private var lastComposing = false

        init(_ parent: NativeSearchField) { self.parent = parent; lastFocusRequest = parent.focusRequest }
        func controlTextDidChange(_ notification: Notification) { publish() }
        func controlTextDidEndEditing(_ notification: Notification) { publish() }
        @objc func search(_ sender: NSSearchField) { publish() }

        func publish() {
            guard let field else { return }
            let editor = field.currentEditor() as? MarkedTextSearchEditor
            guard editor?.isInsertingText != true else { return }
            let composing = editor?.isComposing == true
            let value = editor?.string ?? field.stringValue
            guard value != lastValue || composing != lastComposing else { return }
            lastValue = value
            lastComposing = composing
            if !composing { parent.text = value }
            parent.onChange(value, composing)
        }
    }
}

@MainActor
final class MarkedTextSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { MarkedTextSearchCell.self }
        set { super.cellClass = newValue }
    }
}

@MainActor
final class MarkedTextSearchCell: NSSearchFieldCell {
    let searchEditor = MarkedTextSearchEditor()
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        searchEditor.isFieldEditor = true
        return searchEditor
    }
}

@MainActor
final class MarkedTextSearchEditor: NSTextView {
    var onChange: (() -> Void)?
    private var updatingMarkedText = false
    private(set) var isInsertingText = false
    var isComposing: Bool { updatingMarkedText || hasMarkedText() }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        updatingMarkedText = true
        onChange?()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        updatingMarkedText = false
        onChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onChange?()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        isInsertingText = true
        super.insertText(string, replacementRange: replacementRange)
        isInsertingText = false
        onChange?()
    }
}
