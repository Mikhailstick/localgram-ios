"""Export a small reproducible source repository; application credentials are excluded."""
import json
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    destination = ROOT.parent / "LocalGram-cloud"
    if destination.exists():
        raise SystemExit("Export directory already exists; refusing to overwrite it.")
    destination.mkdir()
    manifest = json.loads((ROOT / "LocalGifts/upstream.json").read_text())
    (destination / "upstream.json").write_text(json.dumps(manifest, indent=2))
    subprocess.run(["git", "diff", "--binary", "--output", str(destination / "local-gifts.patch")], cwd=ROOT, check=True)
    subprocess.run(["git", "apply", "--reverse", "--check", str(destination / "local-gifts.patch")], cwd=ROOT, check=True)
    untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=ROOT).decode().split("\0")
    allowed = ("LocalGifts/", "submodules/LocalGiftsUI/", "submodules/TelegramCore/Sources/LocalGifts/",
               "submodules/TelegramUI/Sources/LocalGifts", "Telegram/Telegram-iOS/LocalGramAssets.xcassets/",
               ".github/workflows/local-gifts.yml")
    count = 0
    for relative in untracked:
        if not relative or not (relative == "Package.swift" or relative.startswith(allowed)):
            continue
        if "/_build/" in relative or relative.endswith("application-credentials.json"):
            raise SystemExit("Refusing to include application credentials.")
        target = destination / "overlay" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, target)
        count += 1
    shutil.copy2(ROOT / "LocalGifts/README.ru.md", destination / "README.md")
    (destination / ".gitignore").write_text("client/\nartifacts/\n_build/\n__pycache__/\n")
    print(f"Exported {count} source/asset files and a verified patch to {destination}")


if __name__ == "__main__":
    main()
