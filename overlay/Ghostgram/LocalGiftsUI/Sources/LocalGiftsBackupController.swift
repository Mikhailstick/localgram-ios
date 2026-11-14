import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import GGCore
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit
import UniformTypeIdentifiers

@available(iOS 14.0, *)
public final class LocalGiftsBackupController: ViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate {
    private let context: AccountContext
    private let store: LocalGiftsStore
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let presentationData: PresentationData
    private var operationInProgress = false

    public init(context: AccountContext) {
        self.context = context
        self.store = LocalGiftsStore.shared(accountPeerId: context.account.peerId)
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        self.title = "Резервная копия"
        self.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        self.table.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        self.table.dataSource = self
        self.table.delegate = self
        self.table.contentInsetAdjustmentBehavior = .never
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        self.displayNode.view.addSubview(self.table)
        self.displayNodeDidLoad()
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: self.table, frame: CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top)))
        self.table.contentInset.bottom = layout.intrinsicInsets.bottom
    }

    public func numberOfSections(in tableView: UITableView) -> Int { return 1 }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return LocalGiftsStore.isEnabled ? 2 : 0
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return "Stars, GRAM, подарки, история и доступные для экспорта настройки ExoraGram текущего аккаунта. Копия сохраняется вручную в JSON. Данные входа и файлы пользовательских бейджей, тем и медиа не входят в копию. Глобальные настройки оформления восстанавливаются для всего приложения."
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if indexPath.row == 0 {
            content.text = "Сохранить копию в файл"
            content.secondaryText = "Поделиться или сохранить в «Файлы»"
            content.image = UIImage(systemName: "square.and.arrow.up")
        } else {
            content.text = "Восстановить из файла"
            content.secondaryText = "Проверить копию и подтвердить замену"
            content.image = UIImage(systemName: "square.and.arrow.down")
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.isUserInteractionEnabled = !self.operationInProgress
        cell.contentView.alpha = self.operationInProgress ? 0.5 : 1.0
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard LocalGiftsStore.isEnabled, !self.operationInProgress else { return }
        if indexPath.row == 0 {
            self.exportBackup()
        } else {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
            picker.allowsMultipleSelection = false
            picker.delegate = self
            self.present(picker, animated: true)
        }
    }

    private func setBusy(_ value: Bool) {
        self.operationInProgress = value
        self.table.reloadData()
    }

    private func exportBackup() {
        let backup: LocalGiftsBackup
        do {
            backup = LocalGiftsBackup(
                accountPeerId: self.context.account.peerId.toInt64(),
                settingsAccountId: self.context.account.id.gg.rawValue,
                ledger: try self.store.backupSnapshot(),
                settingsData: GGSettingsStore.shared.exportData(accounts: [self.context.account.id.gg])
            )
        } catch {
            self.showError(error)
            return
        }
        self.setBusy(true)
        Queue.concurrentDefaultQueue().async { [weak self] in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exoragram-backup-\(UUID().uuidString)", isDirectory: true)
            let url = directory.appendingPathComponent("ExoraGram-backup-\(backup.createdAt).json")
            do {
                let data = try backup.encode()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                Queue.mainQueue().async { [weak self] in
                    guard let self else {
                        try? FileManager.default.removeItem(at: directory)
                        return
                    }
                    self.setBusy(false)
                    let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = self.table
                    share.popoverPresentationController?.sourceRect = CGRect(x: self.table.bounds.midX, y: 30, width: 1, height: 1)
                    share.completionWithItemsHandler = { _, _, _, _ in
                        Queue.concurrentDefaultQueue().async { try? FileManager.default.removeItem(at: directory) }
                    }
                    self.present(share, animated: true)
                }
            } catch {
                try? FileManager.default.removeItem(at: directory)
                Queue.mainQueue().async { [weak self] in
                    self?.setBusy(false)
                    self?.showError(error)
                }
            }
        }
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        self.setBusy(true)
        let peerId = self.context.account.peerId.toInt64()
        Queue.concurrentDefaultQueue().async { [weak self] in
            let result: Result<LocalGiftsBackup, Error>
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                guard size > 0, size <= LocalGiftsBackup.maximumFileSize else { throw LocalGiftsBackupError.fileTooLarge }
                result = .success(try LocalGiftsBackup.decode(Data(contentsOf: url), for: peerId))
            } catch {
                result = .failure(error)
            }
            if url.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/") {
                try? FileManager.default.removeItem(at: url)
            }
            Queue.mainQueue().async { [weak self] in
                self?.setBusy(false)
                switch result {
                case let .success(backup): self?.previewRestore(backup)
                case let .failure(error): self?.showError(error)
                }
            }
        }
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.setBusy(false)
    }

    private func settingsPreview(_ backup: LocalGiftsBackup) throws -> GGSettingsImportDiff {
        try backup.validate(for: self.context.account.peerId.toInt64())
        for receipt in backup.ledger.receipts {
            if receipt.kind != .stars && LocalGiftsStore.decodedGift(receipt) == nil { throw LocalGiftsBackupError.invalidFile }
            if receipt.entitiesData != nil && LocalGiftsStore.decodedEntities(receipt) == nil { throw LocalGiftsBackupError.invalidFile }
        }
        let diff = try GGSettingsStore.shared.importPreview(backup.settingsData, accountMapping: [
            GGAccountID(rawValue: backup.settingsAccountId): self.context.account.id.gg
        ])
        guard diff.unmatchedAccounts.isEmpty else { throw LocalGiftsBackupError.invalidFile }
        return diff
    }

    private func previewRestore(_ backup: LocalGiftsBackup) {
        do {
            let diff = try self.settingsPreview(backup)
            _ = try self.store.backupSnapshot()
            let date = DateFormatter.localizedString(from: Date(timeIntervalSince1970: TimeInterval(backup.createdAt)), dateStyle: .medium, timeStyle: .short)
            let skipped = diff.skippedKeys.count + diff.unknownKeys.count
            let message = "Копия от \(date)\n★ \(backup.ledger.balance) Stars\n\(LocalTonAmount.format(backup.ledger.tonBalanceNano)) GRAM\nПодарки и операции: \(backup.ledger.receipts.count)\nИзменения настроек: \(diff.changes.count)\nПропущенные настройки: \(skipped)\n\nТекущий локальный баланс, подарки и история будут заменены. Настройки из копии применятся к этому аккаунту; глобальные — ко всему приложению."
            let alert = UIAlertController(title: "Восстановить копию?", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            alert.addAction(UIAlertAction(title: "Восстановить", style: .destructive) { [weak self] _ in self?.restore(backup) })
            self.present(alert, animated: true)
        } catch {
            self.showError(error)
        }
    }

    private func restore(_ backup: LocalGiftsBackup) {
        do {
            let diff = try self.settingsPreview(backup)
            try self.store.restoreBackup(backup.ledger)
            GGSettingsStore.shared.applyImport(diff)
            self.showMessage("Локальные данные и настройки восстановлены.")
        } catch {
            self.showError(error)
        }
    }

    private func showError(_ error: Error) {
        let message: String
        switch error {
        case LocalGiftsBackupError.differentAccount: message = "Эта копия принадлежит другому аккаунту Telegram. Переключись на аккаунт, для которого она была сохранена."
        case LocalGiftsBackupError.unsupportedVersion: message = "Версия этой копии пока не поддерживается. Обнови ExoraGram."
        case LocalGiftsBackupError.fileTooLarge: message = "Выбери JSON-копию ExoraGram размером не больше 32 МБ."
        case LocalGiftsBackupError.invalidFile: message = "Копия повреждена или имеет неподходящий формат. Данные не изменены."
        case LocalGiftsError.unreadableStorage: message = "Текущие локальные данные не удалось прочитать. Их файл сохранён; резервная копия не будет записана поверх него."
        default: message = "Не удалось прочитать или сохранить копию. Локальные данные не изменены."
        }
        self.showMessage(message)
    }

    private func showMessage(_ message: String) {
        Queue.mainQueue().after(0.3) { [weak self] in
            let alert = UIAlertController(title: "Резервная копия", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(alert, animated: true)
        }
    }
}
