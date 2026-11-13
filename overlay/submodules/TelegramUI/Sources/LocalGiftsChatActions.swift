import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

extension ChatControllerImpl {
    /// Local gift taps never enter the server-backed purchase, upgrade or transfer UI.
    func showLocalGiftReceipt(messageId: EngineMessage.Id, allowDelete: Bool) {
        let store = LocalGiftsStore.shared(accountPeerId: self.context.account.peerId)
        guard let receipt = store.receipt(sequence: messageId.id, recipientId: messageId.peerId) else { return }
        let cost = receipt.currency == .ton ? "\(LocalTonAmount.format(receipt.cost)) GRAM" : "\(receipt.cost) ★"
        let balance = receipt.currency == .ton ? "\(LocalTonAmount.format(receipt.balanceAfter)) GRAM" : "\(receipt.balanceAfter) ★"
        let alert = UIAlertController(
            title: receipt.title,
            message: "\(receipt.recipientName)\nСтоимость: \(cost)\nБаланс после отправки: \(balance)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
        if allowDelete {
            alert.addAction(UIAlertAction(title: "Скрыть подарок", style: .destructive) { [weak self] _ in
                do { try store.hideReceipt(receipt.id) } catch {
                    Queue.mainQueue().after(0.3) { [weak self] in
                        let errorAlert = UIAlertController(title: "Фейк-подарки", message: "Не удалось сохранить изменение.", preferredStyle: .alert)
                        errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                        self?.present(errorAlert, animated: true)
                    }
                }
            })
        }
        self.present(alert, animated: true)
    }
}
