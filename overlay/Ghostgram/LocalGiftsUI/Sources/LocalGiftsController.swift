import AccountContext
import AsyncDisplayKit
import ComponentFlow
import Display
import Foundation
import GiftAnimationComponent
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
        } else {
            var prices: [String] = []
            if let price = LocalGiftsStore.starsPrice(for: gift) { prices.append("★ \(price)") }
            if let price = LocalGiftsStore.tonPriceNano(for: gift) { prices.append("\(LocalTonAmount.format(price)) GRAM") }
            self.priceLabel.text = prices.isEmpty ? "Нет предложения на продажу" : prices.joined(separator: " · ")
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

/// Stable targets shared by the LocalGram menu and Telegram's settings search.
public enum LocalGiftsSearchTarget: String {
    case starsBalance
    case gramBalance
    case recipient
    case sendStars
    case giftCatalog
    case marketplace
    case starsHistory
    case gramHistory
    case giftLink
    case history
    case reset
    case marketplaceReset
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
    private let purchaseDisposable = MetaDisposable()
    private var purchaseInProgress = false
    private var resaleContext: ResaleGiftsContext?
    private var ledger: LocalGiftsLedger
    private var recipient: EnginePeer?
    private var gifts: [StarGift] = []
    private var loading = true
    private var canLoadMore = false
    private var searchTarget: LocalGiftsSearchTarget?
    private var didApplySearchTarget = false

    public convenience init(context: AccountContext, searchTarget: LocalGiftsSearchTarget? = nil) {
        self.init(context: context, mode: .home, recipient: nil)
        self.searchTarget = searchTarget
    }

    private init(context: AccountContext, mode: Mode, recipient: EnginePeer?) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.store = LocalGiftsStore.shared(accountPeerId: context.account.peerId)
        self.ledger = self.store.snapshot()
        self.mode = mode
        self.recipient = recipient
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        self.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        self.table.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        switch mode {
        case .home: self.title = "Фейк-подарки"
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
        self.purchaseDisposable.dispose()
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
            resale.updateStarsOnly(false)
            self.catalogDisposable.set((resale.state |> deliverOnMainQueue).start(next: { [weak self] state in
                guard let self else { return }
                self.gifts = state.gifts.filter { LocalGiftsStore.starsPrice(for: $0) != nil || LocalGiftsStore.tonPriceNano(for: $0) != nil }
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

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard self.isHome, !self.didApplySearchTarget, let target = self.searchTarget else {
            return
        }
        self.didApplySearchTarget = true
        if target == .history {
            self.table.scrollRectToVisible(self.table.rectForHeader(inSection: 2), animated: true)
            return
        }
        let indexPath: IndexPath
        switch target {
        case .starsBalance: indexPath = IndexPath(row: 0, section: 0)
        case .gramBalance: indexPath = IndexPath(row: 3, section: 0)
        case .recipient: indexPath = IndexPath(row: 1, section: 0)
        case .sendStars: indexPath = IndexPath(row: 2, section: 0)
        case .giftCatalog: indexPath = IndexPath(row: 0, section: 1)
        case .marketplace: indexPath = IndexPath(row: 1, section: 1)
        case .starsHistory: indexPath = IndexPath(row: 2, section: 1)
        case .gramHistory: indexPath = IndexPath(row: 3, section: 1)
        case .giftLink: indexPath = IndexPath(row: 4, section: 1)
        case .reset: indexPath = IndexPath(row: 0, section: 3)
        case .marketplaceReset: indexPath = IndexPath(row: 1, section: 3)
        case .history: return
        }
        self.table.scrollToRow(at: indexPath, at: .middle, animated: false)
        if target == .reset || target == .marketplaceReset {
            // Finding a reset highlights its button; it never resets or opens a confirmation.
            self.table.selectRow(at: indexPath, animated: false, scrollPosition: .none)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.table.deselectRow(at: indexPath, animated: true)
            }
            return
        }
        // The original row handler opens the exact editor, picker or gift screen.
        // Search never writes a balance or sends a gift on its own.
        self.tableView(self.table, didSelectRowAt: indexPath)
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
        case 0: return 4
        case 1: return 5
        case 2: return self.visibleReceipts.count
        case 3: return 2
        default: return 1
        }
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if !self.isHome { return self.recipient.map { "Для \(self.name(of: $0)) · ★ \(self.ledger.balance) · \(LocalTonAmount.format(self.ledger.tonBalanceNano)) GRAM" } }
        return ["Баланс", "Подарки", "История", nil][section]
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if self.isHome && section == 1 { return "Баланс и отправленные подарки видны только тебе в этом клиенте." }
        if self.isHome && section == 2 && self.ledger.receipts.isEmpty { return "Отправленные подарки появятся здесь и в выбранной переписке." }
        if self.isHome && section == 3 { return "Сброс покупок в маркете возвращает только актуальные предложения площадки. Балансы и история сохраняются." }
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
            case (0, 3): content.text = "\(LocalTonAmount.format(self.ledger.tonBalanceNano)) GRAM"; content.secondaryText = "Изменить баланс GRAM (TON)"; content.image = UIImage(systemName: "diamond.fill")
            case (1, 0): content.text = "Меню подарков"; content.image = UIImage(systemName: "gift.fill")
            case (1, 1): content.text = "NFT через маркетплейс"; content.image = UIImage(systemName: "sparkles")
            case (1, 2): content.text = "Мои звёзды"; content.image = UIImage(systemName: "star.circle")
            case (1, 3): content.text = "Мои GRAM"; content.image = UIImage(systemName: "diamond")
            case (1, 4): content.text = "NFT по ссылке"; content.image = UIImage(systemName: "link")
            case (2, _):
                let receipt = self.visibleReceipts[indexPath.row]
                content.text = receipt.title
                let cost = receipt.currency == .ton ? "\(LocalTonAmount.format(receipt.cost)) GRAM" : "\(receipt.cost) ★"
                let balance = receipt.currency == .ton ? LocalTonAmount.format(receipt.balanceAfter) : "\(receipt.balanceAfter)"
                content.secondaryText = "\(receipt.recipientName) · −\(cost) · остаток \(balance)"
                content.secondaryTextProperties.numberOfLines = 2
                content.image = UIImage(systemName: receipt.kind == .stars ? "star.fill" : "gift.fill")
            case (3, 1):
                content.text = "Сбросить покупки в маркете"
                content.secondaryText = "Вернуть доступные NFT в каталог"
                content.image = UIImage(systemName: "arrow.clockwise")
                cell.accessoryType = .none
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
        case (0, 3):
            self.requestAmount(title: "Баланс GRAM (TON)", initial: LocalTonAmount.format(self.ledger.tonBalanceNano), currency: .ton) { [weak self] amount in
                self?.perform { try self?.store.setTonBalanceNano(amount) }
            }
        case (0, 1): self.chooseRecipient {}
        case (0, 2):
            self.withRecipient { [weak self] in
                self?.openNativeStarsGift()
            }
        case (1, 0), (1, 1): self.withRecipient { [weak self] in self?.openNativeGiftMenu() }
        case (1, 2):
            guard let starsContext = self.context.starsContext else { return }
            (self.navigationController as? NavigationController)?.pushViewController(
                self.context.sharedContext.makeStarsTransactionsScreen(context: self.context, starsContext: starsContext))
        case (1, 3):
            guard let tonContext = self.context.tonContext else { return }
            (self.navigationController as? NavigationController)?.pushViewController(
                self.context.sharedContext.makeStarsTransactionsScreen(context: self.context, starsContext: tonContext))
        case (1, 4): self.withRecipient { [weak self] in self?.lookupGift() }
        case (2, _):
            let receipt = self.visibleReceipts[indexPath.row]
            let chat = self.context.sharedContext.makeChatController(context: self.context,
                chatLocation: .peer(id: EnginePeer.Id(receipt.recipientId)), subject: nil, botStart: nil, mode: .standard(.default), params: nil)
            (self.navigationController as? NavigationController)?.pushViewController(chat)
        case (3, 1):
            self.confirm(title: "Сбросить покупки в маркете?", message: "Купленные локально NFT снова появятся, если ещё доступны на площадке. Балансы, подарки и история сохранятся.", destructive: false, confirmTitle: "Сбросить") { [weak self] in
                self?.perform { try self?.store.resetMarketplacePurchases() }
            }
        default:
            self.confirm(title: "Сбросить фейк-подарки?", message: "Виртуальный баланс станет нулевым, локальные подарки исчезнут.", destructive: true) { [weak self] in
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

    private func openNativeGiftMenu() {
        guard let recipient = self.recipient, self.context.starsContext != nil else { return }
        self.lookupDisposable.set((self.context.engine.payments.premiumGiftCodeOptions(peerId: recipient.id)
        |> deliverOnMainQueue).start(next: { [weak self] options in
            guard let self else { return }
            let premiumOptions = options.filter { $0.users == 1 }.map {
                CachedPremiumGiftOption(months: $0.months, currency: $0.currency, amount: $0.amount, botUrl: "", storeProductId: $0.storeProductId)
            }
            let controller = self.context.sharedContext.makeGiftOptionsController(context: self.context,
                peerId: recipient.id, premiumOptions: premiumOptions, hasBirthday: false, completion: nil)
            (self.navigationController as? NavigationController)?.pushViewController(controller)
        }))
    }

    private func openNativeStarsGift() {
        guard let recipient = self.recipient, let starsContext = self.context.starsContext else { return }
        let controller = self.context.sharedContext.makeStarsPurchaseScreen(context: self.context,
            starsContext: starsContext, options: [], purpose: .gift(peerId: recipient.id), targetPeerId: recipient.id,
            customTheme: nil, completion: { [weak self] _ in
                guard let self else { return }
                let chat = self.context.sharedContext.makeChatController(context: self.context,
                    chatLocation: .peer(id: recipient.id), subject: nil, botStart: nil, mode: .standard(.default), params: nil)
                Queue.mainQueue().after(0.3) { [weak self] in
                    (self?.navigationController as? NavigationController)?.pushViewController(chat)
                }
            })
        (self.navigationController as? NavigationController)?.pushViewController(controller)
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

    private func confirmGift(_ gift: StarGift, currency: LocalGiftCurrency? = nil) {
        guard !self.purchaseInProgress, let recipient = self.recipient else { return }
        let starsPrice = LocalGiftsStore.starsPrice(for: gift)
        let tonPrice = LocalGiftsStore.tonPriceNano(for: gift)
        if currency == nil, let starsPrice, let tonPrice {
            let alert = UIAlertController(title: LocalGiftsStore.title(for: gift), message: "Выбери валюту локальной покупки.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "★ \(starsPrice)", style: .default) { [weak self] _ in
                Queue.mainQueue().after(0.25) { self?.confirmGift(gift, currency: .stars) }
            })
            alert.addAction(UIAlertAction(title: "\(LocalTonAmount.format(tonPrice)) GRAM", style: .default) { [weak self] _ in
                Queue.mainQueue().after(0.25) { self?.confirmGift(gift, currency: .ton) }
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            self.present(alert, animated: true)
            return
        }
        let selectedCurrency = currency ?? (starsPrice != nil ? .stars : .ton)
        guard let price = selectedCurrency == .stars ? starsPrice : tonPrice else { self.showError(LocalGiftsError.unsupportedCurrency); return }
        let priceText = selectedCurrency == .ton ? "\(LocalTonAmount.format(price)) GRAM" : "\(price) ★"
        let requestId = UUID()
        self.confirm(title: LocalGiftsStore.title(for: gift), message: "\(self.name(of: recipient))\nСтоимость: \(priceText)", destructive: false) { [weak self] in
            guard let self else { return }
            if case let .unique(uniqueGift) = gift {
                guard !self.purchaseInProgress else { return }
                self.purchaseInProgress = true
                self.purchaseDisposable.set((self.context.engine.payments.getUniqueStarGift(slug: uniqueGift.slug)
                |> deliverOnMainQueue).start(next: { [weak self] currentGift in
                    guard let self else { return }
                    self.purchaseInProgress = false
                    let current = StarGift.unique(currentGift)
                    let currentPrice = selectedCurrency == .stars ? LocalGiftsStore.starsPrice(for: current) : LocalGiftsStore.tonPriceNano(for: current)
                    guard currentGift.id == uniqueGift.id, currentPrice == price else {
                        self.showMessage("Предложение больше недоступно по этой цене. Обнови маркет и выбери доступный NFT.")
                        return
                    }
                    self.perform { _ = try self.store.sendGift(current, recipientId: recipient.id, recipientName: self.name(of: recipient), requestId: requestId, priceOverride: price, currency: selectedCurrency) }
                }, error: { [weak self] _ in
                    self?.purchaseInProgress = false
                    self?.showMessage("Не удалось проверить доступность NFT. Проверь соединение и обнови маркет.")
                }))
                return
            }
            self.perform { _ = try self.store.sendGift(gift, recipientId: recipient.id, recipientName: self.name(of: recipient), requestId: requestId, currency: selectedCurrency) }
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

    private func requestAmount(title: String, initial: String, currency: LocalGiftCurrency = .stars, action: @escaping (Int64) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = currency == .ton ? .decimalPad : .numberPad; $0.text = initial; $0.placeholder = currency == .ton ? "Количество GRAM" : "Количество Stars" }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Готово", style: .default) { [weak self, weak alert] _ in
            let text = (alert?.textFields?.first?.text ?? "").filter { !$0.isWhitespace }
            let parsedAmount = currency == .ton ? LocalTonAmount.parse(text) : Int64(text)
            guard let amount = parsedAmount, amount >= 0 else {
                self?.showMessage(currency == .ton ? "Введи количество GRAM: до 9 знаков после запятой." : "Введи целое количество Stars от нуля.")
                return
            }
            action(amount)
        })
        self.present(alert, animated: true)
    }

    private func confirm(title: String, message: String, destructive: Bool, confirmTitle: String? = nil, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: confirmTitle ?? (destructive ? "Сбросить" : "Отправить"), style: destructive ? .destructive : .default) { _ in action() })
        self.present(alert, animated: true)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.showError(error) }
    }

    private func showError(_ error: Error) {
        let text: String
        switch error {
        case LocalGiftsError.insufficientBalance: text = "Недостаточно виртуального баланса. Измени баланс Stars или GRAM в разделе «Фейк-подарки»."
        case LocalGiftsError.invalidAmount: text = "Введи целое положительное количество Stars. Баланс можно установить в ноль."
        case LocalGiftsError.starsTransferTooLarge: text = "За одну отправку можно показать до 2 147 483 647 Stars. Виртуальный баланс может быть больше."
        case LocalGiftsError.unsupportedCurrency: text = "У подарка нет цены в Stars или GRAM. Выбери предложение на продажу в маркетплейсе."
        case LocalGiftsError.collectibleAlreadyPurchased: text = "Этот NFT уже куплен. Вернуть доступные предложения можно кнопкой сброса покупок в маркете."
        case LocalGiftsError.unreadableStorage: text = "Не удалось прочитать локальные подарки. Можно сбросить их в разделе «Фейк-подарки»."
        default: text = "Не удалось сохранить локальные данные. Баланс не был изменён."
        }
        self.showMessage(text)
    }

    private func showMessage(_ text: String) {
        Queue.mainQueue().after(0.3) { [weak self] in
            let alert = UIAlertController(title: "Фейк-подарки", message: text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(alert, animated: true)
        }
    }
}
