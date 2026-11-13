"""Permit unsigned device packaging in the pinned Apple rules; Sideloadly signs the result."""
import subprocess
from pathlib import Path

PINNED_RULES_COMMIT = "485016eb5b0948cc17307064e7977a6d68e94046"


def prepare_unsigned_rules(root: Path):
    rules = root / "build-system/bazel-rules/rules_apple"
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=rules, text=True).strip()
    if actual != PINNED_RULES_COMMIT:
        raise RuntimeError("Unexpected Apple rules version; unsigned device packaging needs review.")
    ios_rules = rules / "apple/internal/ios_rules.bzl"
    source = ios_rules.read_text(encoding="utf-8")
    original = (
        "    if platform_prerequisites.platform.is_device:\n"
        "        processor_partials.append(\n"
        "            partials.provisioning_profile_partial("
    )
    replacement = (
        '    if platform_prerequisites.platform.is_device and "disable_legacy_signing" not in ctx.features:\n'
        "        processor_partials.append(\n"
        "            partials.provisioning_profile_partial("
    )
    if original not in source:
        if replacement in source:
            return
        raise RuntimeError("The expected device-profile packaging rule is missing.")
    support = (rules / "apple/internal/codesigning_support.bzl").read_text(encoding="utf-8")
    if '"disable_legacy_signing" in features' not in support:
        raise RuntimeError("Pinned Apple rules do not support the unsigned feature.")
    ios_rules.write_text(source.replace(original, replacement), encoding="utf-8")
    print("Prepared unsigned device packaging; signed builds retain the provisioning-profile requirement.")
