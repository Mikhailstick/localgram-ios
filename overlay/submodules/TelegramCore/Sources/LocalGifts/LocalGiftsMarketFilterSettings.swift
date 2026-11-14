import Foundation
import GGCore

extension LocalGiftsMarketFilter: GGSettingValue {
}

public enum LocalGiftsMarketFilterSettings {
    public static let filter = GGAccountSetting<LocalGiftsMarketFilter>("localGifts.marketFilter", default: LocalGiftsMarketFilter())

    public static func declare() {
        let _ = self.filter
    }

    public static func includes(_ gift: StarGift, filter: LocalGiftsMarketFilter, purchasedIds: Set<Int64>, isLocalMode: Bool) -> Bool {
        guard case let .unique(uniqueGift) = gift else { return true }
        let modelName = uniqueGift.attributes.compactMap { attribute -> String? in
            if case let .model(name, _, _, _) = attribute { return name }
            return nil
        }.first
        return filter.includes(
            modelName: modelName,
            starsPrice: LocalGiftsStore.starsPrice(for: gift),
            gramPriceNano: LocalGiftsStore.tonPriceNano(for: gift),
            isPurchased: purchasedIds.contains(uniqueGift.id),
            isLocalMode: isLocalMode
        )
    }
}
