import Foundation
import UIKit
import ObjectiveC
import Display
import SwiftSignalKit
import GGCore
import GGSettingsUI

enum GGBadgeAppearance {
    private static let tab = GGMenuTabID("appearance.icons.badge.appearance")
    private static let colorSection = GGMenuSectionID("interface.islandBadge.appearance.color")
    private static let resetSection = GGMenuSectionID("interface.islandBadge.appearance.reset")
    private static var colorPickerKey: UInt8 = 0

    static func register(linkIn section: GGMenuSectionID) {
        let screen = GGMenuScreenID.tab(GGBadgeAppearance.tab)
        let preview = GGMenuSectionID.preview(of: GGBadgeAppearance.tab)
        let main = GGMenuSectionID.main(of: GGBadgeAppearance.tab)
        GGMenuRegistry.register(tab: GGMenuTabDescriptor(
            id: GGBadgeAppearance.tab,
            parent: .tab(.appearanceIcons),
            title: { GGStrings.Interface.Badge.appearanceTitle },
            searchKeywords: { [GGStrings.Interface.Menu.badgeKeywords] }
        ), linkIn: section, order: 300, subtitle: { GGStrings.Interface.Badge.appearanceInfo }, icon: .system("slider.horizontal.3"))

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: preview, screen: screen, order: 100, header: { GGStrings.Interface.Badge.appearancePreview }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.islandBadge.appearance.preview", section: preview, order: 100, title: { "" }, kind: .preview(.custom(height: 138.0, make: { _ in
            return GGBadgeAppearancePreviewView(frame: CGRect())
        }))))

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: main, screen: screen, order: 200, footer: { _ in GGStrings.Interface.Badge.appearanceFooter }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.islandBadge.scale", section: main, order: 100, title: { GGStrings.Interface.Badge.appearanceSize }, kind: .slider(.global(InterfaceSettings.islandBadgeScale), range: 70.0 ... 130.0, step: 1.0, format: GGBadgeAppearance.percent)))
        GGMenuRegistry.register(GGMenuRow(id: "interface.islandBadge.opacity", section: main, order: 200, title: { GGStrings.Interface.Badge.opacity }, kind: .slider(.global(InterfaceSettings.islandBadgeOpacity), range: 20.0 ... 100.0, step: 1.0, format: GGBadgeAppearance.percent)))

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGBadgeAppearance.colorSection, screen: screen, order: 300, footer: { _ in GGStrings.Interface.Badge.appearanceColorFooter }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.islandBadge.color", section: GGBadgeAppearance.colorSection, order: 100, title: { GGStrings.Interface.Badge.appearanceColor }, kind: .action({ menu in
            GGBadgeAppearance.pickColor(context: menu)
        }), label: { _ in
            if let color = GGIslandBadgeAppearance.color {
                return String(format: "#%06X", color)
            }
            return GGStrings.Interface.Badge.appearanceOriginalColor
        }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.islandBadge.color.reset", section: GGBadgeAppearance.colorSection, order: 200, title: { GGStrings.Interface.Badge.appearanceRestoreColor }, kind: .action({ _ in
            InterfaceSettings.islandBadgeColor.reset()
        }), isEnabled: { _ in !InterfaceSettings.islandBadgeColor.isDefault }))
        GGMenuRegistry.register(GGMenuRow(id: "interface.islandBadge.useLocalGram", section: GGBadgeAppearance.colorSection, order: 300, title: { GGStrings.Interface.Badge.appearanceUseLocalGram }, kind: .action({ _ in
            InterfaceSettings.islandBadgeSelection.set("localgram")
        }), isVisible: { _ in GGBadgeStore.isValidId(InterfaceSettings.islandBadgeSelection.value) }))

        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: GGBadgeAppearance.resetSection, screen: screen, order: 400))
        GGMenuRegistry.register(GGMenuRow(id: "interface.islandBadge.appearance.reset", section: GGBadgeAppearance.resetSection, order: 100, title: { GGStrings.Interface.Badge.appearanceReset }, kind: .action({ _ in
            InterfaceSettings.islandBadgeScale.reset()
            InterfaceSettings.islandBadgeOpacity.reset()
            InterfaceSettings.islandBadgeColor.reset()
        }), isEnabled: { _ in
            return !InterfaceSettings.islandBadgeScale.isDefault || !InterfaceSettings.islandBadgeOpacity.isDefault || !InterfaceSettings.islandBadgeColor.isDefault
        }))
    }

    private static func percent(_ value: Double) -> String {
        return GGStrings.Interface.Menu.percent(value: "\(Int(value.rounded()))")
    }

    private static func pickColor(context: GGMenuContext) {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = UIColor(rgb: GGIslandBadgeAppearance.color ?? 0x35B2E9)
        let delegate = GGBadgeAppearanceColorPickerDelegate()
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &GGBadgeAppearance.colorPickerKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        context.presentNative(picker)
    }
}

/// The selected badge is shown at twice its natural size; drafts follow the slider while it moves.
private final class GGBadgeAppearancePreviewView: UIView, GGMenuPreviewView {
    private let imageView = UIImageView()
    private let nameLabel = UILabel()
    private var documents: [GGBadgeDocument] = []
    private var documentsDisposable: Disposable?
    private var lastContext: GGMenuContext?
    private var imageKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.imageView.contentMode = .scaleAspectFit
        self.imageView.isAccessibilityElement = true
        self.addSubview(self.imageView)
        self.nameLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .medium)
        self.nameLabel.textAlignment = .center
        self.nameLabel.lineBreakMode = .byTruncatingTail
        self.addSubview(self.nameLabel)
        self.documentsDisposable = (GGBadgeStore.shared.documents
        |> deliverOnMainQueue).start(next: { [weak self] documents in
            guard let self else {
                return
            }
            self.documents = documents
            self.imageKey = nil
            if let context = self.lastContext {
                self.update(context: context)
            }
        })
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    deinit {
        self.documentsDisposable?.dispose()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let context = self.lastContext {
            self.update(context: context)
        }
    }

    func update(context: GGMenuContext) {
        self.lastContext = context
        let selection = InterfaceSettings.islandBadgeSelection.value
        let key = selection + "|" + InterfaceSettings.islandBadgeColor.value
        if self.imageKey != key {
            self.imageKey = key
            self.imageView.image = GGBadgeStore.shared.image(selection: selection)
        }
        let name = self.documents.first(where: { $0.id == selection })?.name ?? GGStrings.Interface.Badge.bundledName
        self.nameLabel.text = name
        self.nameLabel.textColor = context.presentationData.theme.list.itemSecondaryTextColor
        self.imageView.accessibilityLabel = name

        let scaleValue = context.displayValue(GGMenuBinding<Double>.global(InterfaceSettings.islandBadgeScale))
        let opacityValue = context.displayValue(GGMenuBinding<Double>.global(InterfaceSettings.islandBadgeOpacity))
        let scale = CGFloat(scaleValue.isFinite ? min(130.0, max(70.0, scaleValue)) / 100.0 : 1.0)
        self.imageView.alpha = CGFloat(opacityValue.isFinite ? min(100.0, max(20.0, opacityValue)) / 100.0 : 1.0)
        let imageSize = self.imageView.image?.size ?? GGBadgeDocument.canvasSize
        let desiredWidth = imageSize.width * scale * 2.0
        let desiredHeight = imageSize.height * scale * 2.0
        let fit = min(1.0, min(max(1.0, self.bounds.width - 32.0) / max(1.0, desiredWidth), 72.0 / max(1.0, desiredHeight)))
        let size = CGSize(width: desiredWidth * fit, height: desiredHeight * fit)
        self.imageView.frame = CGRect(x: floor((self.bounds.width - size.width) * 0.5), y: floor(54.0 - size.height * 0.5), width: size.width, height: size.height)
        self.nameLabel.frame = CGRect(x: 16.0, y: 99.0, width: max(0.0, self.bounds.width - 32.0), height: 22.0)
    }
}

/// Selection saves immediately, including when the picker is later dismissed with a swipe.
/// An untouched picker keeps the original gradient.
private final class GGBadgeAppearanceColorPickerDelegate: NSObject, UIColorPickerViewControllerDelegate {
    private var didPick = false

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        self.didPick = true
        self.saveColor(color)
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        guard self.didPick else {
            return
        }
        self.saveColor(viewController.selectedColor)
    }

    private func saveColor(_ color: UIColor) {
        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return
        }
        let r = UInt32((max(0.0, min(1.0, red)) * 255.0).rounded())
        let g = UInt32((max(0.0, min(1.0, green)) * 255.0).rounded())
        let b = UInt32((max(0.0, min(1.0, blue)) * 255.0).rounded())
        InterfaceSettings.islandBadgeColor.set(String(format: "%06X", (r << 16) | (g << 8) | b))
    }
}
