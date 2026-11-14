import XCTest
@testable import LocalAnimationModel

final class LocalAnimationModelTests: XCTestCase {
    func testDisabledPolicyRetainsAllOriginalAnimationInputs() {
        let policy = EGAnimationPolicy(enabled: false, speed: 2.0, smooth: true, reduceMotion: true)
        XCTAssertNil(policy.adjustment(duration: 0.5, keyPath: "position.x"))
        XCTAssertNil(policy.adjustment(duration: 0.5, keyPath: "opacity"))
    }

    func testSpeedChangesDurationAndNormalizesInvalidOrOutOfRangeValues() {
        XCTAssertEqual(EGAnimationPolicy(enabled: true, speed: 2.0).adjustment(duration: 0.5, keyPath: "position")?.duration, 0.25)
        XCTAssertEqual(EGAnimationPolicy(enabled: true, speed: 0.5).adjustment(duration: 0.5, keyPath: "opacity")?.duration, 1.0)
        for invalid in [Double.nan, Double.infinity, -Double.infinity, 0.0, -1.0] {
            XCTAssertEqual(EGAnimationPolicy(speed: invalid).speed, 1.0)
        }
        XCTAssertEqual(EGAnimationPolicy(speed: 0.1).speed, 0.5)
        XCTAssertEqual(EGAnimationPolicy(speed: 5.0).speed, 2.0)
    }

    func testReducedMotionShortensSpatialTransitionsButRetainsFades() {
        let reduced = EGAnimationPolicy(enabled: true, speed: 1.0, reduceMotion: true)
        for keyPath in ["position", "position.y", "bounds.size", "transform.scale", "sublayerTransform", "anchorPoint"] {
            let adjustment = reduced.adjustment(duration: 0.5, keyPath: keyPath)
            XCTAssertEqual(adjustment?.duration, 0.01)
            XCTAssertEqual(adjustment?.usesSmoothTiming, true)
        }
        XCTAssertEqual(reduced.adjustment(duration: 0.5, keyPath: "opacity")?.duration, 0.5)
        XCTAssertEqual(reduced.adjustment(duration: 0.5, keyPath: "opacity")?.usesSmoothTiming, false)
        let smooth = EGAnimationPolicy(enabled: true, smooth: true)
        XCTAssertEqual(smooth.adjustment(duration: 0.5, keyPath: "position")?.usesSmoothTiming, true)
        XCTAssertEqual(smooth.adjustment(duration: 0.5, keyPath: "opacity")?.usesSmoothTiming, true)
        XCTAssertEqual(smooth.adjustment(duration: 0.5, keyPath: "backgroundColor")?.usesSmoothTiming, false)
    }

    func testInvalidDurationPassesThroughAndExtremeValidValuesStayFinitePositive() throws {
        let policy = EGAnimationPolicy(enabled: true, speed: 2.0, smooth: true, reduceMotion: true)
        for invalid in [Double.nan, Double.infinity, -Double.infinity, 0.0, -0.5] {
            XCTAssertNil(policy.adjustment(duration: invalid, keyPath: "transform"))
        }
        let underflow = try XCTUnwrap(policy.adjustment(duration: .leastNonzeroMagnitude, keyPath: "opacity"))
        XCTAssertEqual(underflow.duration, 0.001)
        let overflow = try XCTUnwrap(EGAnimationPolicy(enabled: true, speed: 0.5).adjustment(duration: .greatestFiniteMagnitude, keyPath: "position"))
        XCTAssertTrue(overflow.duration.isFinite && overflow.duration > 0.0)
    }
}
