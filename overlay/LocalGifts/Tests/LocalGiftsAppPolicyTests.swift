import XCTest
@testable import LocalGiftsLedger

final class LocalGiftsAppPolicyTests: XCTestCase {
    func testExplicitBuildFlagSurvivesBrandAndSigningChanges() {
        for name in ["ExoraGram", "Renamed Client"] {
            XCTAssertTrue(LocalGiftsAppPolicy.isEnabled(infoDictionary: [
                "LocalGiftsEnabled": true, "CFBundleName": name,
                "CFBundleDisplayName": name, "CFBundleIdentifier": "resigned.client"
            ]))
        }
    }

    func testOrdinaryClientsStayDisabled() {
        XCTAssertFalse(LocalGiftsAppPolicy.isEnabled(infoDictionary: [:]))
        XCTAssertFalse(LocalGiftsAppPolicy.isEnabled(infoDictionary: [
            "CFBundleName": "Telegram", "CFBundleDisplayName": "Telegram"
        ]))
    }

    func testExplicitDisableOverridesLegacyName() {
        XCTAssertFalse(LocalGiftsAppPolicy.isEnabled(infoDictionary: [
            "LocalGiftsEnabled": false, "CFBundleName": "LocalGram"
        ]))
    }

    func testLegacyBuildsRemainEnabled() {
        XCTAssertTrue(LocalGiftsAppPolicy.isEnabled(infoDictionary: ["CFBundleName": "LocalGram"]))
        XCTAssertTrue(LocalGiftsAppPolicy.isEnabled(infoDictionary: [
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["localgifts"]]]
        ]))
    }
}
