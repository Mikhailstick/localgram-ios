import Foundation
import XCTest
@testable import LocalGiftsLedger

final class LocalTonLedgerTests: XCTestCase {
    private func buyNFT(_ ledger: inout LocalGiftsLedger, nano: Int64, id: UUID = UUID()) throws -> LocalGiftReceipt {
        return try ledger.purchase(requestId: id, recipientId: 42, recipientName: "Кеша", timestamp: 1_700_000_000,
            kind: .collectible, title: "NFT #1", cost: nano, giftData: Data([1]), currency: .ton)
    }

    func testFractionalNFTPurchaseDebitsOnlyTonAndIsIdempotent() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(900)
        try ledger.setTonBalanceNano(2_000_000_001)
        let id = UUID()
        let receipt = try self.buyNFT(&ledger, nano: 1_234_567_891, id: id)
        XCTAssertEqual(receipt.currency, .ton)
        XCTAssertEqual(receipt.cost, 1_234_567_891)
        XCTAssertEqual(receipt.balanceAfter, 765_432_110)
        XCTAssertEqual(ledger.tonBalanceNano, 765_432_110)
        XCTAssertEqual(ledger.balance, 900)
        XCTAssertEqual(try self.buyNFT(&ledger, nano: 1_234_567_891, id: id), receipt)
        XCTAssertEqual(ledger.tonBalanceNano, 765_432_110)
        XCTAssertEqual(ledger.receipts.count, 1)

        _ = try ledger.purchase(requestId: UUID(), recipientId: 42, recipientName: "Кеша", timestamp: 1_700_000_001,
            kind: .gift, title: "Stars gift", cost: 200, giftData: Data([2]))
        XCTAssertEqual(ledger.balance, 700)
        XCTAssertEqual(ledger.tonBalanceNano, 765_432_110)
        try ledger.validate()
    }

    func testStarsCannotCoverInsufficientTonBalance() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(Int64.max)
        try ledger.setTonBalanceNano(999_999_999)
        let previous = ledger
        XCTAssertThrowsError(try self.buyNFT(&ledger, nano: 1_000_000_000)) {
            XCTAssertEqual($0 as? LocalGiftsError, .insufficientBalance)
        }
        XCTAssertEqual(ledger, previous)
    }

    func testOnlyCollectiblesCanUseTon() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setTonBalanceNano(10_000_000_000)
        let previous = ledger
        for kind in [LocalGiftReceipt.Kind.gift, .stars] {
            XCTAssertThrowsError(try ledger.purchase(requestId: UUID(), recipientId: 42, recipientName: "Кеша", timestamp: 0,
                kind: kind, title: "Unsupported", cost: 1_000_000_000, giftData: nil, currency: .ton)) {
                XCTAssertEqual($0 as? LocalGiftsError, .unsupportedCurrency)
            }
        }
        XCTAssertEqual(ledger, previous)
    }

    func testGrantsAndEditsAreIndependentAndOverflowSafe() throws {
        var ledger = LocalGiftsLedger()
        try ledger.grantStars(7)
        try ledger.grantTonNano(1)
        try ledger.grantTonNano(1_000_000_000)
        XCTAssertEqual(ledger.balance, 7)
        XCTAssertEqual(ledger.tonBalanceNano, 1_000_000_001)
        try ledger.setTonBalanceNano(Int64.max)
        let previous = ledger
        XCTAssertThrowsError(try ledger.grantTonNano(1)) {
            XCTAssertEqual($0 as? LocalGiftsError, .balanceOverflow)
        }
        XCTAssertThrowsError(try ledger.grantTonNano(-1))
        XCTAssertThrowsError(try ledger.grantTonNano(0))
        XCTAssertThrowsError(try ledger.setTonBalanceNano(-1))
        XCTAssertEqual(ledger, previous)
        _ = try self.buyNFT(&ledger, nano: Int64.max)
        XCTAssertEqual(ledger.tonBalanceNano, 0)
        XCTAssertEqual(ledger.balance, 7)
    }

    func testDecimalParsingPreservesEveryNanoAndRejectsRounding() {
        XCTAssertEqual(LocalTonAmount.parse("0"), 0)
        XCTAssertEqual(LocalTonAmount.parse("0.000000001"), 1)
        XCTAssertEqual(LocalTonAmount.parse(" 12,345678901 \n"), 12_345_678_901)
        XCTAssertEqual(LocalTonAmount.parse(".5"), 500_000_000)
        XCTAssertEqual(LocalTonAmount.parse("1."), 1_000_000_000)
        XCTAssertEqual(LocalTonAmount.parse("9223372036.854775807"), Int64.max)
        for invalid in ["", ".", "-1", "+1", "1e9", "NaN", "inf", "1 000", "1.2.3", "1,2.3",
                        "0.0000000001", "9223372036.854775808", "9223372037", "9223372036854775808", "١"] {
            XCTAssertNil(LocalTonAmount.parse(invalid), invalid)
        }
    }

    func testDecimalFormattingRoundTripsWithoutFloatingPointLoss() {
        let amounts: [Int64] = [0, 1, 10, 999_999_999, 1_000_000_000, 1_000_000_001, 9_007_199_254_740_993, Int64.max]
        for nano in amounts {
            XCTAssertEqual(LocalTonAmount.parse(LocalTonAmount.format(nano)), nano)
        }
        XCTAssertEqual(LocalTonAmount.format(1_230_000_000), "1.23")
        XCTAssertEqual(LocalTonAmount.format(1), "0.000000001")
        XCTAssertEqual(LocalTonAmount.format(Int64.max), "9223372036.854775807")
        XCTAssertEqual(LocalTonAmount.format(Int64.min), "-9223372036.854775808")
    }

    func testOldStarsLedgerLoadsWithoutTonFieldsAndKeepsHistory() throws {
        let oldJSON = """
        {"balance":825,"lastSequence":1,"receipts":[{
          "id":"CA155A70-0F59-4E8C-925E-099A40E83217","sequence":1,"recipientId":42,
          "recipientName":"Кеша","timestamp":1700000000,"kind":"gift","title":"Подарок",
          "cost":175,"balanceAfter":825,"giftData":"AQID"
        }]}
        """
        var ledger = try JSONDecoder().decode(LocalGiftsLedger.self, from: Data(oldJSON.utf8))
        try ledger.validate()
        XCTAssertEqual(ledger.balance, 825)
        XCTAssertEqual(ledger.tonBalanceNano, 0)
        let previousReceipt = try XCTUnwrap(ledger.receipts.first)
        XCTAssertEqual(previousReceipt.currency, .stars)
        XCTAssertEqual(previousReceipt.cost, 175)
        XCTAssertEqual(previousReceipt.giftData, Data([1, 2, 3]))
        try ledger.grantTonNano(2_000_000_000)
        let nft = try self.buyNFT(&ledger, nano: 1)
        XCTAssertEqual(nft.sequence, 2)
        XCTAssertEqual(ledger.receipts.first, previousReceipt)
        XCTAssertEqual(ledger.balance, 825)
        XCTAssertEqual(ledger.tonBalanceNano, 1_999_999_999)
        XCTAssertEqual(try JSONDecoder().decode(LocalGiftsLedger.self, from: JSONEncoder().encode(ledger)), ledger)
    }

    func testBothWalletsAndCurrenciesSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("account.json")
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(100)
        try ledger.setTonBalanceNano(9_007_199_254_740_993)
        _ = try self.buyNFT(&ledger, nano: 1)
        try LocalGiftsPersistence.save(ledger, to: url)
        let restored = try LocalGiftsPersistence.load(from: url)
        XCTAssertEqual(restored, ledger)
        XCTAssertEqual(restored.tonBalanceNano, 9_007_199_254_740_992)
        XCTAssertEqual(restored.receipts.first?.currency, .ton)
        ledger.hideReceipt(ledger.receipts[0].id)
        XCTAssertEqual(ledger.tonBalanceNano, restored.tonBalanceNano)
    }

    func testSpendingHistoryIsNewestFirstAndCurrencyIsolatedAfterRestart() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(1000)
        try ledger.setTonBalanceNano(2_000_000_001)
        let firstStars = try ledger.purchase(requestId: UUID(), recipientId: 1, recipientName: "Первый", timestamp: 100,
            kind: .gift, title: "Gift", cost: 100, giftData: nil)
        let ton = try ledger.purchase(requestId: UUID(), recipientId: 2, recipientName: "Второй", timestamp: 200,
            kind: .collectible, title: "NFT", cost: 1_000_000_001, giftData: nil, currency: .ton)
        let nextStars = try ledger.purchase(requestId: UUID(), recipientId: 3, recipientName: "Третий", timestamp: 200,
            kind: .stars, title: "Stars", cost: 50, giftData: nil)
        let latestStars = try ledger.purchase(requestId: UUID(), recipientId: 4, recipientName: "Четвёртый", timestamp: 200,
            kind: .gift, title: "Gift", cost: 20, giftData: nil)
        let restored = try JSONDecoder().decode(LocalGiftsLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.expenses(currency: .stars), [latestStars, nextStars, firstStars])
        XCTAssertEqual(restored.expenses(currency: .ton), [ton])
        XCTAssertEqual(restored.expenses(currency: .ton).first?.cost, 1_000_000_001)
        XCTAssertEqual(restored.balance, 830)
        XCTAssertEqual(restored.tonBalanceNano, 1_000_000_000)
        XCTAssertTrue(LocalGiftsLedger().expenses(currency: .stars).isEmpty)
        XCTAssertTrue(LocalGiftsLedger().expenses(currency: .ton).isEmpty)
    }

    func testCorruptTonBalanceIsRejectedWithoutReplacingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = Data("{\"balance\":1,\"tonBalanceNano\":-1,\"receipts\":[],\"lastSequence\":0}".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try LocalGiftsPersistence.load(from: url)) {
            XCTAssertEqual($0 as? LocalGiftsError, .unreadableStorage)
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
}
