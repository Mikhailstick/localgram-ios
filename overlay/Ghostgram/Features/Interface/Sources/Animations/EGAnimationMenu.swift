import Foundation
import SwiftSignalKit
import TelegramPresentationData
import GGCore
import GGHooks
import GGSettingsUI
import GGFeaturesShared

enum EGAnimationMenu {
    private static let tab = GGMenuTabID("appearance.animations")
    private static var settingsDisposable: Disposable?

    static func registerControls() {
        guard self.settingsDisposable == nil else { return }
        EGAnimationSettings.declare()
        EGAnimationControls.update(EGAnimationSettings.policy)
        GGThemeHooks.presentationData.register({ presentationData, _ in
            let policy = EGAnimationControls.current
            guard policy.enabled, policy.reduceMotion, !presentationData.reduceMotion else {
                return presentationData
            }
            return PresentationData(strings: presentationData.strings, theme: presentationData.theme, autoNightModeTriggered: presentationData.autoNightModeTriggered, chatWallpaper: presentationData.chatWallpaper, chatFontSize: presentationData.chatFontSize, chatBubbleCorners: presentationData.chatBubbleCorners, listsFontSize: presentationData.listsFontSize, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, nameSortOrder: presentationData.nameSortOrder, reduceMotion: true, largeEmoji: presentationData.largeEmoji)
        }, order: 400)

        var isFirst = true
        self.settingsDisposable = (EGAnimationSettings.signal
        |> deliverOnMainQueue).start(next: { policy in
            EGAnimationControls.update(policy)
            if isFirst {
                isFirst = false
                return
            }
            // The menu's sliders write after release; imports publish one settings revision.
            GGThemeHooks.invalidate()
        })
    }

    static func register() {
        let screen = GGMenuScreenID.tab(self.tab)
        let main = GGMenuSectionID.main(of: self.tab)
        GGMenuRegistry.register(tab: GGMenuTabDescriptor(id: self.tab, parent: .category(.appearance), title: { GGStrings.Animations.title }, searchKeywords: { [GGStrings.Animations.keywords] }), linkIn: .appearanceTabs, order: 640, subtitle: { GGStrings.Animations.info }, icon: .system("sparkles"))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: main, screen: screen, order: 100, footer: { _ in GGStrings.Animations.speedInfo + "\n\n" + GGStrings.Animations.footer }))
        GGMenuRegistry.register(GGMenuRow(id: "animation.enabled", section: main, order: 100, title: { GGStrings.Animations.enabled }, kind: .toggle(.global(EGAnimationSettings.enabled))))
        GGMenuRegistry.register(GGMenuRow(id: "animation.speed", section: main, order: 200, title: { GGStrings.Animations.speed }, subtitle: { GGStrings.Animations.speedInfo }, kind: .slider(.global(EGAnimationSettings.speed), range: 0.5 ... 2.0, step: 0.1, format: { GGStrings.Animations.speedValue(value: String(format: "%.1f", $0)) }), isEnabled: { _ in EGAnimationSettings.enabled.value }))
        GGMenuRegistry.register(GGMenuRow(id: "animation.smooth", section: main, order: 300, title: { GGStrings.Animations.smooth }, subtitle: { GGStrings.Animations.smoothInfo }, kind: .toggle(.global(EGAnimationSettings.smooth)), isEnabled: { _ in EGAnimationSettings.enabled.value }))
        GGMenuRegistry.register(GGMenuRow(id: "animation.reduceMotion", section: main, order: 400, title: { GGStrings.Animations.reduceMotion }, subtitle: { GGStrings.Animations.reduceMotionInfo }, kind: .toggle(.global(EGAnimationSettings.reduceMotion)), isEnabled: { _ in EGAnimationSettings.enabled.value }))
    }
}
