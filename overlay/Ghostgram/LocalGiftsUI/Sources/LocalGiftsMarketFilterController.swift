import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import GGCore
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

@available(iOS 14.0, *)
public final class LocalGiftsMarketFilterController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let presentationData: PresentationData
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let disposable = MetaDisposable()
    private var filter: LocalGiftsMarketFilter

    public init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.filter = LocalGiftsMarketFilterSettings.filter.value(for: context.account.id.gg)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        self.title = "Фильтры маркета"
        self.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        self.table.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        self.table.dataSource = self
        self.table.delegate = self
        self.table.contentInsetAdjustmentBehavior = .never
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { self.disposable.dispose() }

    public override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        self.displayNode.view.addSubview(self.table)
        self.displayNodeDidLoad()
        self.disposable.set((LocalGiftsMarketFilterSettings.filter.signal(for: self.context.account.id.gg)
        |> deliverOnMainQueue).start(next: { [weak self] filter in
            guard let self else { return }
            self.filter = filter
            self.table.reloadData()
        }))
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: self.table, frame: CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top)))
        self.table.contentInset.bottom = layout.intrinsicInsets.bottom
    }

    public func numberOfSections(in tableView: UITableView) -> Int { return LocalGiftsStore.isEnabled ? 4 : 0 }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return [2, 1, 3, 1][section]
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return [nil, "Модель NFT", "Цена", nil][section]
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return "Фильтры действуют только в локальном режиме этого аккаунта. Показанные купленные NFT нельзя купить повторно. Когда фильтры выключены, купленные NFT скрыты."
        case 1: return "Поиск по части названия модели, без учёта регистра."
        case 2: return "Stars — целые звёзды, GRAM — точная сумма TON до 9 знаков после запятой. Пустая граница не ограничивает цену. При смене валюты диапазон очищается."
        default: return nil
        }
    }

    private var currencyTitle: String {
        switch self.filter.currency {
        case .any: return "Любая"
        case .stars: return "Stars"
        case .gram: return "GRAM (TON)"
        }
    }

    private func priceTitle(_ price: Int64?) -> String {
        guard let price else { return "Без ограничения" }
        return self.filter.currency == .gram ? "\(LocalTonAmount.format(price)) GRAM" : "\(price) ★"
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.color = self.presentationData.theme.list.itemPrimaryTextColor
        cell.backgroundColor = self.presentationData.theme.list.itemBlocksBackgroundColor
        cell.accessoryType = .disclosureIndicator
        var available = self.filter.enabled
        switch (indexPath.section, indexPath.row) {
        case (0, 0), (0, 1):
            let enabledSwitch = UISwitch()
            enabledSwitch.onTintColor = self.presentationData.theme.list.itemAccentColor
            if indexPath.row == 0 {
                content.text = "Включить фильтры"
                available = true
                enabledSwitch.isOn = self.filter.enabled
                enabledSwitch.addTarget(self, action: #selector(self.toggleEnabled(_:)), for: .valueChanged)
            } else {
                content.text = "Скрывать купленные"
                enabledSwitch.isOn = self.filter.hidePurchased
                enabledSwitch.addTarget(self, action: #selector(self.togglePurchased(_:)), for: .valueChanged)
            }
            enabledSwitch.isEnabled = available
            cell.accessoryView = enabledSwitch
            cell.selectionStyle = .none
        case (1, 0): content.text = "Название модели"; content.secondaryText = self.filter.modelQuery.isEmpty ? "Любая модель" : self.filter.modelQuery
        case (2, 0): content.text = "Валюта"; content.secondaryText = self.currencyTitle
        case (2, 1): content.text = "Минимальная цена"; content.secondaryText = self.priceTitle(self.filter.minimumPrice); available = available && self.filter.currency != .any
        case (2, 2): content.text = "Максимальная цена"; content.secondaryText = self.priceTitle(self.filter.maximumPrice); available = available && self.filter.currency != .any
        default:
            content.text = "Сбросить фильтры"
            content.textProperties.color = self.presentationData.theme.list.itemAccentColor
            available = true
            cell.accessoryType = .none
        }
        cell.contentConfiguration = content
        cell.isUserInteractionEnabled = available
        cell.contentView.alpha = available ? 1.0 : 0.45
        return cell
    }

    @objc private func toggleEnabled(_ sender: UISwitch) {
        var filter = self.filter
        filter.enabled = sender.isOn
        self.save(filter)
    }

    @objc private func togglePurchased(_ sender: UISwitch) {
        var filter = self.filter
        filter.hidePurchased = sender.isOn
        self.save(filter)
    }

    private func save(_ filter: LocalGiftsMarketFilter) {
        guard LocalGiftsStore.isEnabled else { return }
        guard filter.isValid else {
            let alert = UIAlertController(title: "Проверь диапазон", message: "Цена не может быть отрицательной, а минимум — больше максимума.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "ОК", style: .default))
            self.present(alert, animated: true)
            return
        }
        LocalGiftsMarketFilterSettings.filter.set(filter, for: self.context.account.id.gg)
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard LocalGiftsStore.isEnabled else { return }
        if indexPath.section == 3 {
            self.save(LocalGiftsMarketFilter())
            return
        }
        guard self.filter.enabled else { return }
        if indexPath.section == 1 {
            let alert = UIAlertController(title: "Название модели", message: "Введи часть названия или очисти поле, чтобы показать все модели.", preferredStyle: .alert)
            alert.addTextField { field in
                field.text = self.filter.modelQuery
                field.autocorrectionType = .no
                field.autocapitalizationType = .none
                field.clearButtonMode = .whileEditing
            }
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            alert.addAction(UIAlertAction(title: "Применить", style: .default, handler: { [weak self, weak alert] _ in
                guard let self else { return }
                var filter = self.filter
                filter.modelQuery = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                self.save(filter)
            }))
            self.present(alert, animated: true)
        } else if indexPath.section == 2 && indexPath.row == 0 {
            let alert = UIAlertController(title: "Валюта", message: nil, preferredStyle: .actionSheet)
            let currencies: [(String, LocalGiftsMarketFilter.Currency)] = [("Любая", .any), ("Stars", .stars), ("GRAM (TON)", .gram)]
            for (title, currency) in currencies {
                alert.addAction(UIAlertAction(title: title, style: .default, handler: { [weak self] _ in
                    guard let self else { return }
                    var filter = self.filter
                    filter.selectCurrency(currency)
                    self.save(filter)
                }))
            }
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            alert.popoverPresentationController?.sourceView = tableView
            alert.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
            self.present(alert, animated: true)
        } else if indexPath.section == 2 && self.filter.currency != .any {
            self.editPrice(minimum: indexPath.row == 1)
        }
    }

    private func editPrice(minimum: Bool) {
        let currency = self.filter.currency
        let price = minimum ? self.filter.minimumPrice : self.filter.maximumPrice
        let alert = UIAlertController(title: minimum ? "Минимальная цена" : "Максимальная цена", message: currency == .gram ? "Цена в GRAM (TON)" : "Цена в целых Stars", preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = currency == .gram ? .decimalPad : .numberPad
            field.placeholder = "Без ограничения"
            if let price { field.text = currency == .gram ? LocalTonAmount.format(price) : "\(price)" }
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Применить", style: .default, handler: { [weak self, weak alert] _ in
            guard let self else { return }
            // A backup restore may have changed currencies while the editor was open.
            guard self.filter.currency == currency else { return }
            let text = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let amount = currency == .gram ? LocalTonAmount.parse(text) : Int64(text)
            if !text.isEmpty && (amount.map { $0 < 0 } ?? true) {
                let error = UIAlertController(title: "Неверная цена", message: currency == .gram ? "Введи неотрицательную сумму с точностью до 9 знаков после запятой." : "Введи неотрицательное целое число Stars.", preferredStyle: .alert)
                error.addAction(UIAlertAction(title: "ОК", style: .default))
                self.present(error, animated: true)
                return
            }
            var filter = self.filter
            if minimum { filter.minimumPrice = amount } else { filter.maximumPrice = amount }
            self.save(filter)
        }))
        self.present(alert, animated: true)
    }
}
