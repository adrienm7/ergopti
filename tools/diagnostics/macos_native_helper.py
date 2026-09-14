# tools/diagnostics/macos_native_helper.py
"""Verify the actual helper-only package without starting an application UI."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys


def digest(path):
    """Hash artifact bytes without retaining a second in-memory copy."""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def source_identity():
    """Bind a reusable helper to its actual shared source inputs, not unrelated commits."""
    root = Path(__file__).resolve().parents[2]
    launcher = "static/ergopti_plus/macos/launcher/"
    required = [launcher + name for name in ("Package.swift", "ErgoptiPlus.entitlements",
                                             "com.ergoptiplus.remap-guardian.plist")]
    selected = subprocess.check_output(["git", "ls-files", "-z", "--", launcher + "Sources", *required], cwd=root)
    paths = selected.decode("utf-8").rstrip("\0").split("\0")
    if not set(required).issubset(paths) or not any(name.startswith(launcher + "Sources/") for name in paths):
        raise ValueError("Native helper source identity is incomplete")
    return {name: digest(root / name) for name in sorted(paths)}


def observe(application, output):
    """Exercise native loading and exact executable identity in the built helper."""
    if sys.platform != "darwin":
        raise RuntimeError("Native helper acceptance requires macOS")
    application = Path(application).resolve(strict=True)
    executable = application / "Contents/MacOS/ErgoptiPlus"
    plist = plistlib.loads((application / "Contents/Info.plist").read_bytes())
    if (plist.get("LSUIElement") is not True or plist.get("SUEnableAutomaticChecks") is not False
            or plist.get("SUAllowsAutomaticUpdates") is not False
            or any(key in plist for key in ("CFBundleURLTypes", "SUFeedURL"))):
        raise ValueError("Helper package unexpectedly owns a GUI update entrypoint")
    for relative in ("Contents/Frameworks/Hammerspoon.app", "Contents/Resources/Tools", "Contents/Resources/static"):
        if (application / relative).exists():
            raise ValueError("Helper package unexpectedly includes full-application payloads")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(application)], check=True)
    environment = os.environ.copy()
    identity = executable.stat()
    environment["ERGOPTI_LAUNCHER_EXECUTABLE"] = str(executable)
    environment["ERGOPTI_LAUNCHER_DEVICE"] = str(identity.st_dev)
    environment["ERGOPTI_LAUNCHER_INODE"] = str(identity.st_ino)
    command = [str(executable), "--remap-guardian-status"]
    result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=10)
    if result.returncode != 0 or result.stdout.strip() not in ("ready", "requires_approval", "unavailable"):
        raise RuntimeError("Helper headless status failed: " + repr((result.returncode, result.stdout, result.stderr)))
    environment["ERGOPTI_LAUNCHER_INODE"] = str(identity.st_ino + 1)
    rejected = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=10)
    if rejected.returncode != 64 or rejected.stdout:
        raise RuntimeError("Helper admitted the wrong executable identity")
    archive = application.with_name(application.name + ".zip")
    architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(executable)], text=True).split()
    receipt = {"kind": "native-helper-package", "revision": os.environ.get("GITHUB_SHA"),
               "executable_sha256": digest(executable), "architectures": architectures,
               "sources": source_identity(),
               "archive_sha256": digest(archive), "archive_bytes": archive.stat().st_size,
               "guardian_status": result.stdout.strip(), "wrong_identity_exit": rejected.returncode,
               "hammerspoon_bootstrap_verified": False}
    Path(output).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Expected application and receipt output paths")
    observe(sys.argv[1], sys.argv[2])
