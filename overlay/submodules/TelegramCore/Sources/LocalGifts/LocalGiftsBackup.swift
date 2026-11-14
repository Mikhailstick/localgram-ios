import Foundation

public enum LocalGiftsBackupError: Error, Equatable {
    case invalidFile
    case unsupportedVersion
    case differentAccount
    case fileTooLarge
}

/// Portable account-local data; Telegram sessions and media files are never part of this file.
public struct LocalGiftsBackup: Codable {
    public static let maximumFileSize = 32 * 1024 * 1024
    public let format: String
    public let version: Int
    public let createdAt: Int64
    public let accountPeerId: Int64
    public let settingsAccountId: Int64
    public let ledger: LocalGiftsLedger
    /// Native safe settings export; `.noExport` descriptors are omitted by GGSettingsStore.
    public let settingsData: Data

    public init(accountPeerId: Int64, settingsAccountId: Int64, ledger: LocalGiftsLedger, settingsData: Data, createdAt: Int64 = Int64(Date().timeIntervalSince1970)) {
        self.format = "exoragram.local-backup"
        self.version = 1
        self.createdAt = createdAt
        self.accountPeerId = accountPeerId
        self.settingsAccountId = settingsAccountId
        self.ledger = ledger
        self.settingsData = settingsData
    }

    public func validate(for accountPeerId: Int64) throws {
        guard self.format == "exoragram.local-backup" else { throw LocalGiftsBackupError.invalidFile }
        guard self.version == 1 else { throw LocalGiftsBackupError.unsupportedVersion }
        guard self.accountPeerId == accountPeerId else { throw LocalGiftsBackupError.differentAccount }
        guard self.createdAt >= 0, self.settingsData.count <= Self.maximumFileSize else { throw LocalGiftsBackupError.invalidFile }
        try self.ledger.validate()
        guard let settings = try? JSONSerialization.jsonObject(with: self.settingsData) as? [String: Any],
              settings["format"] as? String == "ghostgram.settings",
              settings["version"] as? Int == 1,
              let accounts = settings["accounts"] as? [String: Any],
              accounts.count == 1, accounts[String(self.settingsAccountId)] is [String: Any],
              settings["global"] is [String: Any], settings["appGroup"] is [String: Any] else {
            throw LocalGiftsBackupError.invalidFile
        }
    }

    public func encode() throws -> Data {
        try self.validate(for: self.accountPeerId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumFileSize else { throw LocalGiftsBackupError.fileTooLarge }
        return data
    }

    public static func decode(_ data: Data, for accountPeerId: Int64) throws -> LocalGiftsBackup {
        guard data.count <= Self.maximumFileSize else { throw LocalGiftsBackupError.fileTooLarge }
        let backup: LocalGiftsBackup
        do {
            backup = try JSONDecoder().decode(LocalGiftsBackup.self, from: data)
        } catch {
            throw LocalGiftsBackupError.invalidFile
        }
        try backup.validate(for: accountPeerId)
        return backup
    }
}
