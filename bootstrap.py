"""Restore the exact public client source and apply the local feature implementation."""
import argparse
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", default=str(ROOT / "client"))
    parser.add_argument("--skip-submodules", action="store_true")
    args = parser.parse_args()
    destination = Path(args.destination).expanduser().resolve()
    if destination.exists():
        raise SystemExit("Destination already exists. Choose a new directory; existing files are never replaced.")
    manifest = json.loads((ROOT / "upstream.json").read_text())
    subprocess.run(["git", "init", str(destination)], check=True)
    subprocess.run(["git", "config", "core.longpaths", "true"], cwd=destination, check=True)
    subprocess.run(["git", "remote", "add", "origin", manifest["repository"]], cwd=destination, check=True)
    subprocess.run(["git", "fetch", "--depth", "1", "origin", manifest["commit"]], cwd=destination, check=True)
    subprocess.run(["git", "checkout", "--detach", "FETCH_HEAD"], cwd=destination, check=True)
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=destination, text=True).strip()
    if actual != manifest["commit"]:
        raise SystemExit("Fetched source does not match the pinned commit.")
    patch = ROOT / "local-gifts.patch"
    subprocess.run(["git", "apply", "--check", str(patch)], cwd=destination, check=True)
    for source in (ROOT / "overlay").rglob("*"):
        if not source.is_file():
            continue
        if source.is_symlink():
            raise SystemExit("Unexpected symbolic link in the source overlay.")
        relative = source.relative_to(ROOT / "overlay")
        target = destination / relative
        if destination not in target.resolve().parents or target.exists():
            raise SystemExit("Source overlay conflicts with an existing upstream file: " + str(relative))
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    subprocess.run(["git", "apply", str(patch)], cwd=destination, check=True)
    if not args.skip_submodules:
        subprocess.run(["git", "submodule", "update", "--init", "--recursive", "--depth", "1", "--jobs", "4"], cwd=destination, check=True)
    print("Prepared the full ExoraGram client at " + str(destination))


if __name__ == "__main__":
    main()
