import Foundation

public enum LocalGiftsError: Error, Equatable {
    case invalidAmount
    case starsTransferTooLarge
    case insufficientBalance
    case unsupportedCurrency
    case exhaustedMessageIds
    case unreadableStorage
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
    public let title: String
    public let cost: Int64
    public let balanceAfter: Int64
    public let giftData: Data?
}

/// Account-local display state. This model has no Telegram network or payment dependency.
public struct LocalGiftsLedger: Codable, Equatable {
    public private(set) var balance: Int64
    public private(set) var receipts: [LocalGiftReceipt]
    public private(set) var lastSequence: Int32

    public init() {
        self.balance = 0
        self.receipts = []
        self.lastSequence = 0
    }

    public func validate() throws {
        guard self.balance >= 0, self.lastSequence >= 0, self.lastSequence <= 1_000_000_000 else {
            throw LocalGiftsError.unreadableStorage
        }
        var ids = Set<UUID>()
        var sequences = Set<Int32>()
        for receipt in self.receipts {
            guard receipt.cost > 0, receipt.balanceAfter >= 0,
                  receipt.kind != .stars || receipt.cost <= Int64(Int32.max),
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
        giftData: Data?
    ) throws -> LocalGiftReceipt {
        if let previous = self.receipts.first(where: { $0.id == requestId }) {
            return previous
        }
        guard cost > 0 else {
            throw LocalGiftsError.invalidAmount
        }
        if kind == .stars && cost > Int64(Int32.max) {
            throw LocalGiftsError.starsTransferTooLarge
        }
        guard self.balance >= cost else {
            throw LocalGiftsError.insufficientBalance
        }
        guard self.lastSequence < 1_000_000_000 else {
            throw LocalGiftsError.exhaustedMessageIds
        }
        let nextBalance = self.balance - cost
        let receipt = LocalGiftReceipt(
            id: requestId,
            sequence: self.lastSequence + 1,
            recipientId: recipientId,
            recipientName: recipientName,
            timestamp: timestamp,
            kind: kind,
            title: title,
            cost: cost,
            balanceAfter: nextBalance,
            giftData: giftData
        )
        self.lastSequence = receipt.sequence
        self.balance = nextBalance
        self.receipts.append(receipt)
        return receipt
    }

    /// Hides the local visualization; the already recorded debit is not refunded.
    public mutating func hideReceipt(_ id: UUID) {
        self.receipts.removeAll(where: { $0.id == id })
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
