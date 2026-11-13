import Foundation
import XCTest
@testable import LocalGiftsLedger

final class LocalMarketplaceTests: XCTestCase {
    private func buy(_ ledger: inout LocalGiftsLedger, collectibleId: Int64 = 123, requestId: UUID = UUID(), currency: LocalGiftCurrency = .stars) throws -> LocalGiftReceipt {
        return try ledger.purchase(requestId: requestId, recipientId: 42, recipientName: "Кеша", timestamp: 100,
            kind: .collectible, title: "NFT #1", cost: 100, giftData: Data([1]),
            currency: currency, collectibleId: collectibleId)
    }

    func testDuplicateNFTIsRejectedAcrossRecipientsAndCurrenciesWithoutDebit() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(1000)
        try ledger.setTonBalanceNano(1000)
        let requestId = UUID()
        let first = try self.buy(&ledger, requestId: requestId)
        XCTAssertEqual(try self.buy(&ledger, requestId: requestId), first)
        let previous = ledger
        XCTAssertThrowsError(try ledger.purchase(requestId: UUID(), recipientId: 99, recipientName: "Другой", timestamp: 101,
            kind: .collectible, title: "NFT #1", cost: 100, giftData: nil, currency: .ton, collectibleId: 123)) {
            XCTAssertEqual($0 as? LocalGiftsError, .collectibleAlreadyPurchased)
        }
        XCTAssertEqual(ledger, previous)
        XCTAssertEqual(first.collectibleId, 123)
    }

    func testPurchasedIdentitySurvivesHiddenReceiptAndDiskRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("account.json")
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(1000)
        let receipt = try self.buy(&ledger)
        ledger.hideReceipt(receipt.id)
        try LocalGiftsPersistence.save(ledger, to: url)
        var restored = try LocalGiftsPersistence.load(from: url)
        XCTAssertTrue(restored.receipts.isEmpty)
        XCTAssertEqual(restored.purchasedCollectibleIds, [123])
        XCTAssertThrowsError(try self.buy(&restored)) {
            XCTAssertEqual($0 as? LocalGiftsError, .collectibleAlreadyPurchased)
        }
        XCTAssertEqual(restored.balance, 900)
    }

    func testResetPreservesBalanceAndHistoryAndOnlyRestoresLiveListings() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(1000)
        _ = try self.buy(&ledger, collectibleId: 123)
        _ = try self.buy(&ledger, collectibleId: 456)
        let receipts = ledger.receipts
        let serverListings: [Int64] = [123, 789] // 456 has since disappeared from the marketplace.
        XCTAssertEqual(LocalGiftsLedger.visibleMarketplaceCollectibleIds(in: serverListings, purchasedIds: ledger.purchasedCollectibleIds), [789])
        ledger.resetMarketplacePurchases()
        XCTAssertNotNil(ledger.marketplaceResetId)
        XCTAssertEqual(ledger.balance, 800)
        XCTAssertEqual(ledger.receipts, receipts)
        XCTAssertEqual(LocalGiftsLedger.visibleMarketplaceCollectibleIds(in: serverListings, purchasedIds: ledger.purchasedCollectibleIds), [123, 789])
        XCTAssertFalse(LocalGiftsLedger.visibleMarketplaceCollectibleIds(in: serverListings, purchasedIds: ledger.purchasedCollectibleIds).contains(456))
        let restored = try JSONDecoder().decode(LocalGiftsLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored, ledger)
        XCTAssertTrue(restored.purchasedCollectibleIds.isEmpty)
        _ = try self.buy(&ledger, collectibleId: 123)
        XCTAssertEqual(ledger.balance, 700)
        XCTAssertEqual(ledger.receipts.count, 3)
    }

    func testFailedPurchaseDoesNotHideListing() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(99)
        XCTAssertThrowsError(try self.buy(&ledger))
        XCTAssertTrue(ledger.purchasedCollectibleIds.isEmpty)
        XCTAssertEqual(LocalGiftsLedger.visibleMarketplaceCollectibleIds(in: [123], purchasedIds: ledger.purchasedCollectibleIds), [123])
    }

    func testLegacyPurchaseMigrationRunsOnceAndDoesNotUndoReset() throws {
        let data = Data("{\"balance\":1000,\"receipts\":[],\"lastSequence\":0}".utf8)
        var ledger = try JSONDecoder().decode(LocalGiftsLedger.self, from: data)
        ledger.migrateMarketplacePurchases([123])
        XCTAssertEqual(ledger.purchasedCollectibleIds, [123])
        ledger.resetMarketplacePurchases()
        var restored = try JSONDecoder().decode(LocalGiftsLedger.self, from: JSONEncoder().encode(ledger))
        restored.migrateMarketplacePurchases([123])
        XCTAssertTrue(restored.purchasedCollectibleIds.isEmpty)
    }

    func testInvalidCollectibleIdentityIsRejectedWithoutChangingState() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(1000)
        let previous = ledger
        for id: Int64 in [0, -1] {
            XCTAssertThrowsError(try self.buy(&ledger, collectibleId: id))
            XCTAssertEqual(ledger, previous)
        }
    }
}
