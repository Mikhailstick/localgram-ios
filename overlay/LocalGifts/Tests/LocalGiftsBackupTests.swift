import XCTest
@testable import LocalGiftsLedger

final class LocalGiftsBackupTests: XCTestCase {
    private let settings = Data("{\"format\":\"ghostgram.settings\",\"version\":1,\"global\":{},\"appGroup\":{},\"accounts\":{\"7\":{}}}".utf8)

    func testBackupRoundTripPreservesBalancesAndSettings() throws {
        var ledger = LocalGiftsLedger()
        try ledger.setBalance(1234)
        try ledger.setTonBalanceNano(987_654_321)
        let source = LocalGiftsBackup(accountPeerId: 42, settingsAccountId: 7, ledger: ledger, settingsData: self.settings, createdAt: 100)
        let copy = try LocalGiftsBackup.decode(source.encode(), for: 42)
        XCTAssertEqual(copy.ledger, ledger)
        XCTAssertEqual(copy.settingsData, self.settings)
        XCTAssertEqual(copy.settingsAccountId, 7)
    }

    func testBackupCannotBeAppliedToAnotherTelegramAccount() throws {
        let backup = LocalGiftsBackup(accountPeerId: 42, settingsAccountId: 7, ledger: LocalGiftsLedger(), settingsData: self.settings)
        XCTAssertThrowsError(try LocalGiftsBackup.decode(backup.encode(), for: 43)) {
            XCTAssertEqual($0 as? LocalGiftsBackupError, .differentAccount)
        }
    }

    func testCorruptAndMismatchedSettingsPayloadIsRejected() {
        let backup = LocalGiftsBackup(accountPeerId: 42, settingsAccountId: 8, ledger: LocalGiftsLedger(), settingsData: self.settings)
        XCTAssertThrowsError(try backup.encode())
        XCTAssertThrowsError(try LocalGiftsBackup.decode(Data("not json".utf8), for: 42))
    }

    func testUnsupportedVersionIsRejectedBeforeRestore() throws {
        let backup = LocalGiftsBackup(accountPeerId: 42, settingsAccountId: 7, ledger: LocalGiftsLedger(), settingsData: self.settings)
        let data = try backup.encode()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 2
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try LocalGiftsBackup.decode(unsupported, for: 42)) {
            XCTAssertEqual($0 as? LocalGiftsBackupError, .unsupportedVersion)
        }
    }
}
