import Foundation

/// Only the duration and curve of an interface transition; no clocks or playback state.
public struct EGAnimationAdjustment: Equatable {
    public let duration: Double
    public let usesSmoothTiming: Bool
}

public struct EGAnimationPolicy: Equatable {
    public let enabled: Bool
    public let speed: Double
    public let smooth: Bool
    public let reduceMotion: Bool

    public init(enabled: Bool = false, speed: Double = 1.0, smooth: Bool = false, reduceMotion: Bool = false) {
        self.enabled = enabled
        self.speed = speed.isFinite && speed > 0.0 ? min(2.0, max(0.5, speed)) : 1.0
        self.smooth = smooth
        self.reduceMotion = reduceMotion
    }

    public static let standard = EGAnimationPolicy()

    /// nil means that the caller must retain its original duration and timing function.
    public func adjustment(duration: Double, keyPath: String) -> EGAnimationAdjustment? {
        guard self.enabled, duration.isFinite, duration > 0.0 else {
            return nil
        }
        let scaled = duration / self.speed
        // Extreme imported/input values must never introduce infinity or a zero-duration spring.
        var effectiveDuration = max(0.001, scaled.isFinite && scaled > 0.0 ? scaled : duration)
        let spatial = Self.isSpatialKeyPath(keyPath)
        if self.reduceMotion && spatial {
            effectiveDuration = min(effectiveDuration, 0.01)
        }
        return EGAnimationAdjustment(duration: effectiveDuration, usesSmoothTiming: (self.smooth && (spatial || keyPath == "opacity")) || (self.reduceMotion && spatial))
    }

    private static let spatialKeyPaths = ["position", "bounds", "frame", "transform", "sublayerTransform", "anchorPoint"]

    public static func isSpatialKeyPath(_ keyPath: String) -> Bool {
        return self.spatialKeyPaths.contains { keyPath == $0 || keyPath.hasPrefix($0 + ".") }
    }
}
