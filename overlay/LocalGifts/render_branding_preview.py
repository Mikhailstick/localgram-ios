"""Render production UIKit branding and host appearance on a disposable simulator.

Needs macOS, Xcode/iOS Simulator, ffmpeg, ffprobe and Pillow. Recorded frame
timestamps come from ffprobe; this does not test the full app's cutout position.
"""
import csv
from datetime import datetime, timezone
import hashlib
import json
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
- Frames use decoded index and ffprobe presentation timestamps, not index/fps.
  This checks UIKit bitmap/host appearance, not full-app cutout placement,
  interactive settings, persistence or search/gift navigation.
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


def preview_source(source):
    pieces = ["""import UIKit
extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
"""]
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
            try! writeJSON(["variant_count": previewVariants.count, "screen_scale": self.view.window?.screen.scale ?? UIScreen.main.scale,
                "screen_width_points": self.view.bounds.width, "screen_height_points": self.view.bounds.height,
                "serial_variant_sequence": true, "completed": true],
                to: self.directory.appendingPathComponent("preview-complete.json"))
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
            badges[index].frame = CGRect(x: (surfaces[index].bounds.width - size.width) / 2, y: (106 - size.height) / 2, width: size.width, height: size.height)
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
    swift_source = preview_source(source)
    output = ROOT / "LocalGifts/artifacts/branding"
    output.mkdir(parents=True, exist_ok=True)
    (output / "EXPECTED_FRAMES.md").write_text(EXPECTATIONS, encoding="utf-8")
    (output / "preview-source.swift").write_text(swift_source, encoding="utf-8")
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
            progress(output, "Compiling extracted production UIKit renderers")
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
                    progress(output, "Launching native appearance preview")
                    launcher = subprocess.Popen(["xcrun", "simctl", "launch", "--console", device, info["CFBundleIdentifier"]], stdout=console_log, stderr=console_log)
                    started = time.monotonic()
                    deadline = started + operation_timeout(render_deadline, 240, 75)
                    next_report = started + 15
                    while not (container / "Documents/preview-complete.json").exists():
                        if time.monotonic() >= deadline:
                            raise TimeoutError("Native preview did not complete all appearance variants.")
                        if time.monotonic() >= next_report:
                            event_file = container / "Documents/appearance-events.json"
                            state = "Waiting for UIKit app startup"
                            if event_file.exists():
                                state = event_file.read_text(errors="replace")[-700:]
                            progress(output, "Appearance sequence waiting", elapsed_seconds=round(time.monotonic() - started, 1),
                                latest_events=state)
                            next_report = time.monotonic() + 15
                        time.sleep(0.2)
                    progress(output, "All appearance variants rendered")
                    time.sleep(0.5)
                    run_logged(output, "screenshot", "xcrun", "simctl", "io", device, "screenshot",
                        *display_options, str(output / "simulator.png"), timeout=operation_timeout(render_deadline, 150, 60))
                finally:
                    # End recording while the final variant is still visible.
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
        progress(output, "Extracting recorded frames with ffprobe presentation times")
        frame_sheet(output, metadata, timeout=operation_timeout(render_deadline, 150))
        metadata.update({"runtime": runtime, "device_type": device_type, "device_name": device_name,
            "capture_display": 1 if display_options else "default",
            "production_duo_layout_test": "not performed", "production_source_sha256": hashlib.sha256(source.encode()).hexdigest(),
            "recording": "branding.mp4", "frame_contact_sheets": "frames/sheet-*.png", "frame_timestamps": "frames.tsv",
            "timestamp_source": "ffprobe frame pts_time; no fixed-rate resampling", "scope": "UIKit bitmap and host appearance; full app placement untested"})
        (output / "preview-verification.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        progress(output, "Rendered production appearance and labelled native frames")
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
