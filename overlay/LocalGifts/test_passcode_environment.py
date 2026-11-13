"""Compile the real keychain-group resolver without the unrelated Telegram dependency graph."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    if not shutil.which("swift"):
        raise SystemExit("Swift is required to execute the passcode environment checks.")
    source = (ROOT / "submodules/PasscodeCore/Sources/Passcode.swift").read_text()
    start = source.index("public struct PasscodeConfiguration:")
    end = source.index("protocol PasscodeStorage {")
    checks = r'''
func expectUnavailable(_ action: () throws -> Void) {
    do { try action(); fatalError("Expected unavailable") }
    catch PasscodeError.unavailable {}
    catch { fatalError("Unexpected error: \(error)") }
}
let empty = PasscodeEnvironment()
expectUnavailable { _ = try empty.sharedAccessGroup() }
let shared = PasscodeEnvironment()
try shared.configure(PasscodeConfiguration(appGroupIdentifier: "group.dev.localgram.client", processRole: .mainApp), privateAccessGroup: { "TEAM.dev.localgram.client" })
assert(try shared.sharedAccessGroup() == "group.dev.localgram.client")
let personal = PasscodeEnvironment()
var resolutions = 0
let personalConfig = PasscodeConfiguration(appGroupIdentifier: "group.dev.localgram.client", processRole: .mainApp, usesSharedKeychain: false)
try personal.configure(personalConfig, privateAccessGroup: { resolutions += 1; return "TEAM.dev.localgram.client" })
let first = try personal.sharedAccessGroup()
let second = try personal.sharedAccessGroup()
assert(first == "TEAM.dev.localgram.client" && second == first && resolutions == 1)
try personal.configure(personalConfig, privateAccessGroup: { "not-used" })
expectUnavailable { try personal.configure(PasscodeConfiguration(appGroupIdentifier: "group.dev.localgram.client", processRole: .mainApp), privateAccessGroup: { "wrong" }) }
let missing = PasscodeEnvironment()
try missing.configure(personalConfig, privateAccessGroup: { nil })
expectUnavailable { _ = try missing.sharedAccessGroup() }
let extensionEnvironment = PasscodeEnvironment()
try extensionEnvironment.configure(PasscodeConfiguration(appGroupIdentifier: "group.dev.localgram.client", processRole: .appExtension, usesSharedKeychain: false))
expectUnavailable { _ = try extensionEnvironment.sharedAccessGroup() }
print("Passcode environment checks passed: shared and personal groups, cached resolution, configuration conflicts and unavailable groups.")
'''
    # assert's autoclosure cannot throw.
    checks = checks.replace('assert(try shared.sharedAccessGroup() == "group.dev.localgram.client")', 'let sharedGroup = try shared.sharedAccessGroup()\nassert(sharedGroup == "group.dev.localgram.client")')
    with tempfile.TemporaryDirectory(prefix="localgram-passcode-") as scratch:
        path = Path(scratch) / "main.swift"
        path.write_text("import Foundation\nenum PasscodeError: Error { case unavailable }\n" + source[start:end] + checks)
        subprocess.run(["swift", str(path)], check=True, timeout=120)


if __name__ == "__main__":
    main()
