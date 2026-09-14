# tools/build/karabiner_test_fixture.py
"""Isolated complete product trees shared by package and installation tests."""

from pathlib import Path
import plistlib
import subprocess

from karabiner_candidate import LAUNCHD_RESOURCES, PRODUCTS


def make_products(directory, resources=True):
    root = Path(directory).resolve()
    for component, name in PRODUCTS:
        product = root / "src" / component / "build/Release" / name
        executable = product
        if name.endswith(".app"):
            (product / "Contents").mkdir(parents=True)
            (product / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "native-peer"}))
            executable = product / "Contents/MacOS/native-peer"
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_bytes(component.encode("utf-8"))
    if resources:
        for index, (source, component, folder) in enumerate(LAUNCHD_RESOURCES):
            original = root / source / (str(index) + ".plist")
            copied = root / "src" / component / "build/Release" / dict(PRODUCTS)[component] / "Contents/Library" / folder / original.name
            original.parent.mkdir(parents=True, exist_ok=True)
            copied.parent.mkdir(parents=True, exist_ok=True)
            contents = plistlib.dumps({"Label": "candidate-" + str(index)})
            original.write_bytes(contents)
            copied.write_bytes(contents)
    return root

def signature_verifier(calls, fail=None):
    def verify(command):
        calls.append(command)
        if fail and fail in command[-1]:
            raise subprocess.CalledProcessError(1, command)
        if "--display" in command:
            return "TeamIdentifier=not set\n"
        return "arm64 x86_64\n" if command[0].endswith("lipo") else ""
    return verify

