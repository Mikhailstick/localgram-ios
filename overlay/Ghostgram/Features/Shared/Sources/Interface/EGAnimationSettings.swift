import GGCore
import SwiftSignalKit

public enum EGAnimationSettings {
    public static let enabled = GGSetting<Bool>("animation.enabled", default: false)
    public static let speed = GGSetting<Double>("animation.speed", default: 1.0)
    public static let smooth = GGSetting<Bool>("animation.smooth", default: false)
    public static let reduceMotion = GGSetting<Bool>("animation.reduceMotion", default: false)

    public static func declare() {
        let _ = self.enabled
        let _ = self.speed
        let _ = self.smooth
        let _ = self.reduceMotion
    }

    public static var policy: EGAnimationPolicy {
        return EGAnimationPolicy(enabled: self.enabled.value, speed: self.speed.value, smooth: self.smooth.value, reduceMotion: self.reduceMotion.value)
    }

    public static var signal: Signal<EGAnimationPolicy, NoError> {
        return GGSettingsStore.shared.revision
        |> map { _ in self.policy }
        |> distinctUntilChanged
    }
}
