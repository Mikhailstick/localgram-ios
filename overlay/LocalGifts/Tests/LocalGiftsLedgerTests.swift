import Foundation
import XCTest
@testable import LocalGiftsLedger

final class LocalGiftsLedgerTests: XCTestCase {
    private func buy(_ ledger: inout LocalGiftsLedger, cost: Int64 = 100, id: UUID = UUID()) throws -> LocalGiftReceipt {
        return try ledger.purchase(requestId: id, recipientId: 42, recipientName: "Кеша", timestamp: 1_700_000_000,
            kind: .gift, title: "Подарок", cost: cost, giftData: Data([1, 2, 3]))
    }

    func testPurchaseDebitsExactPriceAndPersistsReceipt() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(1000)
        let receipt = try self.buy(&ledger, cost: 175)
        XCTAssertEqual(ledger.balance, 825)
        XCTAssertEqual(receipt.balanceAfter, 825)
        XCTAssertEqual(ledger.receipts, [receipt])
        let decoded = try JSONDecoder().decode(LocalGiftsLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
    }

    func testInsufficientFundsDoNotModifyState() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(99)
        let previous = ledger
        XCTAssertThrowsError(try self.buy(&ledger)) { XCTAssertEqual($0 as? LocalGiftsError, .insufficientBalance) }
        XCTAssertEqual(ledger, previous)
    }

    func testNativeGiftMetadataPersistsAndOldReceiptsRemainReadable() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(1000)
        let receipt = try ledger.purchase(requestId: UUID(), recipientId: 42,
            recipientName: "Кеша", timestamp: 1_700_000_000, kind: .gift,
            title: "Подарок", cost: 175, giftData: Data([1]),
            text: "С праздником!", entitiesData: Data([2, 3]), nameHidden: true)
        let encoded = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(LocalGiftsLedger.self, from: encoded), ledger)
        XCTAssertEqual(receipt.text, "С праздником!")
        XCTAssertEqual(receipt.nameHidden, true)

        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var oldReceipts = try XCTUnwrap(oldJSON["receipts"] as? [[String: Any]])
        for field in ["text", "entitiesData", "nameHidden"] { oldReceipts[0].removeValue(forKey: field) }
        oldJSON["receipts"] = oldReceipts
        let oldData = try JSONSerialization.data(withJSONObject: oldJSON)
        let restored = try JSONDecoder().decode(LocalGiftsLedger.self, from: oldData)
        try restored.validate()
        XCTAssertEqual(restored.balance, 825)
        XCTAssertEqual(restored.receipts.first?.id, receipt.id)
        XCTAssertNil(restored.receipts.first?.text)
        XCTAssertNil(restored.receipts.first?.nameHidden)
    }

    func testRepeatedConfirmationDoesNotDebitTwice() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(200)
        let id = UUID()
        let first = try self.buy(&ledger, id: id)
        let second = try self.buy(&ledger, id: id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(ledger.balance, 100)
        XCTAssertEqual(ledger.receipts.count, 1)
    }

    func testZeroAndNegativePricesAreRejected() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(1000)
        XCTAssertThrowsError(try self.buy(&ledger, cost: 0))
        XCTAssertThrowsError(try self.buy(&ledger, cost: -100))
        XCTAssertEqual(ledger.balance, 1000)
        XCTAssertTrue(ledger.receipts.isEmpty)
        XCTAssertThrowsError(try ledger.setBalance(-1))
    }

    func testMaximumInt64BalanceDoesNotOverflow() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(Int64.max)
        let receipt = try self.buy(&ledger, cost: Int64.max)
        XCTAssertEqual(receipt.balanceAfter, 0)
        XCTAssertEqual(ledger.balance, 0)
    }

    func testStarsPackageDoesNotOverflowTheNativeRenderer() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(Int64.max)
        let previous = ledger
        XCTAssertThrowsError(try ledger.purchase(requestId: UUID(), recipientId: 42,
            recipientName: "Кеша", timestamp: 1_700_000_000, kind: .stars, title: "Stars",
            cost: Int64(Int32.max) + 1, giftData: nil)) {
            XCTAssertEqual($0 as? LocalGiftsError, .starsTransferTooLarge)
        }
        XCTAssertEqual(ledger, previous)
        _ = try ledger.purchase(requestId: UUID(), recipientId: 42, recipientName: "Кеша",
            timestamp: 1_700_000_000, kind: .stars, title: "Stars", cost: Int64(Int32.max), giftData: nil)
        XCTAssertEqual(ledger.balance, Int64.max - Int64(Int32.max))
    }

    func testHidingVisualizationKeepsDebitAndNeverReusesSequence() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(500)
        let first = try self.buy(&ledger)
        ledger.hideReceipt(first.id)
        XCTAssertEqual(ledger.balance, 400)
        let second = try self.buy(&ledger)
        XCTAssertGreaterThan(second.sequence, first.sequence)
    }

    func testSeparateAccountFilesAndRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("account-1.json")
        let secondURL = directory.appendingPathComponent("account-2.json")
        var first = LocalGiftsLedger()
        try first.setBalance(500)
        _ = try self.buy(&first)
        try LocalGiftsPersistence.save(first, to: firstURL)
        try LocalGiftsPersistence.save(LocalGiftsLedger(), to: secondURL)
        XCTAssertEqual(try LocalGiftsPersistence.load(from: firstURL), first)
        XCTAssertEqual(try LocalGiftsPersistence.load(from: secondURL).balance, 0)
    }

    func testCorruptFileIsNotSilentlyReplaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = Data("broken JSON".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try LocalGiftsPersistence.load(from: url))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
}
