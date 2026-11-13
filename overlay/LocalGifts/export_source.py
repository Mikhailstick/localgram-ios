"""Refresh the existing small source repository with a pinned patch and explicit source overlay."""
import argparse
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWED = (
    "LocalGifts/", "Ghostgram/LocalGiftsUI/", "submodules/TelegramCore/Sources/LocalGifts/",
    "submodules/TelegramUI/Sources/LocalGifts", "Telegram/Telegram-iOS/LocalGramAssets.xcassets/",
    "Telegram/Telegram-iOS/LocalGramIcon@3x.png",
    ".github/workflows/local-gifts.yml",
)


def git(*args, cwd=ROOT):
    return subprocess.check_output(["git", *args], cwd=cwd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path, default=ROOT.parent / "LocalGram-cloud")
    args = parser.parse_args()
    destination = args.destination.resolve()
    if not (destination / ".git").exists() or not (destination / "bootstrap.py").is_file():
        raise SystemExit("Choose the existing LocalGram source-export repository.")
    if git("remote", "get-url", "origin", cwd=destination).decode().strip() != "https://github.com/Mikhailstick/localgram-ios.git":
        raise SystemExit("Unexpected export repository; nothing was replaced.")
    manifest = json.loads((ROOT / "LocalGifts/upstream.json").read_text())
    if git("rev-parse", "HEAD").decode().strip() != manifest["commit"]:
        raise SystemExit("Source checkout does not match the pinned upstream commit.")
    untracked = git("ls-files", "--others", "--exclude-standard", "-z").decode().split("\0")
    sources = []
    for name in untracked:
        if not name or not (name == "Package.swift" or name.startswith(ALLOWED)):
            continue
        if any(part in name.split("/") for part in ("_build", "artifacts", "__pycache__")):
            continue
        if name.endswith((".rej", ".orig", ".ipa", ".p12", ".mobileprovision", "application-credentials.json")):
            raise SystemExit("Unexpected file in source overlay: " + name)
        source = ROOT / name
        if source.is_symlink():
            raise SystemExit("Unexpected overlay symlink: " + name)
        sources.append(name)
    patch = destination / "local-gifts.patch"
    patch.write_bytes(git("diff", "--binary"))
    subprocess.run(["git", "apply", "--reverse", "--check", str(patch)], cwd=ROOT, check=True)
    expected = {"overlay/" + name for name in sources}
    previous = git("ls-files", "-z", "--", "overlay", cwd=destination).decode().split("\0")
    for name in previous:
        if name and name not in expected:
            path = (destination / name).resolve()
            if destination not in path.parents or not name.startswith("overlay/"):
                raise SystemExit("Invalid stale overlay path.")
            path.unlink(missing_ok=True)
    for name in sources:
        target = destination / "overlay" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
    shutil.copy2(ROOT / "LocalGifts/upstream.json", destination / "upstream.json")
    shutil.copy2(ROOT / "LocalGifts/README.ru.md", destination / "README.md")
    shutil.copy2(ROOT / "LICENSE", destination / "LICENSE")
    shutil.copy2(ROOT / ".github/workflows/local-gifts.yml", destination / ".github/workflows/local-gifts.yml")
    print(f"Exported {len(sources)} source and asset files; patch reverse-check passed.")


if __name__ == "__main__":
    main()
