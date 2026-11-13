import AccountContext
import ChatHistoryEntry
import Foundation
import TelegramCore
import TelegramPresentationData

/// Merges display-only gift messages into a loaded timeline. Nothing is written to Postbox.
func localGiftsChatEntries(
    entries: [ChatHistoryEntry],
    context: AccountContext,
    location: ChatLocation,
    subject: ChatControllerSubject?,
    view: EngineRawMessageHistoryView,
    accountPeer: EnginePeer?,
    presentationData: ChatPresentationData,
    reverse: Bool,
    enabled: Bool
) -> [ChatHistoryEntry] {
    guard enabled, subject == nil, !view.isLoading,
          case let .peer(peerId) = location, peerId.namespace == Namespaces.Peer.CloudUser else {
        return entries
    }
    let receipts = LocalGiftsStore.shared(accountPeerId: context.account.peerId).snapshot().receipts.filter { receipt in
        guard receipt.recipientId == peerId.toInt64() else { return false }
        // Keep history pagination honest: never attach today's local gift to an old slice.
        if view.laterId != nil, let last = view.entries.last, receipt.timestamp > last.message.timestamp { return false }
        if view.earlierId != nil, let first = view.entries.first, receipt.timestamp < first.message.timestamp { return false }
        return true
    }
    guard !receipts.isEmpty else { return entries }
    var result = reverse ? Array(entries.reversed()) : entries
    var peers: [EnginePeer.Id: EnginePeer] = [:]
    if let accountPeer { peers[accountPeer.id] = accountPeer }
    for additional in view.additionalData {
        if case let .peer(id, peer) = additional, let peer { peers[id] = EnginePeer(peer) }
    }
    for receipt in receipts {
        let action: TelegramMediaActionType
        if receipt.kind == .stars {
            action = .giftStars(currency: "XTR", amount: receipt.cost, count: receipt.cost,
                cryptoCurrency: nil, cryptoAmount: nil, transactionId: nil)
        } else {
            guard let gift = LocalGiftsStore.decodedGift(receipt) else { continue }
            switch gift {
            case .generic:
                action = .starGift(gift: gift, convertStars: nil, text: receipt.text, entities: LocalGiftsStore.decodedEntities(receipt),
                    nameHidden: receipt.nameHidden ?? false, savedToProfile: false, converted: false, upgraded: false,
                    canUpgrade: false, upgradeStars: nil, isRefunded: false, isPrepaidUpgrade: false,
                    upgradeMessageId: nil, peerId: peerId, senderId: context.account.peerId, savedId: nil,
                    prepaidUpgradeHash: nil, giftMessageId: nil, upgradeSeparate: false,
                    isAuctionAcquired: false, toPeerId: peerId, number: nil)
            case .unique:
                action = .starGiftUnique(gift: gift, isUpgrade: false, isTransferred: true,
                    savedToProfile: false, canExportDate: nil, transferStars: nil, isRefunded: false,
                    isPrepaidUpgrade: false, peerId: peerId, senderId: context.account.peerId,
                    savedId: nil, resaleAmount: CurrencyAmount(amount: StarsAmount(value: receipt.cost, nanos: 0), currency: receipt.currency == .ton ? .ton : .stars), canTransferDate: nil, canResaleDate: nil,
                    dropOriginalDetailsStars: nil, assigned: false, fromOffer: false,
                    canCraftAt: nil, isCrafted: false, text: receipt.text,
                    entities: LocalGiftsStore.decodedEntities(receipt), nameHidden: receipt.nameHidden ?? false)
            }
        }
        let message = EngineMessage(
            stableId: 3_000_000_000 + UInt32(receipt.sequence),
            stableVersion: 0,
            id: EngineMessage.Id(peerId: peerId, namespace: LocalGiftsStore.messageNamespace, id: receipt.sequence),
            globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil,
            timestamp: receipt.timestamp, flags: [], tags: [], globalTags: [], localTags: [],
            customTags: [], forwardInfo: nil, author: accountPeer, text: "",
            attributes: [], media: [.action(TelegramMediaAction(action: action))], peers: peers,
            associatedMessages: [:], associatedMessageIds: [],
            associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:]
        )
        result.append(.MessageEntry(message._asMessage(), presentationData, true, nil, .none, ChatMessageEntryAttributes()))
    }
    result.sort()
    return reverse ? Array(result.reversed()) : result
}
