import Foundation
import SwiftSignalKit

/// Shares one persisted ledger between the settings screen and chat renderer for each account.
public final class LocalGiftsStore {
    /// A renderer-only namespace, deliberately outside every cloud and pending-send namespace.
    public static let messageNamespace: Int32 = 1_900_000_001

    public static func isLocalMessage(_ id: EngineMessage.Id) -> Bool {
        return id.namespace == self.messageNamespace
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
            self.ledger = try LocalGiftsPersistence.load(from: fileURL)
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

    @discardableResult
    public func sendGift(_ gift: StarGift, recipientId: EnginePeer.Id, recipientName: String, requestId: UUID) throws -> LocalGiftReceipt {
        guard let price = Self.starsPrice(for: gift) else {
            throw LocalGiftsError.unsupportedCurrency
        }
        let data = try JSONEncoder().encode(gift)
        let kind: LocalGiftReceipt.Kind
        if case .unique = gift {
            kind = .collectible
        } else {
            kind = .gift
        }
        var receipt: LocalGiftReceipt?
        try self.update {
            receipt = try $0.purchase(requestId: requestId, recipientId: recipientId.toInt64(), recipientName: recipientName,
                timestamp: Int32(clamping: Int64(Date().timeIntervalSince1970)), kind: kind,
                title: Self.title(for: gift), cost: price, giftData: data)
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

    public func receipt(sequence: Int32, recipientId: EnginePeer.Id) -> LocalGiftReceipt? {
        return self.snapshot().receipts.first(where: { $0.sequence == sequence && $0.recipientId == recipientId.toInt64() })
    }

    public static func decodedGift(_ receipt: LocalGiftReceipt) -> StarGift? {
        guard let data = receipt.giftData else { return nil }
        return try? JSONDecoder().decode(StarGift.self, from: data)
    }
}
