import Foundation
import XCTest
@testable import LocalGiftsLedger

final class LocalGiftsMarketFilterTests: XCTestCase {
    func testRealMarketplaceAlwaysKeepsItsCatalog() {
        let filter = LocalGiftsMarketFilter(enabled: true, modelQuery: "missing", currency: .stars, minimumPrice: 100)
        XCTAssertTrue(filter.includes(modelName: "different", starsPrice: 1, gramPriceNano: nil, isPurchased: true, isLocalMode: false))
    }

    func testDisabledFilterPreservesBoughtMaskAndIgnoresOtherCriteria() {
        let filter = LocalGiftsMarketFilter(hidePurchased: false, modelQuery: "missing", currency: .gram, minimumPrice: 100)
        XCTAssertTrue(filter.includes(modelName: nil, starsPrice: 1, gramPriceNano: nil, isPurchased: false, isLocalMode: true))
        XCTAssertFalse(filter.includes(modelName: nil, starsPrice: 1, gramPriceNano: nil, isPurchased: true, isLocalMode: true))
    }

    func testShowingPurchasedRequiresExplicitlyEnabledFilters() {
        var filter = LocalGiftsMarketFilter(enabled: true)
        XCTAssertFalse(filter.includes(modelName: nil, starsPrice: 100, gramPriceNano: nil, isPurchased: true, isLocalMode: true))
        filter.hidePurchased = false
        XCTAssertTrue(filter.includes(modelName: nil, starsPrice: 100, gramPriceNano: nil, isPurchased: true, isLocalMode: true))
        filter.enabled = false
        XCTAssertFalse(filter.includes(modelName: nil, starsPrice: 100, gramPriceNano: nil, isPurchased: true, isLocalMode: true))
    }

    func testModelSubstringIsCaseAndDiacriticInsensitive() {
        let filter = LocalGiftsMarketFilter(enabled: true, modelQuery: "  creme  ")
        XCTAssertTrue(filter.includes(modelName: "Crème Brûlée", starsPrice: 100, gramPriceNano: nil, isPurchased: false, isLocalMode: true))
        XCTAssertFalse(filter.includes(modelName: "Golden", starsPrice: 100, gramPriceNano: nil, isPurchased: false, isLocalMode: true))
        XCTAssertFalse(filter.includes(modelName: nil, starsPrice: 100, gramPriceNano: nil, isPurchased: false, isLocalMode: true))
    }

    func testStarsRangeIsInclusiveAndRequiresStarsOffer() {
        let filter = LocalGiftsMarketFilter(enabled: true, currency: .stars, minimumPrice: 100, maximumPrice: 200)
        for price: Int64 in [100, 200] {
            XCTAssertTrue(filter.includes(modelName: nil, starsPrice: price, gramPriceNano: nil, isPurchased: false, isLocalMode: true))
        }
        for price: Int64 in [99, 201] {
            XCTAssertFalse(filter.includes(modelName: nil, starsPrice: price, gramPriceNano: nil, isPurchased: false, isLocalMode: true))
        }
        XCTAssertFalse(filter.includes(modelName: nil, starsPrice: nil, gramPriceNano: 100, isPurchased: false, isLocalMode: true))
    }

    func testGramRangeUsesExactNanoUnitsAndItsOwnOffer() throws {
        let bound = try XCTUnwrap(LocalTonAmount.parse("1.000000001"))
        let filter = LocalGiftsMarketFilter(enabled: true, currency: .gram, minimumPrice: bound, maximumPrice: bound)
        XCTAssertTrue(filter.includes(modelName: nil, starsPrice: 1, gramPriceNano: bound, isPurchased: false, isLocalMode: true))
        XCTAssertFalse(filter.includes(modelName: nil, starsPrice: bound, gramPriceNano: nil, isPurchased: false, isLocalMode: true))
        XCTAssertFalse(filter.includes(modelName: nil, starsPrice: 1, gramPriceNano: bound - 1, isPurchased: false, isLocalMode: true))
        XCTAssertFalse(filter.includes(modelName: nil, starsPrice: 1, gramPriceNano: bound + 1, isPurchased: false, isLocalMode: true))
    }

    func testChangingCurrencyClearsBoundsInsteadOfReinterpretingThem() {
        var filter = LocalGiftsMarketFilter(enabled: true, currency: .stars, minimumPrice: 100, maximumPrice: 200)
        filter.selectCurrency(.stars)
        XCTAssertEqual(filter.minimumPrice, 100)
        filter.selectCurrency(.gram)
        XCTAssertNil(filter.minimumPrice)
        XCTAssertNil(filter.maximumPrice)
        XCTAssertEqual(filter.currency, .gram)
    }

    func testInvalidRangeFallsBackToOriginalBoughtMask() {
        for filter in [
            LocalGiftsMarketFilter(enabled: true, hidePurchased: false, currency: .stars, minimumPrice: -1),
            LocalGiftsMarketFilter(enabled: true, hidePurchased: false, currency: .gram, minimumPrice: 200, maximumPrice: 100),
            LocalGiftsMarketFilter(enabled: true, hidePurchased: false, currency: .any, maximumPrice: 100)
        ] {
            XCTAssertFalse(filter.isValid)
            XCTAssertTrue(filter.includes(modelName: nil, starsPrice: nil, gramPriceNano: nil, isPurchased: false, isLocalMode: true))
            XCTAssertFalse(filter.includes(modelName: nil, starsPrice: nil, gramPriceNano: nil, isPurchased: true, isLocalMode: true))
        }
    }

    func testPersistentRangeRetainsFullInt64Precision() throws {
        let filter = LocalGiftsMarketFilter(enabled: true, hidePurchased: false, modelQuery: "Neon", currency: .gram, minimumPrice: Int64.max - 1, maximumPrice: Int64.max)
        let restored = try JSONDecoder().decode(LocalGiftsMarketFilter.self, from: JSONEncoder().encode(filter))
        XCTAssertEqual(restored, filter)
        XCTAssertTrue(restored.isValid)
    }
}
