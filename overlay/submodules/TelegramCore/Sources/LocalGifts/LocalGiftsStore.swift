import Foundation
import SwiftSignalKit

/// Shares one persisted ledger between the settings screen and chat renderer for each account.
public final class LocalGiftsStore {
    /// Stable build policy keeps local balances and screens enabled after a rename or re-sign.
    public static let isEnabled = LocalGiftsAppPolicy.isEnabled(infoDictionary: Bundle.main.infoDictionary ?? [:])

    /// A renderer-only namespace, deliberately outside every cloud and pending-send namespace.
    public static let messageNamespace: Int32 = 1_900_000_001

    public static func isLocalMessage(_ id: EngineMessage.Id) -> Bool {
        return id.namespace == self.messageNamespace
    }

    public static let transactionIdPrefix = "localgifts:"

    public static func isLocalTransaction(_ id: String) -> Bool {
        return id.hasPrefix(self.transactionIdPrefix)
    }

    private static let registryLock = NSLock()
    private static var registry: [Int64: LocalGiftsStore] = [:]

    public static func shared(accountPeerId: EnginePeer.Id) -> LocalGiftsStore {
        let key = accountPeerId.toInt64()
        self.registryLock.lock()
        defer { self.registryLock.unlock() }
        if let existing = self.registry[key] {
            return existing
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalGifts", isDirectory: true)
        let store = LocalGiftsStore(fileURL: directory.appendingPathComponent("\(key).json"))
        self.registry[key] = store
        return store
    }

    private let lock = NSLock()
    private let fileURL: URL
    private var ledger: LocalGiftsLedger
    private var storageError: Bool
    private let promise: ValuePromise<LocalGiftsLedger>

    private init(fileURL: URL) {
        self.fileURL = fileURL
        do {
            var ledger = try LocalGiftsPersistence.load(from: fileURL)
            if ledger.needsMarketplacePurchaseMigration {
                let purchasedIds = Set(ledger.receipts.compactMap { receipt -> Int64? in
                    guard receipt.kind == .collectible, case let .unique(gift)? = Self.decodedGift(receipt) else { return nil }
                    return gift.id
                })
                ledger.migrateMarketplacePurchases(purchasedIds)
            }
            self.ledger = ledger
            self.storageError = false
        } catch {
            // Preserve the unreadable file until the user explicitly resets local state.
            self.ledger = LocalGiftsLedger()
            self.storageError = true
        }
        self.promise = ValuePromise(self.ledger, ignoreRepeated: true)
    }

    public var state: Signal<LocalGiftsLedger, NoError> {
        return self.promise.get()
    }

    public func snapshot() -> LocalGiftsLedger {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.ledger
    }

    public func isMarketplaceGiftPurchased(_ gift: StarGift) -> Bool {
        guard case let .unique(gift) = gift else { return false }
        return self.snapshot().purchasedCollectibleIds.contains(gift.id)
    }

    /// Projects a local balance for a screen without changing the server StarsContext.
    public func presentationState(_ state: StarsContext.State?) -> StarsContext.State {
        return Self.presentationState(state, ledger: self.snapshot(), currency: .stars)
    }

    /// Updates a screen when either server metadata or the account-local ledger changes.
    public func presentationState(_ state: Signal<StarsContext.State?, NoError>) -> Signal<StarsContext.State?, NoError> {
        return combineLatest(state, self.state)
        |> map { state, ledger -> StarsContext.State? in
            return Self.presentationState(state, ledger: ledger, currency: .stars)
        }
        |> distinctUntilChanged
    }

    public func tonPresentationState(_ state: StarsContext.State?) -> StarsContext.State {
        return Self.presentationState(state, ledger: self.snapshot(), currency: .ton)
    }

    public func tonPresentationState(_ state: Signal<StarsContext.State?, NoError>) -> Signal<StarsContext.State?, NoError> {
        return combineLatest(state, self.state)
        |> map { state, ledger -> StarsContext.State? in
            return Self.presentationState(state, ledger: ledger, currency: .ton)
        }
        |> distinctUntilChanged
    }

    private static func presentationState(_ state: StarsContext.State?, ledger: LocalGiftsLedger, currency: LocalGiftCurrency) -> StarsContext.State {
        var result = state ?? StarsContext.State(flags: [], balance: .zero, subscriptions: [], canLoadMoreSubscriptions: false, transactions: [], canLoadMoreTransactions: false, isLoading: false)
        // The native TON StarsContext carries nanoTON in value, with nanos == 0.
        let balance = currency == .ton ? ledger.tonBalanceNano : ledger.balance
        result.balance = StarsAmount(value: balance, nanos: 0)
        result.flags.remove(.isPendingBalance)
        result.transactions = Self.transactions(ledger: ledger, currency: currency)
        result.canLoadMoreTransactions = false
        result.isLoading = false
        return result
    }

    /// The local wallet has its own spending history. No server transaction signal is subscribed
    /// and no remote context is modified or paginated by this projection.
    public func presentationTransactionsState(_ state: Signal<StarsTransactionsContext.State, NoError>, currency: LocalGiftCurrency, mode: StarsTransactionsContext.Mode) -> Signal<StarsTransactionsContext.State, NoError> {
        return self.state
        |> map { ledger -> StarsTransactionsContext.State in
            let transactions: [StarsContext.State.Transaction]
            switch mode {
            case .all, .outgoing:
                transactions = Self.transactions(ledger: ledger, currency: currency)
            case .incoming:
                transactions = []
            }
            return StarsTransactionsContext.State(transactions: transactions, canLoadMore: false, isLoading: false)
        }
        |> distinctUntilChanged
    }

    private static func transactions(ledger: LocalGiftsLedger, currency: LocalGiftCurrency) -> [StarsContext.State.Transaction] {
        return ledger.expenses(currency: currency).map { receipt in
            // A display peer retains the recorded recipient name without fetching or persisting it.
            let peer = EnginePeer.user(TelegramUser(
                id: EnginePeer.Id(receipt.recipientId), accessHash: nil,
                firstName: receipt.recipientName, lastName: nil, username: nil, phone: nil,
                photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil,
                usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
                profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil,
                verificationIconFileId: nil
            ))
            var flags: StarsContext.State.Transaction.Flags = [.isLocal]
            if receipt.kind == .stars {
                flags.insert(.isGift)
            } else if receipt.kind == .collectible {
                flags.insert(.isStarGiftResale)
            }
            return StarsContext.State.Transaction(
                flags: flags, id: Self.transactionIdPrefix + receipt.id.uuidString,
                count: CurrencyAmount(amount: StarsAmount(value: -receipt.cost, nanos: 0), currency: currency == .ton ? .ton : .stars),
                date: receipt.timestamp, peer: .peer(peer), title: receipt.title,
                description: receipt.recipientName, photo: nil, transactionDate: nil,
                transactionUrl: nil, paidMessageId: nil, giveawayMessageId: nil, media: [],
                subscriptionPeriod: nil, starGift: Self.decodedGift(receipt), floodskipNumber: nil,
                starrefCommissionPermille: nil, starrefPeerId: nil, starrefAmount: nil,
                paidMessageCount: nil, premiumGiftMonths: nil, adsProceedsFromDate: nil, adsProceedsToDate: nil
            )
        }
    }

    /// UI mutations run on main; readers and the state signal can be used from any queue.
    private func update(reset: Bool = false, _ transform: (inout LocalGiftsLedger) throws -> Void) throws {
        precondition(Thread.isMainThread)
        self.lock.lock()
        do {
            if self.storageError && !reset {
                throw LocalGiftsError.unreadableStorage
            }
            var next = reset ? LocalGiftsLedger() : self.ledger
            try transform(&next)
            // Commit both balance and receipt together, before exposing either to the UI.
            try LocalGiftsPersistence.save(next, to: self.fileURL)
            self.ledger = next
            self.storageError = false
            self.lock.unlock()
            self.promise.set(next)
        } catch {
            self.lock.unlock()
            throw error
        }
    }

    public func setBalance(_ amount: Int64) throws {
        try self.update { try $0.setBalance(amount) }
    }

    public func setTonBalanceNano(_ amount: Int64) throws {
        try self.update { try $0.setTonBalanceNano(amount) }
    }

    public func grantStars(_ amount: Int64) throws {
        try self.update { try $0.grantStars(amount) }
    }

    public func grantTonNano(_ amount: Int64) throws {
        try self.update { try $0.grantTonNano(amount) }
    }

    public static func starsPrice(for gift: StarGift) -> Int64? {
        switch gift {
        case let .generic(gift):
            return gift.price > 0 ? gift.price : nil
        case let .unique(gift):
            guard !gift.resellForTonOnly,
                  let price = gift.resellAmounts?.first(where: { $0.currency == .stars }),
                  price.amount.nanos == 0, price.amount.value > 0 else {
                return nil
            }
            return price.amount.value
        }
    }

    public static func title(for gift: StarGift) -> String {
        switch gift {
        case let .generic(gift):
            return gift.title ?? "Подарок за \(gift.price) Stars"
        case let .unique(gift):
            return "\(gift.title) #\(gift.number)"
        }
    }

    public static func tonPriceNano(for gift: StarGift) -> Int64? {
        guard case let .unique(gift) = gift,
              let price = gift.resellAmounts?.first(where: { $0.currency == .ton }),
              price.amount.nanos == 0, price.amount.value > 0 else {
            return nil
        }
        return price.amount.value
    }

    @discardableResult
    public func sendGift(_ gift: StarGift, recipientId: EnginePeer.Id, recipientName: String, requestId: UUID, text: String? = nil, entities: [MessageTextEntity]? = nil, nameHidden: Bool = false, priceOverride: Int64? = nil, currency: LocalGiftCurrency = .stars) throws -> LocalGiftReceipt {
        let listedPrice = currency == .ton ? Self.tonPriceNano(for: gift) : Self.starsPrice(for: gift)
        guard let price = priceOverride ?? listedPrice, price > 0 else {
            throw LocalGiftsError.unsupportedCurrency
        }
        let data = try JSONEncoder().encode(gift)
        let entitiesData = try entities.map { try JSONEncoder().encode($0) }
        let kind: LocalGiftReceipt.Kind
        let collectibleId: Int64?
        if case let .unique(uniqueGift) = gift {
            kind = .collectible
            collectibleId = uniqueGift.id
        } else {
            kind = .gift
            collectibleId = nil
        }
        var receipt: LocalGiftReceipt?
        try self.update {
            receipt = try $0.purchase(requestId: requestId, recipientId: recipientId.toInt64(), recipientName: recipientName,
                timestamp: Int32(clamping: Int64(Date().timeIntervalSince1970)), kind: kind,
                title: Self.title(for: gift), cost: price, giftData: data,
                text: text, entitiesData: entitiesData, nameHidden: nameHidden, currency: currency, collectibleId: collectibleId)
        }
        return receipt!
    }

    @discardableResult
    public func sendStars(_ amount: Int64, recipientId: EnginePeer.Id, recipientName: String, requestId: UUID) throws -> LocalGiftReceipt {
        var receipt: LocalGiftReceipt?
        try self.update {
            receipt = try $0.purchase(requestId: requestId, recipientId: recipientId.toInt64(), recipientName: recipientName,
                timestamp: Int32(clamping: Int64(Date().timeIntervalSince1970)), kind: .stars,
                title: "\(amount) Stars", cost: amount, giftData: nil)
        }
        return receipt!
    }

    public func hideReceipt(_ id: UUID) throws {
        try self.update { $0.hideReceipt(id) }
    }

    public func reset() throws {
        try self.update(reset: true) { _ in }
    }

    public func resetMarketplacePurchases() throws {
        try self.update { $0.resetMarketplacePurchases() }
    }

    public func receipt(sequence: Int32, recipientId: EnginePeer.Id) -> LocalGiftReceipt? {
        return self.snapshot().receipts.first(where: { $0.sequence == sequence && $0.recipientId == recipientId.toInt64() })
    }

    public func receipt(transactionId: String) -> LocalGiftReceipt? {
        guard Self.isLocalTransaction(transactionId),
              let id = UUID(uuidString: String(transactionId.dropFirst(Self.transactionIdPrefix.count))) else {
            return nil
        }
        return self.snapshot().receipts.first(where: { $0.id == id })
    }

    public static func decodedGift(_ receipt: LocalGiftReceipt) -> StarGift? {
        guard let data = receipt.giftData else { return nil }
        return try? JSONDecoder().decode(StarGift.self, from: data)
    }

    public static func decodedEntities(_ receipt: LocalGiftReceipt) -> [MessageTextEntity]? {
        guard let data = receipt.entitiesData else { return nil }
        return try? JSONDecoder().decode([MessageTextEntity].self, from: data)
    }
}
