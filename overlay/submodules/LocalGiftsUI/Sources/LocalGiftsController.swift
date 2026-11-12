import AccountContext
import AsyncDisplayKit
import ComponentFlow
import Display
import Foundation
import GiftAnimationComponent
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

private final class LocalGiftPreviewCell: UITableViewCell {
    private var animation = ComponentView<Empty>()
    private var renderedFileId: Int64?
    private let titleLabel = UILabel()
    private let priceLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.titleLabel.font = .systemFont(ofSize: 17, weight: .medium)
        self.titleLabel.numberOfLines = 2
        self.priceLabel.font = .systemFont(ofSize: 15)
        self.priceLabel.textColor = .secondaryLabel
        self.contentView.addSubview(self.titleLabel)
        self.contentView.addSubview(self.priceLabel)
        self.accessoryType = .disclosureIndicator
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(gift: StarGift, context: AccountContext, theme: PresentationTheme, marketplaceType: Bool) {
        let file: TelegramMediaFile?
        switch gift {
        case let .generic(gift):
            file = gift.file
        case let .unique(gift):
            file = gift.attributes.compactMap { attribute -> TelegramMediaFile? in
                if case let .model(_, file, _, _) = attribute { return file }
                return nil
            }.first
        }
        if self.renderedFileId != file?.fileId.id {
            self.animation.view?.removeFromSuperview()
            self.animation = ComponentView<Empty>()
            self.renderedFileId = file?.fileId.id
        }
        _ = self.animation.update(
            transition: .immediate,
            component: AnyComponent(GiftAnimationComponent(context: context, theme: theme, file: file, still: true, size: CGSize(width: 76, height: 76))),
            environment: {},
            containerSize: CGSize(width: 76, height: 76)
        )
        if let view = self.animation.view, view.superview == nil {
            self.contentView.addSubview(view)
        }
        self.titleLabel.text = LocalGiftsStore.title(for: gift)
        if marketplaceType {
            self.priceLabel.text = "Открыть коллекционные варианты"
        } else if let price = LocalGiftsStore.starsPrice(for: gift) {
            self.priceLabel.text = "★ \(price)"
        } else {
            self.priceLabel.text = "Нет цены в Stars"
        }
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.animation.view?.frame = CGRect(x: 12, y: (self.contentView.bounds.height - 76) / 2, width: 76, height: 76)
        let width = max(0, self.contentView.bounds.width - 108)
        self.titleLabel.frame = CGRect(x: 100, y: 16, width: width, height: 44)
        self.priceLabel.frame = CGRect(x: 100, y: 64, width: width, height: 22)
    }
}

@available(iOS 14.0, *)
public final class LocalGiftsController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Mode {
        case home
        case regular
        case marketplaceTypes
        case marketplace(Int64)
    }

    private let context: AccountContext
    private let presentationData: PresentationData
    private let store: LocalGiftsStore
    private let mode: Mode
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let stateDisposable = MetaDisposable()
    private let catalogDisposable = MetaDisposable()
    private let updateDisposable = MetaDisposable()
    private let selectionDisposable = MetaDisposable()
    private let lookupDisposable = MetaDisposable()
    private var resaleContext: ResaleGiftsContext?
    private var ledger: LocalGiftsLedger
    private var recipient: EnginePeer?
    private var gifts: [StarGift] = []
    private var loading = true
    private var canLoadMore = false

    public convenience init(context: AccountContext) {
        self.init(context: context, mode: .home, recipient: nil)
    }

    private init(context: AccountContext, mode: Mode, recipient: EnginePeer?) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.store = LocalGiftsStore.shared(accountPeerId: context.account.peerId)
        self.ledger = self.store.snapshot()
        self.mode = mode
        self.recipient = recipient
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData, style: .glass))
        self.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        self.table.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        switch mode {
        case .home: self.title = "Мои функции"
        case .regular: self.title = "Подарки"
        case .marketplaceTypes: self.title = "NFT-маркетплейс"
        case .marketplace: self.title = "Коллекционные подарки"
        }
        self.table.dataSource = self
        self.table.delegate = self
        self.table.register(LocalGiftPreviewCell.self, forCellReuseIdentifier: "gift")
        self.table.contentInsetAdjustmentBehavior = .never
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        self.stateDisposable.dispose()
        self.catalogDisposable.dispose()
        self.updateDisposable.dispose()
        self.selectionDisposable.dispose()
        self.lookupDisposable.dispose()
    }

    public override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        self.displayNode.view.addSubview(self.table)
        self.displayNodeDidLoad()
        self.stateDisposable.set((self.store.state |> deliverOnMainQueue).start(next: { [weak self] ledger in
            self?.ledger = ledger
            self?.reload()
        }))
        switch self.mode {
        case .home:
            self.loading = false
        case .regular, .marketplaceTypes:
            self.catalogDisposable.set((self.context.engine.payments.cachedStarGifts() |> deliverOnMainQueue).start(next: { [weak self] gifts in
                guard let self else { return }
                self.loading = gifts == nil
                self.gifts = gifts ?? []
                if case .marketplaceTypes = self.mode {
                    self.gifts = self.gifts.filter { gift in
                        if case let .generic(gift) = gift { return gift.upgradeStars != nil || (gift.availability?.resale ?? 0) > 0 }
                        return false
                    }
                }
                self.reload()
            }))
            self.updateCatalog()
        case let .marketplace(giftId):
            let resale = ResaleGiftsContext(account: self.context.account, giftId: giftId, forCrafting: false)
            self.resaleContext = resale
            resale.updateStarsOnly(true)
            self.catalogDisposable.set((resale.state |> deliverOnMainQueue).start(next: { [weak self] state in
                guard let self else { return }
                self.gifts = state.gifts.filter { LocalGiftsStore.starsPrice(for: $0) != nil }
                switch state.dataState {
                case .loading: self.loading = true; self.canLoadMore = false
                case let .ready(canLoadMore, _): self.loading = false; self.canLoadMore = canLoadMore
                }
                self.reload()
            }))
        }
        self.reload()
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: self.table, frame: CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top)))
        self.table.contentInset.bottom = layout.intrinsicInsets.bottom
    }

    private var isHome: Bool { if case .home = self.mode { return true }; return false }
    private var visibleReceipts: [LocalGiftReceipt] { return Array(self.ledger.receipts.reversed()) }

    private func reload() {
        guard self.isNodeLoaded else { return }
        self.table.reloadData()
        if !self.isHome && self.gifts.isEmpty {
            let label = UILabel()
            label.text = self.loading ? "Загрузка каталога…" : "Здесь пока нет подарков.\nПотяни вниз, чтобы повторить загрузку."
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            self.table.backgroundView = label
            if self.table.refreshControl == nil {
                let refresh = UIRefreshControl()
                refresh.addTarget(self, action: #selector(self.refreshCatalog), for: .valueChanged)
                self.table.refreshControl = refresh
            }
        } else {
            self.table.backgroundView = nil
        }
        if !self.loading { self.table.refreshControl?.endRefreshing() }
    }

    @objc private func refreshCatalog() {
        if let resaleContext = self.resaleContext {
            resaleContext.reload()
        } else {
            self.updateCatalog()
        }
    }

    private func updateCatalog() {
        self.loading = true
        self.updateDisposable.set((self.context.engine.payments.keepStarGiftsUpdated() |> deliverOnMainQueue).start(
            completed: { [weak self] in
                self?.loading = false
                self?.reload()
            }
        ))
    }

    public func numberOfSections(in tableView: UITableView) -> Int { return self.isHome ? 4 : 1 }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if !self.isHome { return self.gifts.count + (self.canLoadMore ? 1 : 0) }
        switch section {
        case 0: return 3
        case 1: return 3
        case 2: return self.visibleReceipts.count
        default: return 1
        }
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if !self.isHome { return self.recipient.map { "Для \(self.name(of: $0)) · ★ \(self.ledger.balance)" } }
        return ["Звёзды", "Подарки", "История", nil][section]
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if self.isHome && section == 1 { return "Баланс и отправленные подарки видны только тебе в этом клиенте." }
        if self.isHome && section == 2 && self.ledger.receipts.isEmpty { return "Отправленные подарки появятся здесь и в выбранной переписке." }
        return nil
    }

    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return !self.isHome && indexPath.row < self.gifts.count ? 104 : UITableView.automaticDimension
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if !self.isHome && indexPath.row < self.gifts.count {
            let cell = tableView.dequeueReusableCell(withIdentifier: "gift", for: indexPath) as! LocalGiftPreviewCell
            let marketplaceType: Bool
            if case .marketplaceTypes = self.mode { marketplaceType = true } else { marketplaceType = false }
            cell.configure(gift: self.gifts[indexPath.row], context: self.context, theme: self.presentationData.theme, marketplaceType: marketplaceType)
            return cell
        }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .disclosureIndicator
        if !self.isHome {
            content.text = self.loading ? "Загрузка…" : "Загрузить ещё"
        } else {
            switch (indexPath.section, indexPath.row) {
            case (0, 0): content.text = "★ \(self.ledger.balance)"; content.secondaryText = "Изменить баланс Stars"; content.image = UIImage(systemName: "star.fill")
            case (0, 1): content.text = "Получатель"; content.secondaryText = self.recipient.map(self.name) ?? "Выбрать человека"; content.image = UIImage(systemName: "person.crop.circle")
            case (0, 2): content.text = "Отправить звёзды"; content.image = UIImage(systemName: "star.circle")
            case (1, 0): content.text = "Обычные подарки"; content.image = UIImage(systemName: "gift.fill")
            case (1, 1): content.text = "NFT через маркетплейс"; content.image = UIImage(systemName: "sparkles")
            case (1, 2): content.text = "NFT по ссылке"; content.image = UIImage(systemName: "link")
            case (2, _):
                let receipt = self.visibleReceipts[indexPath.row]
                content.text = receipt.title
                content.secondaryText = "\(receipt.recipientName) · −\(receipt.cost) ★ · остаток \(receipt.balanceAfter)"
                content.secondaryTextProperties.numberOfLines = 2
                content.image = UIImage(systemName: receipt.kind == .stars ? "star.fill" : "gift.fill")
            default:
                content.text = "Сбросить локальные подарки и баланс"
                content.textProperties.color = .systemRed
                cell.accessoryType = .none
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if !self.isHome {
            if indexPath.row == self.gifts.count { self.resaleContext?.loadMore(); return }
            let gift = self.gifts[indexPath.row]
            if case .marketplaceTypes = self.mode, case let .generic(generic) = gift {
                self.pushCatalog(.marketplace(generic.id))
            } else {
                self.confirmGift(gift)
            }
            return
        }
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            self.requestAmount(title: "Баланс Stars", initial: "\(self.ledger.balance)") { [weak self] amount in
                self?.perform { try self?.store.setBalance(amount) }
            }
        case (0, 1): self.chooseRecipient {}
        case (0, 2):
            self.withRecipient { [weak self] in
                guard let self else { return }
                self.requestAmount(title: "Сколько звёзд отправить?", initial: "") { [weak self] amount in
                    guard let self, let recipient = self.recipient else { return }
                    let requestId = UUID()
                    self.confirm(title: "Отправить \(amount) ★", message: self.name(of: recipient), destructive: false) { [weak self] in
                        guard let self else { return }
                        self.perform { _ = try self.store.sendStars(amount, recipientId: recipient.id, recipientName: self.name(of: recipient), requestId: requestId) }
                    }
                }
            }
        case (1, 0): self.withRecipient { [weak self] in self?.pushCatalog(.regular) }
        case (1, 1): self.withRecipient { [weak self] in self?.pushCatalog(.marketplaceTypes) }
        case (1, 2): self.withRecipient { [weak self] in self?.lookupGift() }
        case (2, _):
            let receipt = self.visibleReceipts[indexPath.row]
            let chat = self.context.sharedContext.makeChatController(context: self.context,
                chatLocation: .peer(EnginePeer.Id(receipt.recipientId)), subject: nil, botStart: nil, mode: .standard(.default), params: nil)
            (self.navigationController as? NavigationController)?.pushViewController(chat)
        default:
            self.confirm(title: "Сбросить мои функции?", message: "Виртуальный баланс станет нулевым, локальные подарки исчезнут.", destructive: true) { [weak self] in
                self?.perform { try self?.store.reset() }
            }
        }
    }

    public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard self.isHome, indexPath.section == 2 else { return nil }
        let receipt = self.visibleReceipts[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: "Скрыть") { [weak self] _, _, completed in
            guard let self else { completed(false); return }
            do { try self.store.hideReceipt(receipt.id); completed(true) } catch { self.showError(error); completed(false) }
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    private func pushCatalog(_ mode: Mode) {
        (self.navigationController as? NavigationController)?.pushViewController(LocalGiftsController(context: self.context, mode: mode, recipient: self.recipient))
    }

    private func name(of peer: EnginePeer) -> String {
        switch peer.indexName {
        case let .title(title, _): return title
        case let .personName(first, last, _, _): return [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private func withRecipient(_ action: @escaping () -> Void) {
        if self.recipient == nil { self.chooseRecipient(action) } else { action() }
    }

    private func chooseRecipient(_ completion: @escaping () -> Void) {
        let selector = self.context.sharedContext.makeContactSelectionController(ContactSelectionControllerParams(
            context: self.context, title: { _ in "Получатель подарка" }, displayDeviceContacts: false,
            isPeerEnabled: { peer in
                if case let .peer(peer, _, _) = peer { return peer.id.namespace == Namespaces.Peer.CloudUser }
                return false
            }
        ))
        self.selectionDisposable.set((selector.result |> take(1) |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, let result, let first = result.0.first, case let .peer(peer, _, _) = first else { return }
            self.recipient = peer
            self.reload()
            Queue.mainQueue().after(0.25, completion)
        }))
        self.present(selector, in: .window(.root))
    }

    private func confirmGift(_ gift: StarGift) {
        guard let recipient = self.recipient else { return }
        guard let price = LocalGiftsStore.starsPrice(for: gift) else { self.showError(LocalGiftsError.unsupportedCurrency); return }
        let requestId = UUID()
        self.confirm(title: LocalGiftsStore.title(for: gift), message: "\(self.name(of: recipient))\nСтоимость: \(price) ★", destructive: false) { [weak self] in
            guard let self else { return }
            self.perform { _ = try self.store.sendGift(gift, recipientId: recipient.id, recipientName: self.name(of: recipient), requestId: requestId) }
        }
    }

    private func lookupGift() {
        let alert = UIAlertController(title: "NFT по ссылке", message: "Вставь t.me/nft/Название-номер или название-номер.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "t.me/nft/PlushPepe-123"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Найти", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let slug: String
            if let url = URL(string: text.hasPrefix("t.me/") ? "https://" + text : text), let host = url.host {
                let parts = url.path.split(separator: "/")
                guard ["t.me", "telegram.me"].contains(host.lowercased()), parts.count == 2, parts[0] == "nft" else {
                    self.showMessage("Нужна ссылка вида t.me/nft/Название-номер."); return
                }
                slug = String(parts[1])
            } else { slug = text }
            guard slug.range(of: "^[A-Za-z0-9]+-[0-9]+$", options: .regularExpression) != nil else {
                self.showMessage("Проверь название и номер коллекционного подарка."); return
            }
            self.lookupDisposable.set((self.context.engine.payments.getUniqueStarGift(slug: slug) |> deliverOnMainQueue).start(
                next: { [weak self] gift in
                    Queue.mainQueue().after(0.2) { self?.confirmGift(.unique(gift)) }
                },
                error: { [weak self] _ in self?.showMessage("Не удалось загрузить подарок. Проверь ссылку и соединение.") }
            ))
        })
        self.present(alert, animated: true)
    }

    private func requestAmount(title: String, initial: String, action: @escaping (Int64) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .numberPad; $0.text = initial; $0.placeholder = "Количество Stars" }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Готово", style: .default) { [weak self, weak alert] _ in
            let text = (alert?.textFields?.first?.text ?? "").filter { !$0.isWhitespace }
            guard let amount = Int64(text), amount >= 0 else { self?.showError(LocalGiftsError.invalidAmount); return }
            action(amount)
        })
        self.present(alert, animated: true)
    }

    private func confirm(title: String, message: String, destructive: Bool, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: destructive ? "Сбросить" : "Отправить", style: destructive ? .destructive : .default) { _ in action() })
        self.present(alert, animated: true)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.showError(error) }
    }

    private func showError(_ error: Error) {
        let text: String
        switch error {
        case LocalGiftsError.insufficientBalance: text = "Недостаточно виртуальных Stars. Измени баланс в разделе «Мои функции»."
        case LocalGiftsError.invalidAmount: text = "Введи целое положительное количество Stars. Баланс можно установить в ноль."
        case LocalGiftsError.starsTransferTooLarge: text = "За одну отправку можно показать до 2 147 483 647 Stars. Виртуальный баланс может быть больше."
        case LocalGiftsError.unsupportedCurrency: text = "У подарка нет цены в Stars. Выбери предложение маркетплейса с ценой ★."
        case LocalGiftsError.unreadableStorage: text = "Не удалось прочитать локальные подарки. Можно сбросить их в разделе «Мои функции»."
        default: text = "Не удалось сохранить локальные данные. Баланс не был изменён."
        }
        self.showMessage(text)
    }

    private func showMessage(_ text: String) {
        Queue.mainQueue().after(0.3) { [weak self] in
            let alert = UIAlertController(title: "Мои функции", message: text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(alert, animated: true)
        }
    }
}
