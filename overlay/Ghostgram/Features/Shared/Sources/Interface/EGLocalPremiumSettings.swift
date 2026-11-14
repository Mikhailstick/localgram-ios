import Foundation
import GGCore
import TelegramCore

extension EGLocalEmojiStatus: GGSettingValue {
}

/// Presentation-only settings. These never change subscription entitlement or engine peers.
public enum EGLocalPremiumSettings {
    public static let enabled = GGAccountSetting<Bool>("localPremium.enabled", default: false)
    public static let showPremiumBadge = GGAccountSetting<Bool>("localPremium.showBadge", default: true)
    public static let status = GGAccountSetting<EGLocalEmojiStatus>("localPremium.emojiStatus", default: .original)

    public static func declare() {
        let _ = self.enabled
        let _ = self.showPremiumBadge
        let _ = self.status
    }

    public static var currentTimestamp: Int32 {
        return Int32(clamping: Int64(Date().timeIntervalSince1970))
    }

    public static func displayEmojiStatus(account: GGAccountID, serverStatus: PeerEmojiStatus?, now: Int32 = EGLocalPremiumSettings.currentTimestamp) -> PeerEmojiStatus? {
        guard self.enabled.value(for: account) else {
            return serverStatus
        }
        let selection = self.status.value(for: account).effective(at: now)
        switch selection.kind {
        case .original:
            return serverStatus
        case .hidden:
            return nil
        case .emoji:
            guard let fileId = selection.fileId else {
                return serverStatus
            }
            return PeerEmojiStatus(content: .emoji(fileId: fileId), expirationDate: selection.expirationDate)
        }
    }

    public static func showsPremiumBadge(account: GGAccountID, serverIsPremium: Bool) -> Bool {
        return serverIsPremium || (self.enabled.value(for: account) && self.showPremiumBadge.value(for: account))
    }

    public static func setStatus(fileId: Int64?, expirationDate: Int32?, for account: GGAccountID) {
        guard self.enabled.value(for: account) else {
            return
        }
        let selection: EGLocalEmojiStatus
        if let fileId = fileId, fileId != 0 {
            selection = EGLocalEmojiStatus(kind: .emoji, fileId: fileId, expirationDate: expirationDate).effective(at: self.currentTimestamp)
        } else {
            selection = .hidden
        }
        self.status.set(selection, for: account)
    }

    public static func resetStatus(for account: GGAccountID) {
        self.status.reset(for: account)
    }

    public static func reset(for account: GGAccountID) {
        self.enabled.reset(for: account)
        self.showPremiumBadge.reset(for: account)
        self.status.reset(for: account)
    }
}
