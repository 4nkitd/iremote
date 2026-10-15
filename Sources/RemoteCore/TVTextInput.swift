import Foundation

public struct TextFieldState: Equatable {
    public var active = false
    public var value = ""
    public var selectionStart = 0
    public var cursor = 0
    public var label = ""
    public var context = UUID()

    public init() {}

    public var selection: NSRange {
        NSRange(location: min(selectionStart, cursor), length: abs(cursor - selectionStart))
    }
}

final class TVTextInput {
    private enum Edit {
        case insert(String)
        case key(KeyCode)
    }

    private(set) var state = TextFieldState()
    private var appCounter: Int?
    private var fieldID = 0
    private var edits: [Edit] = []
    private var expected: TextFieldState?
    private var scheduled: DispatchWorkItem?
    private var blocked = false
    private var awaitingContext = false
    private let send: (ProtoWriter) -> Void
    private let changed: (TextFieldState) -> Void
    private let failed: (String) -> Void

    init(send: @escaping (ProtoWriter) -> Void, changed: @escaping (TextFieldState) -> Void, failed: @escaping (String) -> Void) {
        self.send = send
        self.changed = changed
        self.failed = failed
    }

    func reset() {
        stop()
        appCounter = nil
        fieldID = 0
        state = TextFieldState()
        changed(state)
    }

    private func stop() {
        edits.removeAll()
        scheduled?.cancel()
        scheduled = nil
        expected = nil
        blocked = false
        awaitingContext = false
    }

    func cancelPending() {
        edits.removeAll()
    }

    func receive(_ message: ProtoMessage) {
        if let inject = message.message(20) {
            InputDiagnostics.record("receive.ime", ["appPresent": inject.has(1) ? 1 : 0, "app": inject.message(1)?.int(1) ?? -1, "fieldPresent": inject.has(2) ? 1 : 0])
            stop()
            state.context = UUID()
            if let app = inject.message(1) { appCounter = app.int(1) }
            update(inject.message(2))
        } else if !awaitingContext, let show = message.message(22) {
            InputDiagnostics.record("receive.show")
            update(show.message(2))
        } else if let batch = message.message(21) {
            InputDiagnostics.record("receive.batch", ["app": batch.int(1), "field": batch.int(2)])
        }
    }

    private func update(_ field: ProtoMessage?) {
        if let field {
            InputDiagnostics.record("receive.field", ["app": appCounter ?? -1, "id": field.int(1), "start": field.int(3), "end": field.int(4), "startPresent": field.has(3) ? 1 : 0, "endPresent": field.has(4) ? 1 : 0, "units": field.string(2).utf16.count])
        }
        guard let field, field.uint(1) <= UInt64(Int32.max),
              let appCounter, appCounter >= 0, appCounter <= Int(Int32.max), field.string(2).utf16.count <= 65536 else {
            // A field can disappear without the app changing. Keep the app counter for a
            // later RemoteImeShowRequest, which does not repeat the app information.
            stop()
            fieldID = 0
            state = TextFieldState()
            changed(state)
            InputDiagnostics.record("field.rejected")
            return
        }
        var report = state
        report.active = true
        report.value = field.string(2)
        report.label = String(field.string(6).prefix(120))
        report.selectionStart = max(0, min(field.int(3), report.value.utf16.count))
        report.cursor = max(0, min(field.int(4), report.value.utf16.count))
        if let expected {
            // A counter advance alone can be a delayed response to an earlier key. Require
            // the actual text and selection to match this operation before advancing.
            guard report.value == expected.value, report.selection == expected.selection else {
                InputDiagnostics.record("echo.mismatch", ["valueEqual": report.value == expected.value ? 1 : 0, "selectionEqual": report.selection == expected.selection ? 1 : 0])
                return
            }
            self.expected = nil
            scheduled?.cancel()
            scheduled = nil
        }
        fieldID = field.int(1)
        blocked = false
        state = report
        InputDiagnostics.record("field.accepted", ["app": appCounter, "id": fieldID])
        changed(state)
        pump()
    }

    func insert(_ text: String) {
        InputDiagnostics.record("insert.request", ["active": state.active ? 1 : 0, "blocked": blocked ? 1 : 0, "units": text.utf16.count])
        guard !text.isEmpty, readyForInput(), validText(text) else { return }
        guard edits.count < 32 else { failed("The TV is catching up. Wait before typing more."); return }
        if case .insert(let tail)? = edits.last, tail.utf16.count + text.utf16.count <= 4096 {
            edits[edits.count - 1] = .insert(tail + text)
        } else {
            edits.append(.insert(text))
        }
        pump()
    }

    func key(_ key: KeyCode) {
        let allowed: Set<KeyCode> = [.deleteBackward, .deleteForward, .dpadLeft, .dpadRight, .moveHome, .moveEnd, .enter]
        guard allowed.contains(key), readyForInput(), edits.count < 32 else { return }
        edits.append(.key(key))
        pump()
    }

    func clear() {
        replace(NSRange(location: 0, length: state.value.utf16.count), with: "")
    }

    func replace(_ range: NSRange, with text: String) {
        guard readyForInput(), validText(text) else { return }
        guard expected == nil, edits.isEmpty else { failed("Wait for the TV to confirm the last edit before replacing text."); return }
        let count = state.value.utf16.count
        guard range.location >= 0, range.length >= 0, range.location <= count,
              range.length <= count - range.location,
              let start = boundary(range.location), let end = boundary(range.location + range.length) else {
            failed("The selection changed. Select the text again.")
            return
        }
        let distance = state.value[..<end].count
        let deletes = state.value[start..<end].count
        guard state.value.count <= 500 else {
            failed("Replacing text supports fields up to 500 characters.")
            return
        }
        guard !text.isEmpty || range.length > 0 else { return }
        // Validate the entire replacement before issuing any cursor moves or deletions.
        if range == state.selection {
            if text.isEmpty { edits = [.key(.deleteBackward)] }
            else { edits = [.insert(text)] }
        } else {
            if state.selection.length == 0, state.cursor == range.location + range.length {
                edits = []
            } else if range.location + range.length == count {
                edits = [.key(.moveEnd)]
            } else {
                edits = [.key(.moveHome)] + Array(repeating: .key(.dpadRight), count: distance)
            }
            edits += Array(repeating: .key(.deleteBackward), count: deletes)
            if !text.isEmpty { edits.append(.insert(text)) }
        }
        pump()
    }

    private func validText(_ text: String) -> Bool {
        guard text.utf16.count <= 4096 else { failed("Paste up to 4,096 UTF-16 units at a time."); return false }
        return true
    }

    private func readyForInput() -> Bool {
        guard state.active else { failed("Open a text field on the TV first."); return false }
        guard !blocked else { failed("Waiting for the TV. Refocus its text field to continue."); return false }
        return true
    }

    private func pump() {
        guard state.active, !blocked, expected == nil, !edits.isEmpty else { return }
        let edit = edits.removeFirst()
        var w = ProtoWriter()
        let before = state
        switch edit {
        case .insert(let value):
            let range = state.selection
            guard let lower = boundary(range.location), let upper = boundary(range.location + range.length) else {
                stop(); failed("The TV reported an invalid cursor position."); return
            }
            let cursor = range.location + value.utf16.count
            w.message(21) { batch in
                batch.int(1, appCounter ?? 0)
                batch.int(2, fieldID)
                batch.message(3) { edit in
                    edit.int(1, 1)
                    edit.message(2) { text in
                        text.int(1, cursor)
                        text.int(2, cursor)
                        text.string(3, value)
                    }
                }
            }
            state.value.replaceSubrange(lower..<upper, with: value)
            state.cursor = cursor
            state.selectionStart = cursor
        case .key(let key):
            w.message(10) { keyMessage in keyMessage.int(1, key.rawValue); keyMessage.int(2, 3) }
            if key == .enter {
                edits.removeAll()
                awaitingContext = true
                state.active = false
                state.context = UUID()
                changed(state)
                send(w)
                return
            }
            apply(key)
        }
        if state.value == before.value, state.selection == before.selection { pump(); return }
        expected = state
        changed(state)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.expected = nil
            self.scheduled = nil
            self.edits.removeAll()
            self.blocked = true
            InputDiagnostics.record("edit.timeout")
            self.failed("The TV hasn't confirmed this edit. Refocus its text field to continue.")
        }
        scheduled = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
        send(w)
    }

    private func boundary(_ offset: Int) -> String.Index? {
        guard offset >= 0, offset <= state.value.utf16.count else { return nil }
        var units = 0
        for index in state.value.indices {
            if units == offset { return index }
            units += String(state.value[index]).utf16.count
            if units > offset { return nil }
        }
        return offset == units ? state.value.endIndex : nil
    }

    private func apply(_ key: KeyCode) {
        let selection = state.selection
        if selection.length > 0 {
            if key == .deleteBackward || key == .deleteForward,
               let lower = boundary(selection.location), let upper = boundary(selection.location + selection.length) {
                state.value.removeSubrange(lower..<upper)
                state.cursor = selection.location
                state.selectionStart = state.cursor
                return
            }
            if key == .dpadLeft || key == .dpadRight {
                state.cursor = key == .dpadLeft ? selection.location : selection.location + selection.length
                state.selectionStart = state.cursor
                return
            }
        }
        guard let at = boundary(state.cursor) else { return }
        switch key {
        case .deleteBackward, .dpadLeft:
            guard at > state.value.startIndex else { return }
            let before = state.value.index(before: at)
            state.cursor = state.value[..<before].utf16.count
            if key == .deleteBackward { state.value.removeSubrange(before..<at) }
        case .deleteForward:
            guard at < state.value.endIndex else { return }
            state.value.removeSubrange(at..<state.value.index(after: at))
        case .dpadRight:
            guard at < state.value.endIndex else { return }
            state.cursor = state.value[..<state.value.index(after: at)].utf16.count
        case .moveHome: state.cursor = 0
        case .moveEnd: state.cursor = state.value.utf16.count
        default: break
        }
        state.selectionStart = state.cursor
    }
}
