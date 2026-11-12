"""Syntax checks only: an Xcode/Bazel build and iPhone test remain necessary."""
import ast
import json
import subprocess
from pathlib import Path
import tree_sitter
import tree_sitter_swift
import yaml
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SWIFT_FILES = [
    "Package.swift",
    "LocalGifts/Tests/LocalGiftsLedgerTests.swift",
    "submodules/TelegramCore/Sources/LocalGifts/LocalGiftsLedger.swift",
    "submodules/TelegramCore/Sources/LocalGifts/LocalGiftsStore.swift",
    "submodules/LocalGiftsUI/Sources/LocalGiftsController.swift",
    "submodules/TelegramUI/Sources/LocalGiftsChatEntries.swift",
    "submodules/TelegramUI/Sources/LocalGiftsChatActions.swift",
]


def errors(node):
    result = []
    if node.type == "ERROR" or node.is_missing:
        result.append((node.start_point.row + 1, node.start_point.column + 1, node.type))
    for child in node.children:
        result.extend(errors(child))
    return result


def main():
    parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
    failures = []
    for relative in SWIFT_FILES:
        issues = errors(parser.parse((ROOT / relative).read_bytes()).root_node)
        if issues:
            failures.append(f"{relative}: {issues[:12]}")
    changed = subprocess.check_output(["git", "diff", "--name-only"], cwd=ROOT, text=True).splitlines()
    for relative in changed:
        if not relative.endswith(".swift"):
            continue
        original = subprocess.check_output(["git", "show", f"HEAD:{relative}"], cwd=ROOT)
        previous = errors(parser.parse(original).root_node)
        current = errors(parser.parse((ROOT / relative).read_bytes()).root_node)
        if len(current) > len(previous):
            failures.append(f"{relative}: Swift parser errors increased from {len(previous)} to {len(current)}: {current[:8]}")
    for path in (ROOT / "LocalGifts").glob("*.py"):
        ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    ast.parse((ROOT / "build-system/Make/Make.py").read_text(encoding="utf-8"))
    for relative in ["Telegram/BUILD", "submodules/LocalGiftsUI/BUILD", "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/BUILD"]:
        ast.parse((ROOT / relative).read_text(encoding="utf-8"), filename=relative)
    workflow = yaml.load((ROOT / ".github/workflows/local-gifts.yml").read_text(), Loader=yaml.BaseLoader)
    if set(workflow["on"]) != {"workflow_dispatch"}:
        failures.append("The local build workflow must be manually triggered.")
    if workflow.get("permissions", {}).get("contents") != "read":
        failures.append("The build workflow must have read-only repository access.")
    icons = ROOT / "Telegram/Telegram-iOS/LocalGramAssets.xcassets/LocalGram.appiconset"
    manifest = json.loads((icons / "Contents.json").read_text())
    for icon in manifest["images"]:
        if icon["idiom"] == "ipad" and icon["size"] == "76x76" and icon["scale"] == "1x":
            failures.append("Xcode rejects the obsolete iPad 76x76@1x icon for this deployment target.")
        image = Image.open(icons / icon["filename"])
        expected = int(float(icon["size"].split("x")[0]) * int(icon["scale"].rstrip("x")))
        if image.size != (expected, expected) or image.mode != "RGB":
            failures.append("Invalid icon size or transparency: " + icon["filename"])
    diff = subprocess.run(["git", "diff", "--check"], cwd=ROOT, capture_output=True, text=True)
    if diff.returncode:
        failures.append(diff.stdout + diff.stderr)
    if failures:
        print("\n".join(failures))
        raise SystemExit(1)
    print(f"Syntax passed: {len(SWIFT_FILES)} new Swift files, modified Swift files, Python, Bazel definitions, workflow, and {len(manifest['images'])} icon assets.")
    print("These checks do not compile the iOS client or execute Swift unit tests.")


if __name__ == "__main__":
    main()
