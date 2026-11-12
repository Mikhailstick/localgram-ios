"""Build the actual Telegram-based client on a Mac; never creates a placeholder IPA."""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", choices=["release_arm64", "debug_arm64"], default="release_arm64")
    parser.add_argument("--build-number", type=int, default=100001)
    parser.add_argument("--check", action="store_true", help="Check build requirements without compiling.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("This is an iOS build: macOS with Xcode is required. Windows can hold the source and install a completed IPA.")
    version = json.loads((ROOT / "versions.json").read_text())["xcode"]
    if not shutil.which("xcodebuild"):
        raise SystemExit("Install Xcode " + version + " and select its Developer directory.")
    xcode = subprocess.check_output(["xcodebuild", "-version"], text=True)
    if not re.search(r"^Xcode " + re.escape(version) + r"\s*$", xcode, re.MULTILINE):
        raise SystemExit("This source is pinned to Xcode " + version + ". Select that Xcode instead of bypassing its version check.")
    if args.check:
        print("macOS and Xcode requirements passed; no compilation was performed.")
        return
    api_id = os.environ.get("TELEGRAM_API_ID", "")
    api_hash = os.environ.get("TELEGRAM_API_HASH", "")
    bundle_id = os.environ.get("LOCALGIFTS_BUNDLE_ID", "dev.localgram.client")
    if not api_id.isdigit() or not 0 < int(api_id) <= 2_147_483_647 or not re.fullmatch(r"[A-Fa-f0-9]{32}", api_hash):
        raise SystemExit("Set your application's TELEGRAM_API_ID and TELEGRAM_API_HASH from my.telegram.org/apps. Never use your login code or password here.")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*){2,}", bundle_id):
        raise SystemExit("LOCALGIFTS_BUNDLE_ID must be a reverse-domain identifier, for example dev.localgram.client.")
    build_directory = ROOT / "LocalGifts" / "_build"
    build_directory.mkdir(parents=True, exist_ok=True)
    config = {
        "bundle_id": bundle_id,
        "api_id": int(api_id),
        "api_hash": api_hash,
        "team_id": "LOCALGIFTS",
        "app_center_id": "0",
        "is_internal_build": "false",
        "is_appstore_build": "false",
        "appstore_id": "0",
        "app_specific_url_scheme": "localgifts",
        "premium_iap_product_id": "",
        "enable_siri": False,
        "enable_icloud": False,
    }
    configuration_path = build_directory / "configuration.json"
    configuration_path.write_text(json.dumps(config), encoding="utf-8")
    configuration_path.chmod(0o600)
    try:
        subprocess.run(["swift", "test", "--package-path", str(ROOT)], cwd=ROOT, check=True)
        subprocess.run([
            sys.executable, "build-system/Make/Make.py",
            "--cacheDir", str(Path.home() / "localgram-bazel-cache"),
            "build",
            "--configurationPath", str(configuration_path),
            "--xcodeManagedCodesigning",
            "--localGiftsUnsigned",
            "--configuration", args.configuration,
            "--buildNumber", str(args.build_number),
        ], cwd=ROOT, check=True)
        # bazel-bin points to this build. archive-root and old bazel-out folders can be stale.
        ipa = ROOT / "bazel-bin" / "Telegram" / "Telegram.ipa"
        if not ipa.is_file():
            raise SystemExit("Bazel finished without the expected device IPA; no artifact was exported.")
        output = ROOT / "LocalGifts" / "artifacts"
        output.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ipa, output / "LocalGram-unsigned.ipa")
        print("Built LocalGifts/artifacts/LocalGram-unsigned.ipa. Re-sign with Sideloadly before installation.")
    finally:
        configuration_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
