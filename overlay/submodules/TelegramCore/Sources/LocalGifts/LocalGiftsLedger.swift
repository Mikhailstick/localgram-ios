import Foundation

public enum LocalGiftsError: Error, Equatable {
    case invalidAmount
    case balanceOverflow
    case starsTransferTooLarge
    case insufficientBalance
    case unsupportedCurrency
    case exhaustedMessageIds
    case unreadableStorage
    case collectibleAlreadyPurchased
}

/// Stars are whole units; TON (GRAM in the local UI) is always stored in nanoTON.
public enum LocalGiftCurrency: String, Codable {
    case stars
    case ton
}

/// Decimal input and display for nanoTON, without a floating-point conversion.
public enum LocalTonAmount {
    public static let scale: Int64 = 1_000_000_000

    public static func parse(_ text: String) -> Int64? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !text.isEmpty,
              parts.allSatisfy({ $0.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) }) else {
            return nil
        }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= 9, !parts[0].isEmpty || !fraction.isEmpty,
              let whole = Int64(parts[0].isEmpty ? "0" : String(parts[0])),
              let fractionalNano = Int64(fraction + String(repeating: "0", count: 9 - fraction.count)) else {
            return nil
        }
        let (wholeNano, multiplicationOverflow) = whole.multipliedReportingOverflow(by: Self.scale)
        let (amount, additionOverflow) = wholeNano.addingReportingOverflow(fractionalNano)
        guard !multiplicationOverflow, !additionOverflow else {
            return nil
        }
        return amount
    }

    public static func format(_ nano: Int64) -> String {
        let magnitude = nano.magnitude
        let whole = magnitude / UInt64(Self.scale)
        let remainder = magnitude % UInt64(Self.scale)
        let sign = nano < 0 ? "-" : ""
        guard remainder != 0 else {
            return "\(sign)\(whole)"
        }
        let digits = String(remainder)
        var fraction = String(repeating: "0", count: 9 - digits.count) + digits
        while fraction.last == "0" {
            fraction.removeLast()
        }
        return "\(sign)\(whole).\(fraction)"
    }
}

public struct LocalGiftReceipt: Codable, Equatable {
    public enum Kind: String, Codable {
        case gift
        case collectible
        case stars
    }

    public let id: UUID
    public let sequence: Int32
    public let recipientId: Int64
    public let recipientName: String
    public let timestamp: Int32
    public let kind: Kind
    public let currency: LocalGiftCurrency
    public let title: String
    public let cost: Int64
    public let balanceAfter: Int64
    public let giftData: Data?
    public let text: String?
    public let entitiesData: Data?
    public let nameHidden: Bool?
    public let collectibleId: Int64?
}

/// Account-local display state. This model has no Telegram network or payment dependency.
public struct LocalGiftsLedger: Codable, Equatable {
    public private(set) var balance: Int64
    public private(set) var tonBalanceNano: Int64
    public private(set) var receipts: [LocalGiftReceipt]
    public private(set) var lastSequence: Int32
    /// Purchased NFT identities outlive their chat/transaction visualization.
    public private(set) var purchasedCollectibleIds: Set<Int64>
    /// A new token makes every open marketplace reload its current server listings.
    public private(set) var marketplaceResetId: UUID?
    var needsMarketplacePurchaseMigration: Bool

    public init() {
        self.balance = 0
        self.tonBalanceNano = 0
        self.receipts = []
        self.lastSequence = 0
        self.purchasedCollectibleIds = []
        self.marketplaceResetId = nil
        self.needsMarketplacePurchaseMigration = false
    }

    public func validate() throws {
        guard self.balance >= 0, self.tonBalanceNano >= 0, self.lastSequence >= 0, self.lastSequence <= 1_000_000_000,
              self.purchasedCollectibleIds.allSatisfy({ $0 > 0 }) else {
            throw LocalGiftsError.unreadableStorage
        }
        var ids = Set<UUID>()
        var sequences = Set<Int32>()
        for receipt in self.receipts {
            guard receipt.cost > 0, receipt.balanceAfter >= 0,
                  receipt.kind != .stars || receipt.cost <= Int64(Int32.max),
                  receipt.currency != .ton || receipt.kind == .collectible,
                  receipt.collectibleId == nil || (receipt.kind == .collectible && receipt.collectibleId! > 0),
                  receipt.sequence > 0, receipt.sequence <= self.lastSequence,
                  ids.insert(receipt.id).inserted,
                  sequences.insert(receipt.sequence).inserted else {
                throw LocalGiftsError.unreadableStorage
            }
        }
    }

    public mutating func setBalance(_ amount: Int64) throws {
        guard amount >= 0 else {
            throw LocalGiftsError.invalidAmount
        }
        self.balance = amount
    }

    public mutating func setTonBalanceNano(_ amount: Int64) throws {
        guard amount >= 0 else {
            throw LocalGiftsError.invalidAmount
        }
        self.tonBalanceNano = amount
    }

    public mutating func grantStars(_ amount: Int64) throws {
        self.balance = try Self.addingGrant(amount, to: self.balance)
    }

    public mutating func grantTonNano(_ amount: Int64) throws {
        self.tonBalanceNano = try Self.addingGrant(amount, to: self.tonBalanceNano)
    }

    /// Local wallet spending history, newest first and isolated by currency.
    public func expenses(currency: LocalGiftCurrency) -> [LocalGiftReceipt] {
        return self.receipts.filter { $0.currency == currency }.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.sequence > rhs.sequence
        }
    }

    /// Reset only the local marketplace mask, leaving balances, gifts and history intact.
    public mutating func resetMarketplacePurchases() {
        self.purchasedCollectibleIds.removeAll()
        self.marketplaceResetId = UUID()
        self.needsMarketplacePurchaseMigration = false
    }

    /// Availability is always supplied by the current marketplace response, never by receipts.
    public static func visibleMarketplaceCollectibleIds(in serverListingIds: [Int64], purchasedIds: Set<Int64>) -> Set<Int64> {
        return Set(serverListingIds).subtracting(purchasedIds)
    }

    mutating func migrateMarketplacePurchases(_ ids: Set<Int64>) {
        guard self.needsMarketplacePurchaseMigration else { return }
        self.purchasedCollectibleIds.formUnion(ids.filter { $0 > 0 })
        self.needsMarketplacePurchaseMigration = false
    }

    private static func addingGrant(_ amount: Int64, to balance: Int64) throws -> Int64 {
        guard amount > 0 else {
            throw LocalGiftsError.invalidAmount
        }
        let (result, overflow) = balance.addingReportingOverflow(amount)
        guard !overflow else {
            throw LocalGiftsError.balanceOverflow
        }
        return result
    }

    /// Repeating a request with the same UUID returns its original receipt without another debit.
    @discardableResult
    public mutating func purchase(
        requestId: UUID,
        recipientId: Int64,
        recipientName: String,
        timestamp: Int32,
        kind: LocalGiftReceipt.Kind,
        title: String,
        cost: Int64,
        giftData: Data?,
        text: String? = nil,
        entitiesData: Data? = nil,
        nameHidden: Bool? = nil,
        currency: LocalGiftCurrency = .stars,
        collectibleId: Int64? = nil
    ) throws -> LocalGiftReceipt {
        if let previous = self.receipts.first(where: { $0.id == requestId }) {
            return previous
        }
        guard cost > 0 else {
            throw LocalGiftsError.invalidAmount
        }
        guard currency != .ton || kind == .collectible else {
            throw LocalGiftsError.unsupportedCurrency
        }
        if let collectibleId {
            guard kind == .collectible, collectibleId > 0 else {
                throw LocalGiftsError.invalidAmount
            }
            guard !self.purchasedCollectibleIds.contains(collectibleId) else {
                throw LocalGiftsError.collectibleAlreadyPurchased
            }
        }
        if kind == .stars && cost > Int64(Int32.max) {
            throw LocalGiftsError.starsTransferTooLarge
        }
        let availableBalance = currency == .ton ? self.tonBalanceNano : self.balance
        guard availableBalance >= cost else {
            throw LocalGiftsError.insufficientBalance
        }
        guard self.lastSequence < 1_000_000_000 else {
            throw LocalGiftsError.exhaustedMessageIds
        }
        let nextBalance = availableBalance - cost
        let receipt = LocalGiftReceipt(
            id: requestId,
            sequence: self.lastSequence + 1,
            recipientId: recipientId,
            recipientName: recipientName,
            timestamp: timestamp,
            kind: kind,
            currency: currency,
            title: title,
            cost: cost,
            balanceAfter: nextBalance,
            giftData: giftData,
            text: text,
            entitiesData: entitiesData,
            nameHidden: nameHidden,
            collectibleId: collectibleId
        )
        self.lastSequence = receipt.sequence
        if currency == .ton {
            self.tonBalanceNano = nextBalance
        } else {
            self.balance = nextBalance
        }
        self.receipts.append(receipt)
        if let collectibleId {
            self.purchasedCollectibleIds.insert(collectibleId)
        }
        return receipt
    }

    /// Hides the local visualization; the already recorded debit is not refunded.
    public mutating func hideReceipt(_ id: UUID) {
        self.receipts.removeAll(where: { $0.id == id })
    }
}

extension LocalGiftReceipt {
    private enum CodingKeys: String, CodingKey {
        case id, sequence, recipientId, recipientName, timestamp, kind, currency, title, cost, balanceAfter
        case giftData, text, entitiesData, nameHidden, collectibleId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.sequence = try container.decode(Int32.self, forKey: .sequence)
        self.recipientId = try container.decode(Int64.self, forKey: .recipientId)
        self.recipientName = try container.decode(String.self, forKey: .recipientName)
        self.timestamp = try container.decode(Int32.self, forKey: .timestamp)
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.currency = try container.decodeIfPresent(LocalGiftCurrency.self, forKey: .currency) ?? .stars
        self.title = try container.decode(String.self, forKey: .title)
        self.cost = try container.decode(Int64.self, forKey: .cost)
        self.balanceAfter = try container.decode(Int64.self, forKey: .balanceAfter)
        self.giftData = try container.decodeIfPresent(Data.self, forKey: .giftData)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.entitiesData = try container.decodeIfPresent(Data.self, forKey: .entitiesData)
        self.nameHidden = try container.decodeIfPresent(Bool.self, forKey: .nameHidden)
        self.collectibleId = try container.decodeIfPresent(Int64.self, forKey: .collectibleId)
    }
}

extension LocalGiftsLedger {
    private enum CodingKeys: String, CodingKey {
        case balance, tonBalanceNano, receipts, lastSequence, purchasedCollectibleIds, marketplaceResetId, needsMarketplacePurchaseMigration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.balance = try container.decode(Int64.self, forKey: .balance)
        self.tonBalanceNano = try container.decodeIfPresent(Int64.self, forKey: .tonBalanceNano) ?? 0
        self.receipts = try container.decode([LocalGiftReceipt].self, forKey: .receipts)
        self.lastSequence = try container.decode(Int32.self, forKey: .lastSequence)
        self.purchasedCollectibleIds = try container.decodeIfPresent(Set<Int64>.self, forKey: .purchasedCollectibleIds) ?? []
        self.marketplaceResetId = try container.decodeIfPresent(UUID.self, forKey: .marketplaceResetId)
        self.needsMarketplacePurchaseMigration = try container.decodeIfPresent(Bool.self, forKey: .needsMarketplacePurchaseMigration) ?? !container.contains(.purchasedCollectibleIds)
    }
}

public enum LocalGiftsPersistence {
    public static func load(from url: URL) throws -> LocalGiftsLedger {
        if !FileManager.default.fileExists(atPath: url.path) {
            return LocalGiftsLedger()
        }
        let ledger = try JSONDecoder().decode(LocalGiftsLedger.self, from: Data(contentsOf: url))
        try ledger.validate()
        return ledger
    }

    public static func save(_ ledger: LocalGiftsLedger, to url: URL) throws {
        try ledger.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
    }
}
