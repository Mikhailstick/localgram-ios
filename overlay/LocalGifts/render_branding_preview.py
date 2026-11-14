"""Render production UIKit branding and a pure animation-policy demo.

Needs macOS, Xcode/iOS Simulator, ffmpeg, ffprobe and Pillow. Recorded frame
timestamps come from ffprobe; this does not test the full app's cutout position.
"""
import csv
from datetime import datetime, timezone
import hashlib
import json
import math
import platform
import plistlib
import re
import signal
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VARIANTS = [
    ("Default", "default", 100, 100, None),
    ("Small", "small", 70, 100, None),
    ("Large", "large", 130, 100, None),
    ("Faint", "faint", 100, 20, None),
    ("Translucent", "translucent", 100, 60, None),
    ("Custom blue", "blue", 100, 100, 0x007AFF),
    ("Large violet", "violet", 130, 60, 0xAF52DE),
    ("Small amber", "amber", 70, 20, 0xFF9500),
]
ANIMATION_POLICY_PATH = ROOT / "Ghostgram/GGCore/Sources/Animations/EGAnimationPolicy.swift"
ANIMATION_VARIANTS = [
    ("Default", "default", False, 1.0, False, False, 1.0, "linear"),
    ("Slow", "slow", True, 0.5, False, False, 2.0, "linear"),
    ("Fast", "fast", True, 2.0, False, False, 0.5, "linear"),
    ("Smooth", "smooth", True, 1.0, True, False, 1.0, "easeInEaseOut"),
    ("Reduced motion", "reduced-motion", True, 1.0, False, True, 0.01, "easeInEaseOut"),
]
EXPECTATIONS = """Expected appearance frames before recording:
- Every production badge keeps a 93 x 22 pt canvas. The shared arrow and ExoraGram
  label fit fully inside its rounded pill on light and dark surfaces.
- Host sizes 70%, 100% and 130% scale the whole bitmap together around its centre.
- Host alpha 20%, 60% and 100% affects background, glyph and text together.
- Nil uses the ExoraGram violet gradient and the settings tile uses dark purple.
  A custom UInt32 color is passed
  directly to the production renderer, without a preview-specific tint.
- Variants advance serially after one second in each state; the numbered label
  identifies each state. No spring or animated interpolation is expected.
  There must be no clipped or duplicated content between states.
- After all eight appearance states, five moving-badge demos use the verbatim
  production EGAnimationPolicy.swift, with an explicit linear caller animation
  of position and a 1.00 s base duration. Default (.standard, disabled) retains
  1.00 s/linear; slow (0.5x) uses 2.00 s/linear; fast (2x) uses 0.50 s/linear;
  smooth uses 1.00 s/easeInEaseOut; reduced motion uses 0.01 s/easeInEaseOut.
- Each motion demo resets to the default 93 x 22 pt badge at 100% opacity,
  holds the start for 0.6 s, moves the complete bitmap from left to right,
  then holds the settled position for 0.6 s before starting the next demo.
  Both surfaces move in the same phase, with equal travel. The glyph, label
  and background must stay together. Tiles and labels stay still during motion.
  There is no spring, overshoot, clipping, duplication or return at completion.
- Motion starts beyond the stationary tile's right edge and ends 16 pt before
  the surface's right edge; travel is capped at 180 pt and adapts to host width.
  The reset between demos and near-instant reduced-motion move are expected
  jumps. Recorder gap/jump heuristics still require visual frame inspection.
- Appearance and animation event times are process uptime relative to the
  controller start; MP4 times are independent ffprobe PTS. They must not be
  equated without clock synchronization. Horizontal motion is visually reviewed;
  animation_sheet.py's vertical template tracker is not used to claim tracking.
- Frames use decoded index and ffprobe presentation timestamps, not index/fps.
  This checks UIKit bitmap/host appearance, not full-app cutout placement,
  interactive settings, persistence or search/gift navigation.
- Animation scope is this UIKit host with the pure production policy and
  explicit configurations. It does not verify Atomic controls, the global
  Display hook or the full app's interactive animation settings.
- If the matching SDK runtime supports only iPhone Duo, the disposable Duo
  records its primary display (1) and verifies this one generic UIKit host
  in its initial posture. It does not
  verify the production app's Duo placement, folding or rotation behavior.
"""


def run(*args, timeout=150):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=timeout).strip()
    except subprocess.CalledProcessError as error:
        print(error.output, flush=True)
        raise


def progress(output, stage, **details):
    entry = {"time_utc": datetime.now(timezone.utc).isoformat(), "stage": stage, **details}
    message = entry["time_utc"] + " " + stage
    if details:
        message += " " + json.dumps(details, ensure_ascii=False)
    print(message, flush=True)
    with (output / "progress.log").open("a", encoding="utf-8") as journal:
        journal.write(message + "\n")
    (output / "progress.json").write_text(json.dumps(entry, indent=2), encoding="utf-8")


def operation_timeout(deadline, maximum, reserve=0):
    """Bound all stages by one render budget, reserving time for recorded frames."""
    remaining = deadline - time.monotonic() - reserve
    if remaining < 1:
        raise TimeoutError("The shared preview render budget is exhausted before the next operation.")
    return min(maximum, remaining)


def select_simulator(runtimes, types, sdk_version):
    def version(value):
        parts = tuple(map(int, value.split("."))) if isinstance(value, str) else tuple(value)
        return parts + (0,) * (3 - len(parts))
    sdk = version(sdk_version)
    compatible_runtimes = [item for item in runtimes if item.get("isAvailable")
        and re.search(r"\.iOS-\d+-\d+(?:-\d+)?$", item["identifier"])
        and version(item["version"]) <= sdk]
    # Match the selected SDK first. A Duo-only runtime still runs this ordinary
    # single-window UIKit preview; no fold/rotation or production layout is tested.
    for candidate in sorted(compatible_runtimes, key=lambda item: (version(item["version"]) == sdk, version(item["version"])), reverse=True):
        supported_ids = {item["identifier"] if isinstance(item, dict) else item for item in candidate.get("supportedDeviceTypes", [])}
        compatible = [item for item in types if item["name"].startswith("iPhone")
            and (not supported_ids or item["identifier"] in supported_ids)]
        if not compatible:
            continue
        standard = [item for item in compatible if "Duo" not in item["name"]]
        preferred = next((item for item in standard if item["name"] == "iPhone 17 Pro"), None)
        device = preferred or (standard or compatible)[-1]
        return candidate["identifier"], device
    raise RuntimeError("No available iPhone simulator runtime/type pair at or below the selected SDK.")


def run_logged(output, stage, *args, timeout):
    """Keep subprocess output on disk while waiting; cold boots can be quiet."""
    log = output / (stage + ".log")
    progress(output, stage + " started", timeout_seconds=timeout, log=log.name)
    started = time.monotonic()
    with log.open("w", encoding="utf-8") as stream:
        process = subprocess.Popen(args, stdout=stream, stderr=subprocess.STDOUT)
        try:
            while True:
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    process.kill()
                    process.wait(timeout=10)
                    raise TimeoutError(stage + " exceeded " + str(timeout) + " seconds; see " + log.name)
                try:
                    code = process.wait(timeout=min(15, remaining))
                    break
                except subprocess.TimeoutExpired:
                    lines = log.read_text(errors="replace").splitlines()
                    progress(output, stage + " waiting", elapsed_seconds=round(time.monotonic() - started, 1),
                        output_tail=lines[-1][-500:] if lines else "No subprocess output yet")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
    elapsed = round(time.monotonic() - started, 1)
    progress(output, stage + " finished", elapsed_seconds=elapsed, exit_code=code)
    if code != 0:
        raise RuntimeError(stage + " failed with exit " + str(code) + "; see " + log.name)
    return log.read_text(errors="replace").strip()


def simulator_diagnostics(output, device):
    """Read durable state with bounded commands before disposing our simulator."""
    commands = [
        ("diagnostic-load-average.log", ["/usr/bin/uptime"]),
        ("diagnostic-virtual-memory.log", ["/usr/bin/vm_stat"]),
        ("diagnostic-devices.json", ["xcrun", "simctl", "list", "devices", "--json"]),
        ("diagnostic-runtime-processes.log", ["/usr/bin/pgrep", "-lf", "CoreSimulator|simctl|launchd_sim|SpringBoard|installd"]),
        ("diagnostic-simulator.log", ["/usr/bin/log", "show", "--last", "5m", "--style", "compact", "--predicate", 'subsystem BEGINSWITH "com.apple.CoreSimulator"']),
    ]
    progress(output, "Collecting simulator diagnostics", device=device)
    deadline = time.monotonic() + 30
    for name, command in commands:
        remaining = deadline - time.monotonic()
        if remaining < 1:
            break
        with (output / name).open("w", encoding="utf-8") as stream:
            try:
                subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=False, timeout=min(10, remaining))
            except subprocess.TimeoutExpired:
                stream.write("\nDiagnostic command exceeded its bounded diagnostic budget.\n")
            except OSError as error:
                stream.write("\n" + str(error) + "\n")


def function(source, name):
    start = source.index("private func " + name + "(")
    opening = source.index("{", start)
    depth = 0
    for offset in range(opening, len(source)):
        depth += (source[offset] == "{") - (source[offset] == "}")
        if depth == 0:
            return source[start:offset + 1]
    raise ValueError("Incomplete renderer: " + name)


def preview_source(source, policy_source=None):
    if policy_source is None:
        policy_source = ANIMATION_POLICY_PATH.read_text(encoding="utf-8")
    pieces = ["""import UIKit
extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
"""]
    # Compile the actual policy unchanged; the host supplies only caller values
    # and explicit configurations, without recreating its adjustment logic.
    pieces.append(policy_source)
    for name in ("ggBrandColors", "ggBrandTileColors"):
        match = re.search(r"^private let " + name + r"[^\n]*", source, re.MULTILINE)
        if match is None:
            raise ValueError("Missing production branding constant: " + name)
        pieces.append(match.group())
    for name in ("ggBrandMarkPath", "ggDrawBrandGlyph", "ggRenderBrandGlyph", "ggRenderLocalGramIslandBadge", "ggRenderSettingsTile", "ggRenderBrandMark"):
        pieces.append(function(source, name))
    if not re.search(r"\(\s*color\s*:\s*UInt32\?", function(source, "ggRenderLocalGramIslandBadge")):
        raise ValueError("Production badge renderer must accept color: UInt32? before appearance verification.")
    cases = []
    for name, slug, size, alpha, rgb in VARIANTS:
        color = "nil" if rgb is None else f"UInt32(0x{rgb:06X})"
        cases.append(f'PreviewVariant(name: {json.dumps(name)}, slug: "{slug}", sizePercent: {size}, alphaPercent: {alpha}, color: {color})')
    pieces.append("let previewVariants: [PreviewVariant] = [\n" + ",\n".join(cases) + "\n]")
    cases = []
    for name, slug, enabled, speed, smooth, reduced, _, _ in ANIMATION_VARIANTS:
        policy = ".standard" if not enabled else (
            f"EGAnimationPolicy(enabled: true, speed: {speed}, smooth: {str(smooth).lower()}, reduceMotion: {str(reduced).lower()})")
        cases.append(f'PreviewAnimationVariant(name: {json.dumps(name)}, slug: "{slug}", policy: {policy})')
    pieces.append("let previewAnimationVariants: [PreviewAnimationVariant] = [\n" + ",\n".join(cases) + "\n]")
    pieces.append(r'''
struct PreviewVariant {
    let name: String
    let slug: String
    let sizePercent: Int
    let alphaPercent: Int
    let color: UInt32?
    var scale: CGFloat { CGFloat(sizePercent) / 100.0 }
    var alpha: CGFloat { CGFloat(alphaPercent) / 100.0 }
    var caption: String {
        let tint = color.map { String(format: "#%06X", $0) } ?? "brand gradient"
        return "\(sizePercent)% size / \(alphaPercent)% alpha / \(tint)"
    }
}

let previewAnimationKeyPath = "position"
let previewAnimationBaseDuration = 1.0
let previewAnimationStartHold = 0.6
let previewAnimationSettleHold = 0.6

struct PreviewAnimationVariant {
    let name: String
    let slug: String
    let policy: EGAnimationPolicy
    var adjustment: EGAnimationAdjustment? {
        policy.adjustment(duration: previewAnimationBaseDuration, keyPath: previewAnimationKeyPath)
    }
    var duration: Double { adjustment?.duration ?? previewAnimationBaseDuration }
    var timing: CAMediaTimingFunctionName { adjustment?.usesSmoothTiming == true ? .easeInEaseOut : .linear }
    var caption: String { String(format: "%.2f s / %@ / speed %.2f", duration, timing.rawValue, policy.speed) }
    func descriptor(index: Int) -> [String: Any] {
        ["index": index, "name": name, "slug": slug, "enabled": policy.enabled, "speed": policy.speed,
         "smooth": policy.smooth, "reduce_motion": policy.reduceMotion,
         "key_path": previewAnimationKeyPath, "base_duration_seconds": previewAnimationBaseDuration,
         "caller_timing_function": CAMediaTimingFunctionName.linear.rawValue,
         "adjustment_applied": adjustment != nil, "effective_duration_seconds": duration,
         "effective_timing_function": timing.rawValue,
         "start_hold_seconds": previewAnimationStartHold, "settle_hold_seconds": previewAnimationSettleHold]
    }
}

final class PreviewMotionCompletion: NSObject, CAAnimationDelegate {
    let completion: (Bool) -> Void
    init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
    func animationDidStop(_ animation: CAAnimation, finished flag: Bool) { completion(flag) }
}

func writeJSON(_ value: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}

func drawBadge(_ image: UIImage, variant: PreviewVariant, center: CGPoint) {
    let size = CGSize(width: image.size.width * variant.scale, height: image.size.height * variant.scale)
    image.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), blendMode: .normal, alpha: variant.alpha)
}

final class BadgePreviewController: UIViewController {
    let titleLabel = UILabel()
    let captionLabel = UILabel()
    let surfaces = [UIView(), UIView()]
    let badges = [UIImageView(), UIImageView()]
    let tiles = [UIImageView(), UIImageView()]
    var variant = previewVariants[0]
    var directory: URL!
    let startTime = ProcessInfo.processInfo.systemUptime
    var events: [[String: Any]] = []
    var animationEvents: [[String: Any]] = []
    var animationIndex: Int?
    var animationAtEnd = false
    var motionCompletion: PreviewMotionCompletion?
    var sequenceStarted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.86, alpha: 1)
        titleLabel.font = .systemFont(ofSize: 19, weight: .bold)
        titleLabel.textColor = .black
        titleLabel.textAlignment = .center
        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.textColor = .darkGray
        captionLabel.textAlignment = .center
        view.addSubview(titleLabel)
        view.addSubview(captionLabel)
        for index in 0..<2 {
            surfaces[index].backgroundColor = index == 0 ? .white : UIColor(white: 0.11, alpha: 1)
            view.addSubview(surfaces[index])
            badges[index].contentMode = .scaleAspectFit
            surfaces[index].addSubview(badges[index])
            tiles[index].image = ggRenderSettingsTile()
            surfaces[index].addSubview(tiles[index])
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !sequenceStarted else { return }
        sequenceStarted = true
        showNext(0)
    }

    func showNext(_ index: Int) {
        showVariant(index)
        view.layoutIfNeeded()
        // Schedule only the next state after the current one has laid out.
        // Absolute launch-time deadlines can all expire while CI is overloaded,
        // coalescing every update into the final state before a frame is drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if index + 1 < previewVariants.count {
                self.showNext(index + 1)
                return
            }
            self.showAnimation(0)
        }
    }

    func showVariant(_ index: Int) {
        variant = previewVariants[index]
        titleLabel.text = "\(index + 1)/\(previewVariants.count)  \(variant.name)"
        captionLabel.text = variant.caption
        let image = ggRenderLocalGramIslandBadge(color: variant.color)!
        for badge in badges { badge.image = image; badge.alpha = variant.alpha }
        events.append(["index": index, "name": variant.name, "elapsed_uptime_seconds": ProcessInfo.processInfo.systemUptime - startTime])
        try! writeJSON(events, to: directory.appendingPathComponent("appearance-events.json"))
        view.setNeedsLayout()
    }

    func animationCenter(surface: UIView, atEnd: Bool) -> CGPoint {
        let halfBadgeWidth: CGFloat = 93 / 2
        let minimumX: CGFloat = 16 + 30 + 16 + halfBadgeWidth
        let maximumX = surface.bounds.width - 16 - halfBadgeWidth
        precondition(maximumX > minimumX, "The motion host is too narrow for an unclipped badge path.")
        let travel = min(180.0, maximumX - minimumX)
        return CGPoint(x: atEnd ? maximumX : maximumX - travel, y: 53)
    }

    func recordAnimation(_ phase: String, index: Int, finished: Bool? = nil) {
        var event = previewAnimationVariants[index].descriptor(index: index)
        event["phase"] = phase
        event["elapsed_uptime_seconds"] = ProcessInfo.processInfo.systemUptime - startTime
        event["clock"] = "process_uptime_relative_to_controller_start; not recording PTS"
        event["surfaces"] = surfaces.map { surface -> [String: Any] in
            let start = animationCenter(surface: surface, atEnd: false)
            let end = animationCenter(surface: surface, atEnd: true)
            return ["start_x_points": start.x, "end_x_points": end.x, "y_points": start.y,
                    "travel_points": end.x - start.x, "surface_width_points": surface.bounds.width]
        }
        if let finished { event["finished"] = finished }
        animationEvents.append(event)
        try! writeJSON(animationEvents, to: directory.appendingPathComponent("animation-events.json"))
    }

    func showAnimation(_ index: Int) {
        animationIndex = index
        animationAtEnd = false
        variant = previewVariants[0]
        let configuration = previewAnimationVariants[index]
        titleLabel.text = "Motion \(index + 1)/\(previewAnimationVariants.count)  \(configuration.name)"
        captionLabel.text = configuration.caption
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for badge in badges {
            badge.layer.removeAllAnimations()
            badge.image = ggRenderLocalGramIslandBadge()!
            badge.alpha = 1
        }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        CATransaction.commit()
        recordAnimation("start_hold", index: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + previewAnimationStartHold) { [weak self] in
            self?.moveAnimation(index)
        }
    }

    func moveAnimation(_ index: Int) {
        let configuration = previewAnimationVariants[index]
        animationAtEnd = true
        motionCompletion = PreviewMotionCompletion { [weak self] finished in
            guard let self else { return }
            self.recordAnimation(finished ? "settled" : "interrupted", index: index, finished: finished)
            guard finished else { return }
            self.motionCompletion = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + previewAnimationSettleHold) { [weak self] in
                guard let self else { return }
                self.recordAnimation("settle_hold_complete", index: index)
                if index + 1 < previewAnimationVariants.count {
                    self.showAnimation(index + 1)
                } else {
                    self.completePreview()
                }
            }
        }
        recordAnimation("move", index: index)
        let beginTime = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for surfaceIndex in 0..<badges.count {
            let badge = badges[surfaceIndex]
            let start = animationCenter(surface: surfaces[surfaceIndex], atEnd: false)
            let end = animationCenter(surface: surfaces[surfaceIndex], atEnd: true)
            badge.layer.position = end
            let animation = CABasicAnimation(keyPath: previewAnimationKeyPath)
            animation.fromValue = NSValue(cgPoint: start)
            animation.toValue = NSValue(cgPoint: end)
            animation.duration = configuration.duration
            animation.timingFunction = CAMediaTimingFunction(name: configuration.timing)
            animation.beginTime = badge.layer.convertTime(beginTime, from: nil)
            if surfaceIndex == badges.count - 1 { animation.delegate = motionCompletion }
            badge.layer.add(animation, forKey: "policy-demo-position")
        }
        CATransaction.commit()
    }

    func completePreview() {
        try! writeJSON(["variant_count": previewVariants.count, "animation_variant_count": previewAnimationVariants.count,
            "screen_scale": view.window?.screen.scale ?? UIScreen.main.scale,
            "screen_width_points": view.bounds.width, "screen_height_points": view.bounds.height,
            "serial_variant_sequence": true, "serial_animation_sequence": true,
            "completed_elapsed_uptime_seconds": ProcessInfo.processInfo.systemUptime - startTime, "completed": true],
            to: directory.appendingPathComponent("preview-complete.json"))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let left = view.safeAreaInsets.left
        let width = view.bounds.width - left - view.safeAreaInsets.right
        let top = max(60.0, view.safeAreaInsets.top)
        titleLabel.frame = CGRect(x: left + 12, y: top, width: width - 24, height: 30)
        captionLabel.frame = CGRect(x: left + 8, y: top + 31, width: width - 16, height: 25)
        for index in 0..<2 {
            surfaces[index].frame = CGRect(x: left + 20, y: top + 72 + CGFloat(index) * 126, width: width - 40, height: 106)
            let size = CGSize(width: 93 * variant.scale, height: 22 * variant.scale)
            if animationIndex != nil {
                // Keep the model's final position if UIKit relayouts in flight.
                badges[index].bounds = CGRect(origin: .zero, size: size)
                badges[index].center = animationCenter(surface: surfaces[index], atEnd: animationAtEnd)
            } else {
                badges[index].frame = CGRect(x: (surfaces[index].bounds.width - size.width) / 2, y: (106 - size.height) / 2, width: size.width, height: size.height)
            }
            tiles[index].frame = CGRect(x: 16, y: 38, width: 30, height: 30)
        }
    }
}

@objc(PreviewAppDelegate)
final class PreviewAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: session.role)
        configuration.delegateClass = PreviewSceneDelegate.self
        return configuration
    }
}
@objc(PreviewSceneDelegate)
final class PreviewSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let badge = ggRenderLocalGramIslandBadge()!
        let tile = ggRenderSettingsTile()!
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! badge.pngData()!.write(to: directory.appendingPathComponent("badge.png"))
        // Preserve original artifact dimensions/composition for existing build7 consumers.
        let preview = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image { render in
            UIColor.white.setFill()
            render.fill(CGRect(x: 0, y: 0, width: 320, height: 90))
            UIColor(white: 0.11, alpha: 1).setFill()
            render.fill(CGRect(x: 0, y: 90, width: 320, height: 90))
            for y in [CGFloat(0), CGFloat(90)] {
                tile.draw(in: CGRect(x: 18, y: y + 30, width: 30, height: 30))
                badge.draw(in: CGRect(x: 76, y: y + 23, width: 186, height: 44))
            }
        }
        try! preview.pngData()!.write(to: directory.appendingPathComponent("branding-preview.png"))
        var descriptors: [[String: Any]] = []
        let canvasHeight = CGFloat(60 + previewVariants.count * 64)
        let appearance = UIGraphicsImageRenderer(size: CGSize(width: 640, height: canvasHeight)).image { render in
            UIColor.white.setFill()
            render.fill(CGRect(x: 0, y: 0, width: 320, height: canvasHeight))
            UIColor(white: 0.11, alpha: 1).setFill()
            render.fill(CGRect(x: 320, y: 0, width: 320, height: canvasHeight))
            for column in 0..<2 {
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: column == 0 ? UIColor.black : UIColor.white]
                let title = column == 0 ? "Light surface" : "Dark surface"
                (title as NSString).draw(at: CGPoint(x: CGFloat(column * 320 + 16), y: 14), withAttributes: attributes)
            }
            for (index, variant) in previewVariants.enumerated() {
                let image = ggRenderLocalGramIslandBadge(color: variant.color)!
                try! image.pngData()!.write(to: directory.appendingPathComponent("badge-\(variant.slug).png"))
                descriptors.append(["index": index, "name": variant.name, "slug": variant.slug, "size_percent": variant.sizePercent, "alpha_percent": variant.alphaPercent,
                    "color": variant.color.map { String(format: "#%06X", $0) } ?? "nil", "bitmap_width_points": image.size.width, "bitmap_height_points": image.size.height, "bitmap_scale": image.scale])
                let y = CGFloat(60 + index * 64)
                for column in 0..<2 {
                    let x = CGFloat(column * 320)
                    let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: column == 0 ? UIColor.darkGray : UIColor.lightGray]
                    ("\(index + 1). \(variant.name) - \(variant.caption)" as NSString).draw(at: CGPoint(x: x + 12, y: y), withAttributes: attributes)
                    drawBadge(image, variant: variant, center: CGPoint(x: x + 160, y: y + 36))
                }
            }
        }
        try! appearance.pngData()!.write(to: directory.appendingPathComponent("appearance-preview.png"))
        try! writeJSON(descriptors, to: directory.appendingPathComponent("appearance-variants.json"))
        try! writeJSON(previewAnimationVariants.enumerated().map { $0.element.descriptor(index: $0.offset) },
            to: directory.appendingPathComponent("animation-variants.json"))
        try! writeJSON([], to: directory.appendingPathComponent("animation-events.json"))
        let controller = BadgePreviewController()
        controller.directory = directory
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        NSLog("LocalGram production appearance preview rendered in %@", directory.path)
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(PreviewAppDelegate.self))
''')
    return "\n".join(pieces)


def recording_ready(recording, log, timeout=120):
    started = time.monotonic()
    deadline = started + timeout
    next_report = started + 15
    while time.monotonic() < deadline:
        if "Recording started" in log.read_text(errors="replace"):
            return
        if recording.poll() is not None:
            raise RuntimeError("Simulator recorder exited before starting: " + log.read_text(errors="replace"))
        if time.monotonic() >= next_report:
            lines = log.read_text(errors="replace").splitlines()
            progress(log.parent, "Recorder waiting", elapsed_seconds=round(time.monotonic() - started, 1),
                output_tail=lines[-1][-500:] if lines else "No recorder output yet")
            next_report = time.monotonic() + 15
        time.sleep(0.1)
    raise TimeoutError("Simulator did not confirm that recording started.")


def frame_sheet(output, metadata, timeout=150):
    """Reuse the project's ffprobe-indexed extractor, without resampling."""
    width = metadata["screen_width_points"]
    height = min(430, metadata["screen_height_points"] - 60)
    subprocess.run([
        "python3", str(ROOT / "tools/animation_sheet.py"), str(output / "branding.mp4"), str(output / "frames"),
        "--scale", str(metadata["screen_scale"]), "--crop", f"0,60,{width},{height}",
        "--tile-width", "350", "--columns", "4", "--rows", "3",
    ], check=True, timeout=timeout)
    shutil.copy2(output / "frames/frames.tsv", output / "frames.tsv")
    with (output / "frames.tsv").open(newline="") as source:
        rows = list(csv.DictReader(source, delimiter="\t"))
    if not rows:
        raise ValueError("Recording produced no labelled contact sheet.")
    # A representative overview is easier to open than the first sheet, which
    # can contain only app-launch frames. Every frame remains in frames/sheet-*.
    count = min(12, len(rows))
    first_time, last_time = float(rows[0]["time_s"]), float(rows[-1]["time_s"])
    selected = {}
    for slot in range(count):
        target = first_time + (last_time - first_time) * slot / max(1, count - 1)
        row = min(rows, key=lambda item: abs(float(item["time_s"]) - target))
        selected[int(row["index"])] = row
    from PIL import Image, ImageDraw, ImageFont
    chosen = [selected[index] for index in sorted(selected)]
    with Image.open(output / "frames/frames/00000.png") as example:
        tile_width = 350
        tile_height = round(example.height * tile_width / example.width)
    label_height, gap, columns = 24, 4, 4
    sheet = Image.new("RGB", (columns * (tile_width + gap) + gap,
        ((len(chosen) + columns - 1) // columns) * (tile_height + label_height + gap) + gap), (40, 40, 40))
    draw = ImageDraw.Draw(sheet)
    try:
        label_font = ImageFont.load_default(size=14)
    except TypeError:
        label_font = ImageFont.load_default()
    for slot, row in enumerate(chosen):
        index = int(row["index"])
        x, y = gap + slot % columns * (tile_width + gap), gap + slot // columns * (tile_height + label_height + gap)
        draw.text((x + 2, y + 2), f"#{index} t={float(row['time_s']):.3f}s +{row['interval_ms']}ms", fill=(230, 230, 230), font=label_font)
        with Image.open(output / "frames/frames" / f"{index:05d}.png") as frame:
            sheet.paste(frame.convert("RGB").resize((tile_width, tile_height), Image.Resampling.LANCZOS), (x, y + label_height))
    sheet.save(output / "sheet.png")


def verify_animation_sequence(output, metadata, appearance_events):
    """Validate native policy results and serial lifecycle; frames judge appearance."""
    descriptors = json.loads((output / "animation-variants.json").read_text())
    events = json.loads((output / "animation-events.json").read_text())
    if len(descriptors) != len(ANIMATION_VARIANTS) or metadata.get("animation_variant_count") != len(ANIMATION_VARIANTS):
        raise ValueError("A native animation-policy demo is missing.")
    for index, (actual, expected) in enumerate(zip(descriptors, ANIMATION_VARIANTS)):
        name, slug, enabled, speed, smooth, reduced, duration, timing = expected
        exact = {"index": index, "name": name, "slug": slug, "enabled": enabled, "speed": speed,
            "smooth": smooth, "reduce_motion": reduced, "adjustment_applied": enabled,
            "key_path": "position", "base_duration_seconds": 1.0, "caller_timing_function": "linear",
            "effective_timing_function": timing, "start_hold_seconds": 0.6, "settle_hold_seconds": 0.6}
        if any(actual.get(key) != value for key, value in exact.items()) or not math.isclose(
                actual.get("effective_duration_seconds", -1), duration, abs_tol=1e-9):
            raise ValueError("Native production policy differs from the recorded plan for " + name)
    expected_phases = [(index, phase) for index in range(len(ANIMATION_VARIANTS))
        for phase in ("start_hold", "move", "settled", "settle_hold_complete")]
    if [(event.get("index"), event.get("phase")) for event in events] != expected_phases:
        raise ValueError("The native animation demo did not finish every serial lifecycle.")
    times = [event["elapsed_uptime_seconds"] for event in events]
    if not all(math.isfinite(value) for value in times) or any(second < first for first, second in zip(times, times[1:])):
        raise ValueError("Animation event uptime is invalid or out of order.")
    if times[0] - appearance_events[-1]["elapsed_uptime_seconds"] < 0.95:
        raise ValueError("The animation demo started before the last appearance hold ended.")
    for index in range(len(ANIMATION_VARIANTS)):
        start, move, settled, hold = events[index * 4:index * 4 + 4]
        if move["elapsed_uptime_seconds"] - start["elapsed_uptime_seconds"] < 0.55 or (
                hold["elapsed_uptime_seconds"] - settled["elapsed_uptime_seconds"] < 0.55):
            raise ValueError("A native animation demo skipped its start or settle hold.")
        if settled.get("finished") is not True:
            raise ValueError("A native animation was interrupted instead of settling.")
        # Allow a few display frames of tolerance; event uptimes are still
        # lifecycle evidence, never a substitute for reviewing the MP4 frames.
        if settled["elapsed_uptime_seconds"] - move["elapsed_uptime_seconds"] < max(
                0.0, descriptors[index]["effective_duration_seconds"] - 0.06):
            raise ValueError("A native animation settled before its policy duration elapsed.")
        for event in (start, move, settled, hold):
            if any(event.get(key) != value for key, value in descriptors[index].items()):
                raise ValueError("An animation event reports a different policy from its native descriptor.")
            if len(event.get("surfaces", [])) != 2:
                raise ValueError("The animation demo did not report both surfaces.")
            travel = [surface["travel_points"] for surface in event["surfaces"]]
            if not math.isclose(travel[0], travel[1], abs_tol=1e-6) or not 0 < travel[0] <= 180:
                raise ValueError("The two badge paths differ or have invalid travel.")
            for surface in event["surfaces"]:
                if surface["start_x_points"] - 46.5 < 62 - 1e-6 or (
                        surface["end_x_points"] + 46.5 > surface["surface_width_points"] - 16 + 1e-6):
                    raise ValueError("A moving badge path overlaps its tile or leaves the surface.")
    if metadata.get("serial_animation_sequence") is not True or metadata.get("completed") is not True or (
            metadata.get("completed_elapsed_uptime_seconds", -1) < times[-1]):
        raise ValueError("Preview completion was written before the animation demo finished.")
    return descriptors, events


def main():
    # The matching Duo runtime needed 150s boot + 114s install + 99s container
    # on the observed runner. Active work gets 14m40s so launch and frame
    # extraction still have time; 80s remain for diagnostics/cleanup within
    # the workflow's 16-minute render step. Per-stage limits share this budget.
    render_deadline = time.monotonic() + 880
    if platform.system() != "Darwin":
        raise SystemExit("UIKit preview needs macOS with the iOS Simulator SDK, ffmpeg/ffprobe and Pillow.")
    missing = [name for name in ("xcrun", "codesign", "ffmpeg", "ffprobe") if shutil.which(name) is None]
    if missing:
        raise SystemExit("Missing preview tooling: " + ", ".join(missing) + ". Install ffmpeg (includes ffprobe) on the Mac runner.")
    try:
        import PIL  # noqa: F401: animation_sheet.py needs Pillow.
    except ImportError:
        raise SystemExit("Frame contact sheets require Pillow: python3 -m pip install Pillow")
    if not (ROOT / "tools/animation_sheet.py").is_file():
        raise SystemExit("Missing the pinned project's tools/animation_sheet.py for ffprobe-labelled frames.")
    source = (ROOT / "Ghostgram/GGSettingsUI/Sources/Style/GGMenuIcons.swift").read_text()
    policy_source = ANIMATION_POLICY_PATH.read_text(encoding="utf-8")
    policy_sha256 = hashlib.sha256(policy_source.encode()).hexdigest()
    swift_source = preview_source(source, policy_source)
    output = ROOT / "LocalGifts/artifacts/branding"
    output.mkdir(parents=True, exist_ok=True)
    (output / "EXPECTED_FRAMES.md").write_text(EXPECTATIONS, encoding="utf-8")
    (output / "preview-source.swift").write_text(swift_source, encoding="utf-8")
    # The plan and source identity exist before passive recording begins.
    animation_plan = {"production_policy_source": str(ANIMATION_POLICY_PATH.relative_to(ROOT)),
        "production_policy_sha256": policy_sha256, "policy_compilation": "verbatim source in disposable UIKit host",
        "scope": "pure policy with explicit configs; Atomic controls, Display hook and full-app settings untested",
        "event_clock": "process uptime relative to controller start", "video_clock": "independent ffprobe PTS; no clock alignment claimed",
        "key_path": "position", "base_duration_seconds": 1.0, "caller_timing_function": "linear",
        "start_hold_seconds": 0.6, "settle_hold_seconds": 0.6,
        "expected_variants": [{"index": index, "name": name, "slug": slug, "enabled": enabled,
            "speed": speed, "smooth": smooth, "reduce_motion": reduced,
            "effective_duration_seconds": duration, "effective_timing_function": timing}
            for index, (name, slug, enabled, speed, smooth, reduced, duration, timing) in enumerate(ANIMATION_VARIANTS)]}
    (output / "animation-plan.json").write_text(json.dumps(animation_plan, indent=2), encoding="utf-8")
    print(EXPECTATIONS, flush=True)
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json", timeout=operation_timeout(render_deadline, 60, 80)))["runtimes"]
    types = json.loads(run("xcrun", "simctl", "list", "devicetypes", "--json", timeout=operation_timeout(render_deadline, 60, 80)))["devicetypes"]
    sdk_version = tuple(map(int, run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version", timeout=operation_timeout(render_deadline, 60, 80)).split(".")))
    (output / "simulator-runtimes.json").write_text(json.dumps(runtimes, indent=2), encoding="utf-8")
    (output / "simulator-device-types.json").write_text(json.dumps(types, indent=2), encoding="utf-8")
    runtime, selected_type = select_simulator(runtimes, types, sdk_version)
    device_type = selected_type["identifier"]
    device_name = selected_type["name"]
    # Duo has two displays, so simctl cannot choose a recording/screenshot
    # target. Its documented primary display is 1; ordinary iPhones retain
    # simctl's default. Both captures must use the same display.
    display_options = ["--display=1"] if "Duo" in device_name else []
    progress(output, "Creating disposable simulator", device_type=device_type, device_name=device_name, runtime=runtime)
    device = run_logged(output, "create", "xcrun", "simctl", "create", "ExoraGram branding preview", device_type, runtime, timeout=operation_timeout(render_deadline, 60, 80))
    (output / "simulator-selection.json").write_text(json.dumps({"device": device, "device_type": device_type,
        "device_name": device_name, "runtime": runtime, "sdk_version": sdk_version,
        "preference": "matching SDK runtime; standard iPhone preferred when supported, Duo allowed",
        "capture_display": 1 if display_options else "default",
        "scope": "one UIKit preview host in initial posture; production Duo layout untested"}, indent=2), encoding="utf-8")
    container = None
    try:
        with tempfile.TemporaryDirectory(prefix="localgram-branding-") as scratch:
            app = Path(scratch) / "Preview.app"
            app.mkdir()
            swift = Path(scratch) / "main.swift"
            swift.write_text(swift_source, encoding="utf-8")
            info = {"CFBundleIdentifier": "dev.localgram.brandingpreview", "CFBundleExecutable": "Preview", "CFBundleName": "Preview", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL", "MinimumOSVersion": "15.0", "UIDeviceFamily": [1], "LSRequiresIPhoneOS": True, "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "UILaunchScreen": {}, "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False, "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [{"UISceneConfigurationName": "Default", "UISceneDelegateClassName": "PreviewSceneDelegate"}]}}}
            info["CFBundleDisplayName"] = "ExoraGram Preview"
            info["CFBundleIcons"] = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon60x60"], "UIPrerenderedIcon": True}}
            for scale in (2, 3):
                shutil.copy2(ROOT / f"Telegram/Telegram-iOS/LocalGramAssets.xcassets/LocalGram.appiconset/iphone-60-{scale}x.png", app / f"AppIcon60x60@{scale}x.png")
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path", timeout=operation_timeout(render_deadline, 60, 80))
            progress(output, "Compiling production UIKit renderers and verbatim animation policy")
            subprocess.run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-sdk", sdk, "-target", "arm64-apple-ios15.0-simulator", "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift", str(swift), "-o", str(app / "Preview")], check=True, timeout=operation_timeout(render_deadline, 120, 80))
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, timeout=operation_timeout(render_deadline, 30, 80))
            run_logged(output, "boot", "xcrun", "simctl", "boot", device, timeout=operation_timeout(render_deadline, 90, 180))
            run_logged(output, "bootstatus", "xcrun", "simctl", "bootstatus", device, "-b", timeout=operation_timeout(render_deadline, 300, 180))
            run_logged(output, "install", "xcrun", "simctl", "install", device, str(app), timeout=operation_timeout(render_deadline, 240, 160))
            container = Path(run_logged(output, "container", "xcrun", "simctl", "get_app_container", device,
                info["CFBundleIdentifier"], "data", timeout=operation_timeout(render_deadline, 240, 130)))
            with (output / "recording.log").open("w") as recording_log, (output / "console.log").open("w") as console_log:
                progress(output, "Starting passive simulator recording")
                recording = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo", *display_options, "--codec=h264", "--force", str(output / "branding.mp4")], stdout=recording_log, stderr=recording_log)
                launcher = None
                try:
                    recording_ready(recording, output / "recording.log", timeout=operation_timeout(render_deadline, 120, 100))
                    progress(output, "Launching native appearance and pure-policy preview")
                    launcher = subprocess.Popen(["xcrun", "simctl", "launch", "--console", device, info["CFBundleIdentifier"]], stdout=console_log, stderr=console_log)
                    started = time.monotonic()
                    deadline = started + operation_timeout(render_deadline, 240, 75)
                    next_report = started + 15
                    while not (container / "Documents/preview-complete.json").exists():
                        if time.monotonic() >= deadline:
                            raise TimeoutError("Native preview did not complete all appearance and animation variants.")
                        if time.monotonic() >= next_report:
                            event_file = container / "Documents/animation-events.json"
                            state = "Waiting for UIKit app startup"
                            if event_file.exists() and len(event_file.read_text(errors="replace")) > 10:
                                state = event_file.read_text(errors="replace")[-700:]
                            elif (container / "Documents/appearance-events.json").exists():
                                state = (container / "Documents/appearance-events.json").read_text(errors="replace")[-700:]
                            progress(output, "Appearance and policy sequence waiting", elapsed_seconds=round(time.monotonic() - started, 1),
                                latest_events=state)
                            next_report = time.monotonic() + 15
                        time.sleep(0.2)
                    progress(output, "All appearance and policy variants rendered")
                    time.sleep(0.5)
                    run_logged(output, "screenshot", "xcrun", "simctl", "io", device, "screenshot",
                        *display_options, str(output / "simulator.png"), timeout=operation_timeout(render_deadline, 150, 60))
                finally:
                    # End recording while the final reduced-motion rest is visible.
                    if recording.poll() is None:
                        recording.send_signal(signal.SIGINT)
                        recording.wait(timeout=max(1, min(90, render_deadline - time.monotonic() - 50)))
                    try:
                        subprocess.run(["xcrun", "simctl", "terminate", device, info["CFBundleIdentifier"]], check=False,
                            timeout=max(1, min(20, render_deadline - time.monotonic() - 40)))
                    except subprocess.TimeoutExpired:
                        progress(output, "Preview termination timed out after recording stopped")
                    if launcher is not None:
                        try:
                            launcher.wait(timeout=max(1, min(10, render_deadline - time.monotonic() - 35)))
                        except subprocess.TimeoutExpired:
                            launcher.terminate()
                            launcher.wait(timeout=5)
            for item in (container / "Documents").iterdir():
                if item.suffix in (".png", ".json"):
                    shutil.copy2(item, output / item.name)
        descriptors = json.loads((output / "appearance-variants.json").read_text())
        if len(descriptors) != len(VARIANTS) or any(item["bitmap_width_points"] != 93 or item["bitmap_height_points"] != 22 for item in descriptors):
            raise ValueError("Production badge canvas changed or an appearance variant is missing.")
        metadata = json.loads((output / "preview-complete.json").read_text())
        events = json.loads((output / "appearance-events.json").read_text())
        if [event["index"] for event in events] != list(range(len(VARIANTS))):
            raise ValueError("The native appearance sequence did not visit every variant in order.")
        animation_descriptors, animation_events = verify_animation_sequence(output, metadata, events)
        progress(output, "Extracting recorded frames with ffprobe presentation times")
        frame_sheet(output, metadata, timeout=operation_timeout(render_deadline, 150))
        metadata.update({"runtime": runtime, "device_type": device_type, "device_name": device_name,
            "capture_display": 1 if display_options else "default",
            "production_duo_layout_test": "not performed", "production_source_sha256": hashlib.sha256(source.encode()).hexdigest(),
            "production_animation_policy_sha256": policy_sha256,
            "animation_variants": animation_descriptors, "animation_event_count": len(animation_events),
            "animation_plan": "animation-plan.json", "animation_events": "animation-events.json",
            "animation_scope": animation_plan["scope"], "animation_event_clock": animation_plan["event_clock"],
            "event_to_video_clock_alignment": "not performed; use ffprobe PTS to cite frames",
            "recording": "branding.mp4", "frame_contact_sheets": "frames/sheet-*.png", "frame_timestamps": "frames.tsv",
            "timestamp_source": "ffprobe frame pts_time; no fixed-rate resampling",
            "scope": "UIKit bitmap/host appearance and pure animation-policy demo; full app placement and Display integration untested"})
        (output / "preview-verification.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        progress(output, "Rendered production appearance, pure-policy demo and labelled native frames")
    except BaseException as error:
        # Preserve native PNGs/event metadata even if a later capture or frame
        # analysis step fails, before our disposable simulator is removed.
        if container is not None and (container / "Documents").is_dir():
            try:
                for item in (container / "Documents").iterdir():
                    if item.suffix in (".png", ".json"):
                        shutil.copy2(item, output / item.name)
            except OSError as collection_error:
                progress(output, "Native output collection failed", error=str(collection_error))
        (output / "failure.json").write_text(json.dumps({"error_type": type(error).__name__, "error": str(error),
            "device": device, "runtime": runtime}, indent=2), encoding="utf-8")
        progress(output, "Preview failed", error_type=type(error).__name__, error=str(error))
        simulator_diagnostics(output, device)
        raise
    finally:
        for operation in ("shutdown", "delete"):
            print("Cleaning up disposable simulator: " + operation, flush=True)
            try:
                subprocess.run(["xcrun", "simctl", operation, device], check=False, timeout=20)
            except subprocess.TimeoutExpired:
                print("Simulator cleanup timed out: " + operation)


if __name__ == "__main__":
    main()
