import AppKit
import RemoteCore
import SwiftUI

struct TVTypingView: NSViewRepresentable {
    let state: TextFieldState
    let insert: (String) -> Void
    let key: (KeyCode) -> Void
    let clear: () -> Void
    let replace: (NSRange, String) -> Void
    let back: () -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView(frame: .zero)
        view.font = .systemFont(ofSize: 14)
        view.textColor = .labelColor
        view.insertionPointColor = NSColor(red: 1, green: 0.353, blue: 0.122, alpha: 1)
        view.drawsBackground = false
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.maximumNumberOfLines = 1
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Type on TV")
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: InputView, context: Context) {
        view.onInsert = insert
        view.onKey = key
        view.onClear = clear
        view.onReplace = replace
        view.onBack = back
        view.applyContext(state)
        guard !view.hasMarkedText() else { return }
        if view.string != state.value { view.string = state.value }
        if !view.allSelected {
            view.setSelectedRange(state.selection)
            view.scrollRangeToVisible(view.selectedRange())
        }
    }

    final class InputView: NSTextView {
        var onInsert: ((String) -> Void)?
        var onKey: ((KeyCode) -> Void)?
        var onClear: (() -> Void)?
        var onReplace: ((NSRange, String) -> Void)?
        var onBack: (() -> Void)?
        var remoteText = ""
        var remoteCursor = 0
        var remoteSelection = NSRange(location: 0, length: 0)
        var allSelected = false
        private var context: UUID?

        func applyContext(_ state: TextFieldState) {
            if context != state.context {
                inputContext?.discardMarkedText()
                unmarkText()
                allSelected = false
                string = state.value
                context = state.context
            }
            remoteCursor = state.cursor
            remoteText = state.value
            remoteSelection = state.selection
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isKeyWindow == true else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func insertText(_ insertString: Any, replacementRange: NSRange) {
            let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
            InputDiagnostics.record("native.insert", ["units": text.utf16.count, "replacement": replacementRange.location == NSNotFound ? 0 : 1])
            guard !text.isEmpty else { return }
            let marked = markedRange()
            let replacesMarked = marked.location != NSNotFound
                && (replacementRange.location == NSNotFound
                    || (replacementRange.location >= marked.location
                        && replacementRange.location <= NSMaxRange(marked)
                        && replacementRange.length <= NSMaxRange(marked) - replacementRange.location))
            unmarkText()
            string = remoteText
            if allSelected {
                allSelected = false
                onReplace?(NSRange(location: 0, length: remoteText.utf16.count), text)
            } else if replacementRange.location != NSNotFound, !replacesMarked {
                onReplace?(replacementRange, text)
            } else {
                onInsert?(text)
            }
        }

        override func paste(_ sender: Any?) {
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        override func selectAll(_ sender: Any?) {
            allSelected = true
            super.selectAll(sender)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            allSelected = false
            setSelectedRange(remoteSelection)
        }

        override func doCommand(by selector: Selector) {
            if hasMarkedText() { super.doCommand(by: selector); return }
            let code: KeyCode?
            switch NSStringFromSelector(selector) {
            case "deleteBackward:": code = .deleteBackward
            case "deleteForward:": code = .deleteForward
            case "moveLeft:": code = .dpadLeft
            case "moveRight:": code = .dpadRight
            case "moveToBeginningOfLine:", "moveToBeginningOfDocument:": code = .moveHome
            case "moveToEndOfLine:", "moveToEndOfDocument:": code = .moveEnd
            case "insertNewline:": code = .enter
            case "cancelOperation:": onBack?(); return
            default: return
            }
            if allSelected, code == .deleteBackward || code == .deleteForward {
                allSelected = false
                onClear?()
                return
            }
            allSelected = false
            if let code { onKey?(code) }
        }
    }
}
