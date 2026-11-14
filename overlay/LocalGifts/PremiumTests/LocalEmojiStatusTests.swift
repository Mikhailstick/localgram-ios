import XCTest
@testable import LocalPremiumModel

final class LocalEmojiStatusTests: XCTestCase {
    func testPermanentEmojiRemainsSelected() {
        let selected = EGLocalEmojiStatus(kind: .emoji, fileId: 42)
        XCTAssertEqual(selected.effective(at: 2_000), selected)
    }

    func testTimedStatusEndsAtTheDeadline() {
        let selected = EGLocalEmojiStatus(kind: .emoji, fileId: 42, expirationDate: 2_000)
        XCTAssertEqual(selected.effective(at: 1_999), selected)
        XCTAssertEqual(selected.effective(at: 2_000), .original)
        XCTAssertEqual(selected.effective(at: 2_001), .original)
    }

    func testExplicitClearIsDifferentFromRestoringServerStatus() {
        XCTAssertEqual(EGLocalEmojiStatus.hidden.effective(at: 2_000), .hidden)
        XCTAssertNotEqual(EGLocalEmojiStatus.hidden, .original)
    }

    func testInvalidImportedSelectionFallsBackToServerStatus() {
        XCTAssertEqual(EGLocalEmojiStatus(kind: .emoji).effective(at: 2_000), .original)
        XCTAssertEqual(EGLocalEmojiStatus(kind: .emoji, fileId: 0).effective(at: 2_000), .original)
        XCTAssertEqual(EGLocalEmojiStatus(kind: .emoji, fileId: 42, expirationDate: -1).effective(at: 2_000), .original)
    }

    func testSignedDocumentIdIsPreserved() {
        let selected = EGLocalEmojiStatus(kind: .emoji, fileId: -42)
        XCTAssertEqual(selected.effective(at: 2_000), selected)
    }

    func testSelectionAndDeadlineSurviveEncoding() throws {
        let selected = EGLocalEmojiStatus(kind: .emoji, fileId: 42, expirationDate: 2_000)
        let restored = try JSONDecoder().decode(EGLocalEmojiStatus.self, from: JSONEncoder().encode(selected))
        XCTAssertEqual(restored, selected)
        XCTAssertEqual(restored.effective(at: 2_000), .original)
    }
}
