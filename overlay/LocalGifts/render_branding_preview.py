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


def run(*args, timeout=150):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=timeout).strip()
    except subprocess.CalledProcessError as error:
        print(error.output, flush=True)
        raise


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
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        NSLog("LocalGram branding preview rendered in %@", directory.path)
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(PreviewAppDelegate.self))
''')
    output = ROOT / "LocalGifts/artifacts/branding"
    output.mkdir(parents=True, exist_ok=True)
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    available = [item for item in runtimes if item.get("isAvailable") and ".iOS-" in item["identifier"]]
    types = json.loads(run("xcrun", "simctl", "list", "devicetypes", "--json"))["devicetypes"]
    sdk_version = tuple(map(int, run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version").split(".")))
    runtime = None
    device_type = None
    for candidate in sorted(available, key=lambda item: tuple(map(int, item["version"].split("."))), reverse=True):
        if tuple(map(int, candidate["version"].split("."))) > sdk_version:
            continue
        if not re.search(r"\.iOS-\d+-\d+(?:-\d+)?$", candidate["identifier"]):
            continue
        supported = candidate.get("supportedDeviceTypes", [])
        supported_ids = {item["identifier"] if isinstance(item, dict) else item for item in supported}
        # Some beta runtimes are restricted to one new iPhone model. Do not pair those
        # with a device selected independently from CoreSimulator's type inventory.
        if not supported_ids and not re.search(r"\.iOS-\d+-\d+(?:-\d+)?$", candidate["identifier"]):
            continue
        compatible = [item for item in types if item["name"].startswith("iPhone") and "Duo" not in item["name"] and (not supported_ids or item["identifier"] in supported_ids)]
        if not compatible:
            continue
        preferred = next((item for item in compatible if item["name"] == "iPhone 17 Pro"), None)
        runtime = candidate["identifier"]
        device_type = (preferred or compatible[-1])["identifier"]
        break
    if runtime is None:
        raise RuntimeError("No compatible installed iPhone simulator runtime/type pair.")
    print("Rendering on " + device_type + " with " + runtime, flush=True)
    device = run("xcrun", "simctl", "create", "LocalGram branding preview", device_type, runtime)
    try:
        with tempfile.TemporaryDirectory(prefix="localgram-branding-") as scratch:
            app = Path(scratch) / "Preview.app"
            app.mkdir()
            swift = Path(scratch) / "main.swift"
            swift.write_text("\n".join(pieces))
            info = {"CFBundleIdentifier": "dev.localgram.brandingpreview", "CFBundleExecutable": "Preview", "CFBundleName": "Preview", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL", "MinimumOSVersion": "15.0", "UIDeviceFamily": [1], "LSRequiresIPhoneOS": True, "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "UILaunchScreen": {}, "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False, "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [{"UISceneConfigurationName": "Default", "UISceneDelegateClassName": "PreviewSceneDelegate"}]}}}
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
            subprocess.run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-sdk", sdk, "-target", "arm64-apple-ios15.0-simulator", "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift", str(swift), "-o", str(app / "Preview")], check=True, timeout=120)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, timeout=30)
            run("xcrun", "simctl", "boot", device)
            run("xcrun", "simctl", "bootstatus", device, "-b", timeout=240)
            run("xcrun", "simctl", "install", device, str(app))
            container = Path(run("xcrun", "simctl", "get_app_container", device, info["CFBundleIdentifier"], "data"))
            with (output / "recording.log").open("w") as recording_log, (output / "console.log").open("w") as console_log:
                recording = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo", "--codec=h264", "--force", str(output / "branding.mp4")], stdout=recording_log, stderr=recording_log)
                try:
                    time.sleep(1)
                    launcher = subprocess.Popen(["xcrun", "simctl", "launch", "--console", device, info["CFBundleIdentifier"]], stdout=console_log, stderr=console_log)
                    for _ in range(30):
                        if (container / "Documents/branding-preview.png").exists():
                            time.sleep(1)
                            run("xcrun", "simctl", "io", device, "screenshot", str(output / "simulator.png"))
                            break
                        time.sleep(1)
                    subprocess.run(["xcrun", "simctl", "terminate", device, info["CFBundleIdentifier"]], check=False, timeout=20)
                    launcher.wait(timeout=20)
                finally:
                    recording.send_signal(signal.SIGINT)
                    recording.wait(timeout=30)
            for name in ("badge.png", "branding-preview.png"):
                shutil.copy2(container / "Documents" / name, output / name)
        print("Rendered the production LocalGram badge and settings icon using UIKit.")
    finally:
        for operation in ("shutdown", "delete"):
            try:
                subprocess.run(["xcrun", "simctl", operation, device], check=False, timeout=20)
            except subprocess.TimeoutExpired:
                print("Simulator cleanup timed out: " + operation)


if __name__ == "__main__":
    main()
