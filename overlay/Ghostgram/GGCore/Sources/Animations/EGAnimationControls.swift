import SwiftSignalKit

/// Display reads one immutable snapshot. Settings and UI hooks publish it on the main queue.
public enum EGAnimationControls {
    private static let snapshot = Atomic<EGAnimationPolicy>(value: .standard)

    public static var current: EGAnimationPolicy {
        return self.snapshot.with { $0 }
    }

    public static func update(_ policy: EGAnimationPolicy) {
        let _ = self.snapshot.swap(policy)
    }
}
