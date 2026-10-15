import Foundation
@testable import RemoteCore
import XCTest

final class VolumeTests: XCTestCase {
    func testOneCommandInFlightAndRepeatedTargetsDoNotOvershoot() {
        var stepper = VolumeStepper()
        XCTAssertNil(stepper.receive(VolumeInfo(level: 18, max: 100, muted: false)))
        XCTAssertEqual(stepper.setTarget(0.50), .volumeUp)
        XCTAssertNil(stepper.setTarget(0.50))
        XCTAssertNil(stepper.receive(VolumeInfo(level: 18, max: 100, muted: false)))
        for level in 19..<50 {
            XCTAssertEqual(stepper.receive(VolumeInfo(level: level, max: 100, muted: false)), .volumeUp)
            XCTAssertNil(stepper.setTarget(0.50))
        }
        XCTAssertNil(stepper.receive(VolumeInfo(level: 50, max: 100, muted: false)))
        XCTAssertNil(stepper.setTarget(0.50))
    }

    func testInvalidReportsAreIgnored() throws {
        for (maximum, level) in [(0, 0), (1, Int.max), (Int.max, 1), (100, -1)] {
            var w = ProtoWriter()
            w.int(6, maximum)
            w.int(7, level)
            XCTAssertNil(VolumeInfo.decode(try ProtoMessage(w.data)))
        }
        var stepper = VolumeStepper()
        XCTAssertNil(stepper.receive(VolumeInfo(level: Int.max, max: 1, muted: false)))
        XCTAssertNil(stepper.setTarget(.infinity))
    }

    func testCancellationStopsPendingTarget() {
        var stepper = VolumeStepper()
        _ = stepper.receive(VolumeInfo(level: 10, max: 100, muted: false))
        XCTAssertEqual(stepper.setTarget(0.9), .volumeUp)
        stepper.cancel()
        XCTAssertNil(stepper.receive(VolumeInfo(level: 11, max: 100, muted: false)))
    }
}

final class TextInputTests: XCTestCase {
    func testAppCounterSurvivesSeparateFocusAnnouncementIncludingZero() throws {
        for counter in [0, 7] {
            var sent: [ProtoMessage] = []
            let input = TVTextInput(send: { sent.append(try! ProtoMessage($0.data)) }, changed: { _ in }, failed: { XCTFail($0) })
            var app = ProtoWriter()
            app.message(20) { $0.message(1) { $0.int(1, counter) } }
            input.receive(try ProtoMessage(app.data))
            XCTAssertFalse(input.state.active)
            input.receive(try field(id: 0, text: "", cursor: 0))
            XCTAssertTrue(input.state.active)
            input.insert("a")
            XCTAssertEqual(sent.first?.message(21)?.int(1), counter)
            XCTAssertEqual(sent.first?.message(21)?.int(2), 0)
            input.reset()
        }
    }
    private func field(id: Int, text: String, cursor: Int, focus: Bool = false) throws -> ProtoMessage {
        var w = ProtoWriter()
        w.message(focus ? 20 : 22) { envelope in
            if focus { envelope.message(1) { $0.int(1, 7) } }
            envelope.message(2) { f in
                f.int(1, id)
                f.string(2, text)
                f.int(3, cursor)
                f.int(4, cursor)
                f.string(6, "Search")
            }
        }
        return try ProtoMessage(w.data)
    }

    func testUnicodeEditsWaitForEchoAndUseAppAndFieldCounters() throws {
        var sent: [ProtoMessage] = []
        let input = TVTextInput(send: { sent.append(try! ProtoMessage($0.data)) }, changed: { _ in }, failed: { XCTFail($0) })
        input.receive(try field(id: 4, text: "a", cursor: 1, focus: true))
        input.insert("😀")
        input.insert("h m / +")
        XCTAssertEqual(sent.count, 1)
        let batch = try XCTUnwrap(sent.first?.message(21))
        XCTAssertEqual(batch.int(1), 7)
        XCTAssertEqual(batch.int(2), 4)
        XCTAssertEqual(batch.message(3)?.message(2)?.int(1), 3)
        XCTAssertEqual(batch.message(3)?.message(2)?.string(3), "😀")
        input.receive(try field(id: 5, text: "a😀", cursor: 3))
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].message(21)?.int(2), 5)
        XCTAssertEqual(sent[1].message(21)?.message(3)?.message(2)?.string(3), "h m / +")
        input.reset()
    }

    func testNoFieldAndLostFocusNeverSendText() throws {
        var count = 0
        let input = TVTextInput(send: { _ in count += 1 }, changed: { _ in }, failed: { _ in })
        input.insert("secret")
        XCTAssertEqual(count, 0)
        input.receive(try field(id: 1, text: "", cursor: 0, focus: true))
        input.insert("first")
        input.insert("queued")
        var lost = ProtoWriter()
        lost.message(20) { $0.message(1) { $0.int(1, 8) } }
        input.receive(try ProtoMessage(lost.data))
        XCTAssertFalse(input.state.active)
        input.insert("not sent")
        XCTAssertEqual(count, 1)
    }

    func testBackspaceAfterUnicodeUsesUTF16Cursor() throws {
        let input = TVTextInput(send: { _ in }, changed: { _ in }, failed: { XCTFail($0) })
        input.receive(try field(id: 1, text: "a😀", cursor: 3, focus: true))
        input.key(.deleteBackward)
        XCTAssertEqual(input.state.value, "a")
        XCTAssertEqual(input.state.cursor, 1)
        input.reset()
    }

    func testCancelledQueueDoesNotSendToLaterField() throws {
        var count = 0
        let input = TVTextInput(send: { _ in count += 1 }, changed: { _ in }, failed: { _ in })
        input.receive(try field(id: 1, text: "", cursor: 0, focus: true))
        input.insert("one")
        input.insert("two")
        input.cancelPending()
        input.receive(try field(id: 2, text: "one", cursor: 3))
        XCTAssertEqual(count, 1)
        input.reset()
    }

    func testUnconfirmedInsertionTimesOutWithoutRetry() throws {
        var count = 0
        let timeout = expectation(description: "timeout")
        let input = TVTextInput(send: { _ in count += 1 }, changed: { _ in }, failed: { _ in timeout.fulfill() })
        input.receive(try field(id: 1, text: "", cursor: 0, focus: true))
        input.insert("one")
        input.insert("two")
        wait(for: [timeout], timeout: 3)
        XCTAssertEqual(count, 1)
        input.reset()
    }

    func testDelayedBackspaceEchoCannotAcknowledgeFollowingInsertion() throws {
        var sent: [ProtoMessage] = []
        let input = TVTextInput(send: { sent.append(try! ProtoMessage($0.data)) }, changed: { _ in }, failed: { XCTFail($0) })
        input.receive(try field(id: 1, text: "ab", cursor: 2, focus: true))
        input.key(.deleteBackward)
        input.insert("X")
        input.insert("Y")
        let delayed = expectation(description: "slow TV")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { delayed.fulfill() }
        wait(for: [delayed], timeout: 1)
        XCTAssertEqual(sent.count, 1)
        input.receive(try field(id: 2, text: "a", cursor: 1))
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].message(21)?.int(2), 2)
        XCTAssertEqual(sent[1].message(21)?.message(3)?.message(2)?.string(3), "XY")
        input.receive(try field(id: 3, text: "a", cursor: 1))
        input.insert("Z")
        XCTAssertEqual(sent.count, 2)
        input.receive(try field(id: 4, text: "aXY", cursor: 3))
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent[2].message(21)?.int(2), 4)
        input.reset()
    }

    func testAbsentProto3CursorMeansZero() throws {
        let input = TVTextInput(send: { _ in }, changed: { _ in }, failed: { XCTFail($0) })
        var w = ProtoWriter()
        w.message(20) { envelope in
            envelope.message(1) { $0.int(1, 7) }
            envelope.message(2) { f in f.int(1, 1); f.string(2, "abc") }
        }
        input.receive(try ProtoMessage(w.data))
        XCTAssertEqual(input.state.cursor, 0)
        input.insert("X")
        XCTAssertEqual(input.state.value, "Xabc")
        input.reset()
    }

    func testInvalidReplacementNeverSendsClearingKeys() throws {
        var count = 0
        let input = TVTextInput(send: { _ in count += 1 }, changed: { _ in }, failed: { _ in })
        input.receive(try field(id: 1, text: "abc", cursor: 3, focus: true))
        input.replace(NSRange(location: 0, length: 3), with: String(repeating: "a", count: 4097))
        XCTAssertEqual(count, 0)
        XCTAssertEqual(input.state.value, "abc")
        input.receive(try field(id: 2, text: String(repeating: "a", count: 501), cursor: 501, focus: true))
        input.replace(NSRange(location: 0, length: 501), with: "new")
        XCTAssertEqual(count, 0)
        input.reset()
    }

    func testCommittedAccentReplacementWaitsForDeletion() throws {
        var sent: [ProtoMessage] = []
        let input = TVTextInput(send: { sent.append(try! ProtoMessage($0.data)) }, changed: { _ in }, failed: { XCTFail($0) })
        input.receive(try field(id: 1, text: "e", cursor: 1, focus: true))
        input.replace(NSRange(location: 0, length: 1), with: "é")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].message(10)?.int(1), KeyCode.deleteBackward.rawValue)
        input.receive(try field(id: 2, text: "", cursor: 0))
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].message(21)?.message(3)?.message(2)?.string(3), "é")
        input.reset()
    }

    func testComposedCharacterDeletionThenInsertion() throws {
        var sent: [ProtoMessage] = []
        let input = TVTextInput(send: { sent.append(try! ProtoMessage($0.data)) }, changed: { _ in }, failed: { XCTFail($0) })
        let text = "a👨‍👩‍👧‍👦"
        input.receive(try field(id: 1, text: text, cursor: text.utf16.count, focus: true))
        input.key(.deleteBackward)
        input.insert("b")
        XCTAssertEqual(input.state.value, "a")
        XCTAssertEqual(sent.count, 1)
        input.receive(try field(id: 2, text: "a", cursor: 1))
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(input.state.value, "ab")
        input.reset()
    }

    func testReturnSuspendsInputUntilFreshFocus() throws {
        var count = 0
        let input = TVTextInput(send: { _ in count += 1 }, changed: { _ in }, failed: { _ in })
        input.receive(try field(id: 1, text: "query", cursor: 5, focus: true))
        let context = input.state.context
        input.key(.enter)
        XCTAssertFalse(input.state.active)
        XCTAssertNotEqual(input.state.context, context)
        input.insert("stale")
        input.receive(try field(id: 2, text: "query", cursor: 5))
        input.insert("still stale")
        XCTAssertEqual(count, 1)
        input.receive(try field(id: 3, text: "", cursor: 0, focus: true))
        input.insert("new")
        XCTAssertEqual(count, 2)
        input.reset()
    }
}

final class HardwareKeyboardTests: XCTestCase {
    func testLettersAreLiteralAndroidKeysNotRemoteActions() throws {
        let keys = try XCTUnwrap(HardwareKeyboard.strokes(for: "hm a"))
        XCTAssertEqual(keys.map(\.code), [36, 41, 62, 29])
        XCTAssertTrue(keys.allSatisfy { $0.direction == 3 })
        XCTAssertFalse(keys.contains { $0.code == KeyCode.home.rawValue || $0.code == KeyCode.volumeMute.rawValue })
    }

    func testUppercaseAndPunctuationUseBalancedShift() throws {
        let keys = try XCTUnwrap(HardwareKeyboard.strokes(for: "A?"))
        XCTAssertEqual(keys.map(\.code), [59, 29, 59, 59, 76, 59])
        XCTAssertEqual(keys.map(\.direction), [1, 3, 2, 1, 3, 2])
        let ascii = String((32...126).map { Character(UnicodeScalar($0)!) })
        XCTAssertNotNil(HardwareKeyboard.strokes(for: ascii))
    }

    func testUnsupportedPasteIsRejectedBeforeAnyKeysAreSent() {
        XCTAssertNil(HardwareKeyboard.strokes(for: "abc😀"))
        XCTAssertNil(HardwareKeyboard.strokes(for: "abc\n"))
        XCTAssertNil(HardwareKeyboard.strokes(for: String(repeating: "a", count: 513)))
    }
}
