import AppKit
import RemoteCore

@main
struct NativeInputProbe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let view = TVTypingView.InputView(frame: NSRect(x: 0, y: 0, width: 288, height: 36))
        var inserted: [String] = []
        var keys: [KeyCode] = []
        var clears = 0
        var replacements: [(NSRange, String)] = []
        view.onInsert = { inserted.append($0) }
        view.onKey = { keys.append($0) }
        view.onClear = { clears += 1 }
        view.onReplace = { replacements.append(($0, $1)) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 288, height: 36), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        for (text, code) in [("h", UInt16(4)), ("m", UInt16(46)), (" ", UInt16(49))] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            view.keyDown(with: event)
        }
        precondition(inserted == ["h", "m", " "])
        precondition(keys.isEmpty)
        inserted.removeAll()
        let range = NSRange(location: NSNotFound, length: 0)
        for text in ["h", "m", " ", "/", "+", "😀", "नमस्ते"] {
            view.insertText(text, replacementRange: range)
        }
        precondition(inserted == ["h", "m", " ", "/", "+", "😀", "नमस्ते"])
        precondition(keys.isEmpty)
        view.doCommand(by: #selector(NSTextView.deleteBackward(_:)))
        view.doCommand(by: #selector(NSTextView.insertNewline(_:)))
        precondition(keys == [.deleteBackward, .enter])
        var field = TextFieldState()
        field.active = true
        field.value = "all text"
        field.cursor = 8
        field.selectionStart = 8
        view.applyContext(field)
        view.selectAll(nil)
        view.insertText("replacement", replacementRange: range)
        precondition(clears == 0)
        precondition(replacements.last?.0 == NSRange(location: 0, length: 8))
        precondition(replacements.last?.1 == "replacement")
        view.insertText("é", replacementRange: NSRange(location: 0, length: 1))
        precondition(replacements.last?.0 == NSRange(location: 0, length: 1))
        precondition(replacements.last?.1 == "é")
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: range)
        precondition(view.hasMarkedText())
        view.allSelected = true
        field.context = UUID()
        field.value = "new destination"
        field.cursor = 0
        field.selectionStart = 0
        view.applyContext(field)
        precondition(!view.hasMarkedText())
        precondition(!view.allSelected)
        precondition(view.string == "new destination")
        print("Native input probe passed: key events, Unicode, backspace, Return, replacements and composition cancellation.")
    }
}
