import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit
import Display
import TelegramPresentationData
import PresentationDataUtils

extension ChatControllerImpl {
    /// Reuse Telegram's gift and operation sheets with display-only local data.
    func showLocalGiftReceipt(message: EngineMessage, allowDelete: Bool) {
        let store = LocalGiftsStore.shared(accountPeerId: self.context.account.peerId)
        guard let receipt = store.receipt(sequence: message.id.id, recipientId: message.id.peerId) else { return }
        let openDetails = { [weak self] in
            guard let self else { return }
            if receipt.kind == .stars {
                self.push(self.context.sharedContext.makeStarsGiftScreen(context: self.context, message: message))
            } else {
                let controller = self.context.sharedContext.makeGiftViewScreen(context: self.context, message: message, shareStory: nil)
                self.push(controller)
            }
        }
        if allowDelete {
            let sheet = ActionSheetController(presentationData: self.presentationData)
            sheet.setItemGroups([
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: "Подробнее", color: .accent, action: { [weak sheet] in
                        sheet?.dismissAnimated()
                        openDetails()
                    }),
                    ActionSheetButtonItem(title: "Скрыть подарок", color: .destructive, action: { [weak self, weak sheet] in
                        sheet?.dismissAnimated()
                        do { try store.hideReceipt(receipt.id) } catch {
                            guard let self else { return }
                            self.present(textAlertController(context: self.context, title: "Фейк-подарки", text: "Не удалось сохранить изменение.", actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                        }
                    })
                ]),
                ActionSheetItemGroup(items: [ActionSheetButtonItem(title: self.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                })])
            ])
            self.present(sheet, in: .window(.root))
        } else {
            openDetails()
        }
    }
}
