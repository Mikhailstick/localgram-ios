import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import ComponentFlow
import EntityKeyboard
import EmojiStatusComponent
import EmojiStatusSelectionComponent
import GGCore
import GGSettingsUI
import GGFeaturesShared

enum EGLocalPremiumMenu {
    private static let tab = GGMenuTabID("appearance.localPremium")

    static func register() {
        let screen = GGMenuScreenID.tab(self.tab)
        let main = GGMenuSectionID.main(of: self.tab)
        GGMenuRegistry.register(tab: GGMenuTabDescriptor(id: self.tab, parent: .category(.appearance), title: { GGStrings.LocalPremium.title }, searchKeywords: { [GGStrings.LocalPremium.keywords] }), linkIn: .appearanceTabs, order: 650, subtitle: { GGStrings.LocalPremium.info }, icon: .system("star.fill"))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: .preview(of: self.tab), screen: screen, order: 100, header: { GGStrings.LocalPremium.preview }))
        GGMenuRegistry.register(GGMenuRow(id: "localPremium.preview", section: .preview(of: self.tab), order: 100, title: { "" }, kind: .preview(.custom(height: 116.0, make: { _ in EGLocalPremiumPreview(frame: CGRect()) }))))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: main, screen: screen, order: 200, footer: { _ in GGStrings.LocalPremium.footer }))
        GGMenuRegistry.register(GGMenuRow(id: "localPremium.enabled", section: main, order: 100, title: { GGStrings.LocalPremium.enabled }, kind: .toggle(.account(EGLocalPremiumSettings.enabled))))
        GGMenuRegistry.register(GGMenuRow(id: "localPremium.showBadge", section: main, order: 200, title: { GGStrings.LocalPremium.showBadge }, kind: .toggle(.account(EGLocalPremiumSettings.showPremiumBadge)), isEnabled: { EGLocalPremiumSettings.enabled.value(for: $0.accountID) }))
        GGMenuRegistry.register(GGMenuRow(id: "localPremium.chooseStatus", section: main, order: 300, title: { GGStrings.LocalPremium.chooseStatus }, kind: .action({ menu in self.chooseStatus(menu) }), isEnabled: { EGLocalPremiumSettings.enabled.value(for: $0.accountID) }))
        GGMenuRegistry.register(GGMenuRow(id: "localPremium.clearStatus", section: main, order: 400, title: { GGStrings.LocalPremium.clearStatus }, kind: .action({ menu in EGLocalPremiumSettings.setStatus(fileId: nil, expirationDate: nil, for: menu.accountID) }), isEnabled: { EGLocalPremiumSettings.enabled.value(for: $0.accountID) }))
        GGMenuRegistry.register(GGMenuRow(id: "localPremium.restoreStatus", section: main, order: 500, title: { GGStrings.LocalPremium.restoreStatus }, kind: .action({ menu in EGLocalPremiumSettings.resetStatus(for: menu.accountID) }), isEnabled: { !EGLocalPremiumSettings.status.isDefault(for: $0.accountID) }))
        GGMenuRegistry.register(GGMenuRow(id: "localPremium.reset", section: main, order: 600, title: { GGStrings.LocalPremium.reset }, kind: .action({ menu in EGLocalPremiumSettings.reset(for: menu.accountID) }), isEnabled: { menu in
            !EGLocalPremiumSettings.enabled.isDefault(for: menu.accountID) || !EGLocalPremiumSettings.showPremiumBadge.isDefault(for: menu.accountID) || !EGLocalPremiumSettings.status.isDefault(for: menu.accountID)
        }))
    }

    private static func chooseStatus(_ menu: GGMenuContext) {
        guard EGLocalPremiumSettings.enabled.value(for: menu.accountID), let sourceView = menu.navigationController?.view else {
            return
        }
        let context = menu.context
        let selected = EGLocalPremiumSettings.displayEmojiStatus(account: menu.accountID, serverStatus: menu.accountPeer?.emojiStatus)?.fileId
        let picker = EmojiStatusSelectionController(context: context, mode: .localStatusSelection(completion: { file, expirationDate in
            EGLocalPremiumSettings.setStatus(fileId: file?.fileId.id, expirationDate: expirationDate, for: context.account.id.gg)
        }), sourceView: sourceView, emojiContent: EmojiPagerContentComponent.emojiInputData(context: context, animationCache: context.animationCache, animationRenderer: context.animationRenderer, isStandalone: false, subject: .status, hasTrending: false, topReactionItems: [], areUnicodeEmojiEnabled: false, areCustomEmojiEnabled: true, chatPeerId: context.account.peerId, selectedItems: selected.map { Set([AnyHashable(EngineMedia.Id(namespace: Namespaces.Media.CloudFile, id: $0))]) } ?? [], forceHasPremium: true, allowsStarGiftStatus: false, isLocalStatusSelection: true), currentSelection: selected, allowsPremiumSelection: true, destinationItemView: { nil })
        menu.present(picker)
    }
}

/// This uses the same native status component as the profile, including animated custom emoji.
private final class EGLocalPremiumPreview: UIView, GGMenuPreviewView {
    private let nameLabel = UILabel()
    private let stateLabel = UILabel()
    private let statusView = ComponentView<Empty>()
    private var lastContext: GGMenuContext?
    private var expiryTimer: SwiftSignalKit.Timer?
    private var timerExpiration: Int32?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.nameLabel.font = .systemFont(ofSize: 21.0, weight: .semibold)
        self.nameLabel.lineBreakMode = .byTruncatingTail
        self.stateLabel.font = .systemFont(ofSize: 14.0)
        self.stateLabel.textAlignment = .center
        self.addSubview(self.nameLabel)
        self.addSubview(self.stateLabel)
    }

    required init?(coder: NSCoder) { preconditionFailure() }
    deinit { self.expiryTimer?.invalidate() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let context = self.lastContext { self.update(context: context) }
    }

    func update(context: GGMenuContext) {
        self.lastContext = context
        let theme = context.presentationData.theme
        let enabled = EGLocalPremiumSettings.enabled.value(for: context.accountID)
        let status = EGLocalPremiumSettings.displayEmojiStatus(account: context.accountID, serverStatus: context.accountPeer?.emojiStatus)
        let content: EmojiStatusComponent.Content
        if let status {
            content = .animation(content: .customEmoji(fileId: status.fileId), size: CGSize(width: 32.0, height: 32.0), placeholderColor: theme.list.itemSecondaryTextColor.withAlphaComponent(0.3), themeColor: UIColor(rgb: 0x8A5CF6), loopMode: .forever)
        } else if EGLocalPremiumSettings.showsPremiumBadge(account: context.accountID, serverIsPremium: context.accountPeer?.isPremium ?? false) {
            content = .premium(color: UIColor(rgb: 0x8A5CF6))
        } else {
            content = .none
        }
        let statusSize = self.statusView.update(transition: .immediate, component: AnyComponent(EmojiStatusComponent(context: context.context, animationCache: context.context.animationCache, animationRenderer: context.context.animationRenderer, content: content, size: CGSize(width: 32.0, height: 32.0), isVisibleForAnimations: true, action: nil)), environment: {}, containerSize: CGSize(width: 32.0, height: 32.0))
        let hasIcon = content != .none
        self.nameLabel.text = context.accountPeer?.compactDisplayTitle ?? "ExoraGram"
        self.nameLabel.textColor = theme.list.itemPrimaryTextColor
        let labelWidth = min(max(0.0, self.bounds.width - 80.0), self.nameLabel.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: 28.0)).width)
        let groupWidth = labelWidth + (hasIcon ? statusSize.width + 7.0 : 0.0)
        let left = floor((self.bounds.width - groupWidth) * 0.5)
        self.nameLabel.frame = CGRect(x: left, y: 28.0, width: labelWidth, height: 29.0)
        if let view = self.statusView.view {
            if view.superview !== self { self.addSubview(view) }
            view.frame = CGRect(x: left + labelWidth + 7.0, y: 26.5, width: statusSize.width, height: statusSize.height)
            view.isHidden = !hasIcon
        }
        self.stateLabel.text = enabled ? GGStrings.LocalPremium.active : GGStrings.LocalPremium.inactive
        self.stateLabel.textColor = theme.list.itemSecondaryTextColor
        self.stateLabel.frame = CGRect(x: 16.0, y: 74.0, width: max(0.0, self.bounds.width - 32.0), height: 22.0)
        let expiration = status?.expirationDate
        if self.timerExpiration != expiration {
            self.expiryTimer?.invalidate()
            self.expiryTimer = nil
            self.timerExpiration = expiration
            if let expiration, Double(expiration) > Date().timeIntervalSince1970 {
                let timer = SwiftSignalKit.Timer(timeout: max(0.01, Double(expiration) - Date().timeIntervalSince1970 + 0.05), repeat: false, completion: { [weak self] in
                    guard let self else { return }
                    self.timerExpiration = nil
                    if let context = self.lastContext { self.update(context: context) }
                }, queue: Queue.mainQueue())
                self.expiryTimer = timer
                timer.start()
            }
        }
    }
}
