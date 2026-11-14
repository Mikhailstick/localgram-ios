import Foundation

/// Filters only the local projection of the marketplace. Prices remain in their exact currency units.
public struct LocalGiftsMarketFilter: Codable, Equatable {
    public enum Currency: String, Codable {
        case any
        case stars
        case gram
    }

    public var enabled: Bool
    public var hidePurchased: Bool
    public var modelQuery: String
    public var currency: Currency
    public var minimumPrice: Int64?
    public var maximumPrice: Int64?

    public init(enabled: Bool = false, hidePurchased: Bool = true, modelQuery: String = "", currency: Currency = .any, minimumPrice: Int64? = nil, maximumPrice: Int64? = nil) {
        self.enabled = enabled
        self.hidePurchased = hidePurchased
        self.modelQuery = modelQuery
        self.currency = currency
        self.minimumPrice = minimumPrice
        self.maximumPrice = maximumPrice
    }

    public var isValid: Bool {
        if let minimumPrice = self.minimumPrice, minimumPrice < 0 { return false }
        if let maximumPrice = self.maximumPrice, maximumPrice < 0 { return false }
        if let minimumPrice = self.minimumPrice, let maximumPrice = self.maximumPrice, minimumPrice > maximumPrice { return false }
        if self.currency == .any && (self.minimumPrice != nil || self.maximumPrice != nil) { return false }
        return true
    }

    public mutating func selectCurrency(_ currency: Currency) {
        guard self.currency != currency else { return }
        self.currency = currency
        self.minimumPrice = nil
        self.maximumPrice = nil
    }

    public func includes(modelName: String?, starsPrice: Int64?, gramPriceNano: Int64?, isPurchased: Bool, isLocalMode: Bool) -> Bool {
        guard isLocalMode else { return true }
        // Turning filters off restores the original local behavior: bought NFTs stay hidden.
        guard self.enabled, self.isValid else { return !isPurchased }
        if self.hidePurchased && isPurchased { return false }
        let query = self.modelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            guard let modelName, modelName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return false }
        }
        let price: Int64?
        switch self.currency {
        case .any: return true
        case .stars: price = starsPrice
        case .gram: price = gramPriceNano
        }
        guard let price, price >= 0 else { return false }
        if let minimumPrice = self.minimumPrice, price < minimumPrice { return false }
        if let maximumPrice = self.maximumPrice, price > maximumPrice { return false }
        return true
    }
}
