"""Render the actual UIKit brand functions on a disposable CI simulator.

This checks the bitmap and typography only; it does not test the full app's UI.
"""
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


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def function(source, name):
    start = source.index("private func " + name + "(")
    opening = source.index("{", start)
    depth = 0
    for offset in range(opening, len(source)):
        depth += (source[offset] == "{") - (source[offset] == "}")
        if depth == 0:
            return source[start:offset + 1]
    raise ValueError("Incomplete renderer: " + name)


def main():
    if platform.system() != "Darwin":
        raise SystemExit("UIKit preview needs macOS with the iOS Simulator SDK.")
    source = (ROOT / "Ghostgram/GGSettingsUI/Sources/Style/GGMenuIcons.swift").read_text()
    pieces = ["""import UIKit
extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
"""]
    for name in ("ggHeaderMarkSymbol", "ggBrandColors"):
        pieces.append(re.search(r"^private let " + name + r"[^\n]*", source, re.MULTILINE).group())
    for name in ("ggRenderLocalGramIslandBadge", "ggRenderSettingsTile", "ggRenderBrandMark"):
        pieces.append(function(source, name))
    pieces.append('''
final class PreviewDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let badge = ggRenderLocalGramIslandBadge()!
        let tile = ggRenderSettingsTile()!
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try! badge.pngData()!.write(to: directory.appendingPathComponent("badge.png"))
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
        let controller = UIViewController()
        controller.view.backgroundColor = .systemGroupedBackground
        let imageView = UIImageView(image: preview)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(x: 0, y: 150, width: 320, height: 180)
        controller.view.addSubview(imageView)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(PreviewDelegate.self))
''')
    output = ROOT / "LocalGifts/artifacts/branding"
    output.mkdir(parents=True, exist_ok=True)
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    runtime = next(item["identifier"] for item in reversed(runtimes) if item.get("isAvailable") and ".iOS-" in item["identifier"])
    types = json.loads(run("xcrun", "simctl", "list", "devicetypes", "--json"))["devicetypes"]
    device_type = next(item["identifier"] for item in reversed(types) if item["name"].startswith("iPhone") and "Pro" in item["name"])
    device = run("xcrun", "simctl", "create", "LocalGram branding preview", device_type, runtime)
    try:
        with tempfile.TemporaryDirectory(prefix="localgram-branding-") as scratch:
            app = Path(scratch) / "Preview.app"
            app.mkdir()
            swift = Path(scratch) / "main.swift"
            swift.write_text("\n".join(pieces))
            info = {"CFBundleIdentifier": "dev.localgram.brandingpreview", "CFBundleExecutable": "Preview", "CFBundleName": "Preview", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL", "MinimumOSVersion": "15.0", "UIDeviceFamily": [1], "UILaunchScreen": {}}
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
            subprocess.run(["xcrun", "swiftc", "-sdk", sdk, "-target", "arm64-apple-ios15.0-simulator", str(swift), "-o", str(app / "Preview")], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
            run("xcrun", "simctl", "boot", device)
            run("xcrun", "simctl", "bootstatus", device, "-b")
            run("xcrun", "simctl", "install", device, str(app))
            with (output / "recording.log").open("w") as recording_log:
                recording = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo", "--codec=h264", "--force", str(output / "branding.mp4")], stdout=recording_log, stderr=recording_log)
                try:
                    time.sleep(1)
                    run("xcrun", "simctl", "launch", device, info["CFBundleIdentifier"])
                    time.sleep(2)
                finally:
                    recording.send_signal(signal.SIGINT)
                    recording.wait(timeout=30)
            container = Path(run("xcrun", "simctl", "get_app_container", device, info["CFBundleIdentifier"], "data"))
            for _ in range(30):
                if (container / "Documents/branding-preview.png").exists():
                    break
                time.sleep(1)
            for name in ("badge.png", "branding-preview.png"):
                shutil.copy2(container / "Documents" / name, output / name)
            run("xcrun", "simctl", "io", device, "screenshot", str(output / "simulator.png"))
        print("Rendered the production LocalGram badge and settings icon using UIKit.")
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], check=False)
        subprocess.run(["xcrun", "simctl", "delete", device], check=False)


if __name__ == "__main__":
    main()
