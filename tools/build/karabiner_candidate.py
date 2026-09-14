# tools/build/karabiner_candidate.py
"""Package all cooperating Karabiner peers for disposable native acceptance."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "diagnostics"))
from hs274_raw_patch import REVISION


PRODUCTS = (
    ("apps/AppIconSwitcher", "Karabiner-AppIconSwitcher.app"),
    ("apps/EventViewer", "Karabiner-EventViewer.app"),
    ("apps/MultitouchExtension", "Karabiner-MultitouchExtension.app"),
    ("apps/ServiceManager-Non-Privileged-Agents", "Karabiner-Elements Non-Privileged Agents v2.app"),
    ("apps/ServiceManager-Privileged-Daemons", "Karabiner-Elements Privileged Daemons v2.app"),
    ("apps/SettingsWindow", "Karabiner-Elements.app"),
    ("apps/Updater", "Karabiner-Updater.app"),
    ("bin/cli", "karabiner_cli"),
    ("apps/ConsoleUserServer", "Karabiner-Console-User-Server.app"),
    ("apps/CoreService", "Karabiner-Core-Service.app"),
)
BUILD_STEP = 'echo "make build"\nruby scripts/reduce-logs.rb \'make build\' || exit 99'
SIGN_STEP = 'bash scripts/codesign.sh "pkgroot"'

LAUNCHD_RESOURCES = (
    ("src/apps/ServiceManager-Non-Privileged-Agents/LaunchAgents", "apps/ServiceManager-Non-Privileged-Agents", "LaunchAgents"),
    ("src/apps/ServiceManager-Privileged-Daemons/LaunchDaemons", "apps/ServiceManager-Privileged-Daemons", "LaunchDaemons"),
    ("vendor/Karabiner-DriverKit-VirtualHIDDevice/files/LaunchDaemons", "apps/ServiceManager-Privileged-Daemons", "LaunchDaemons"),
)


def pinned_root(root):
    """Only operate in the inspected native build checkout."""
    if sys.platform != "darwin":
        raise RuntimeError("Candidate packaging requires native macOS tools")
    root = Path(root).resolve()
    revision = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise ValueError("Candidate requires the inspected Karabiner revision")
    return root


def build(root):
    """Retain every upstream post-build recipe while bounding compiler parallelism."""
    root = pinned_root(root)
    makefiles = ["src/Makefile"] + ["src/" + component + "/Makefile" for component, _ in PRODUCTS]
    for relative in makefiles:
        expected = subprocess.check_output(["git", "-C", str(root), "show", "HEAD:" + relative])
        if (root / relative).read_bytes() != expected:
            raise ValueError("Refusing modified upstream build commands")
    with tempfile.TemporaryDirectory(prefix="ergopti-build-tools-") as directory:
        wrapper = Path(directory) / "xcodebuild"
        wrapper.write_text('#!/bin/sh\nexec /usr/bin/xcodebuild -jobs 2 "$@"\n', encoding="utf-8", newline="\n")
        wrapper.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = directory + os.pathsep + environment["PATH"]
        subprocess.run(["/usr/bin/make", "-C", str(root / "src"), "all"], env=environment, check=True)
    # The service-manager recipes copy launchd plists after Xcode signing.
    # Seal the complete candidate only after those upstream mutations finish.
    for component, name in PRODUCTS:
        product = root / "src" / component / "build/Release" / name
        if not product.exists() or product.resolve() != product:
            raise ValueError("Missing or redirected product before candidate signing")
        subprocess.run(["/usr/bin/codesign", "--force", "--deep",
                        "--preserve-metadata=identifier,entitlements,flags", "--sign", "-", str(product)], check=True)


def verify_launchd_resources(root):
    """A signed executable alone cannot register its required agents and daemons."""
    names = dict(PRODUCTS)
    copied = set()
    for source, component, folder in LAUNCHD_RESOURCES:
        resources = sorted((root / source).glob("*.plist"))
        if not resources:
            raise ValueError("Missing upstream launchd resources")
        target = root / "src" / component / "build/Release" / names[component] / "Contents/Library" / folder
        for resource in resources:
            destination = target / resource.name
            if destination in copied or resource.resolve() != resource or destination.resolve() != destination:
                raise ValueError("Conflicting or redirected launchd resources")
            if not destination.is_file() or destination.read_bytes() != resource.read_bytes():
                raise ValueError("Missing or changed launchd resource in candidate")
            copied.add(destination)


def native(command):
    """Require native verification to succeed; never admit an unchecked product."""
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as error:
        sys.stderr.write(error.output or "")
        raise


def inspect_product(product, verify=native):
    """Verify an actual build or installed product with the same native policy."""
    product = Path(product)
    if not product.exists() or product.resolve() != product:
        raise ValueError("Missing or redirected Karabiner product: " + str(product))
    executable = product
    if product.suffix == ".app":
        info = product / "Contents/Info.plist"
        if info.resolve() != info or not info.is_file():
            raise ValueError("Missing or redirected product metadata")
        metadata = plistlib.loads(info.read_bytes())
        name = metadata.get("CFBundleExecutable")
        if (not isinstance(name, str) or not name or name in (".", "..")
                or "/" in name or "\\" in name):
            raise ValueError("Invalid product executable name")
        executable = product / "Contents/MacOS" / name
    if not executable.is_file() or executable.resolve() != executable:
        raise ValueError("Missing or redirected product executable")
    verify(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(product)])
    signature = verify(["/usr/bin/codesign", "--display", "--verbose=4", str(product)])
    teams = re.findall(r"^TeamIdentifier=(.+)$", signature, re.MULTILINE)
    if len(teams) != 1 or not teams[0].strip():
        raise ValueError("Karabiner signature has no exact team identity")
    team = teams[0].strip()
    architectures = verify(["/usr/bin/lipo", "-archs", str(executable)]).split()
    if sorted(architectures) != ["arm64", "x86_64"]:
        raise ValueError("Karabiner candidate must contain both supported architectures")
    return {"executable": executable, "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            "architectures": sorted(architectures), "team_identifier": team}


def inspect_products(root, verify=native):
    """Verify the complete peer set before allowing package assembly."""
    root = Path(root).resolve()
    verify_launchd_resources(root)
    receipts = []
    for component, name in PRODUCTS:
        product = root / "src" / component / "build/Release" / name
        receipt = inspect_product(product, verify)
        receipt["product"] = product.relative_to(root).as_posix()
        receipt["executable"] = receipt["executable"].relative_to(root).as_posix()
        receipts.append(receipt)
    if len({row["team_identifier"] for row in receipts}) != 1:
        raise ValueError("Karabiner candidate mixes different signing teams")
    return receipts


def packaging_script(source, receipt):
    """Reuse the pinned upstream assembly after the complete build was verified."""
    if source.count(BUILD_STEP) != 1 or source.count(SIGN_STEP) != 1:
        raise ValueError("Pinned Karabiner packaging script changed")
    source = source.replace(BUILD_STEP, '# All components were built and verified by the caller.', 1)
    target = 'pkgroot/Library/Application Support/org.pqrs/Karabiner-Elements/ergopti-candidate.json'
    return source.replace(SIGN_STEP, 'cp ' + shlex.quote(str(receipt)) + ' ' + shlex.quote(target)
                          + "\n" + SIGN_STEP, 1)


def assemble(root, output):
    """Build a candidate DMG, never install it or select it for normal onboarding."""
    root = pinned_root(root)
    output = Path(output).resolve()
    # Upstream assembly owns these paths in its disposable build checkout.
    version = (root / "version").read_text(encoding="utf-8").strip()
    pinned_version = subprocess.check_output(["git", "-C", str(root), "show", "HEAD:version"], text=True).strip()
    if version != pinned_version or not version or any(c not in "0123456789." for c in version):
        raise ValueError("Unexpected upstream package version")
    archive = root / ("Karabiner-Elements-" + version + ".dmg")
    for owned in (root / "pkgroot", root / ("Karabiner-Elements-" + version), archive):
        if owned.exists() or owned.is_symlink():
            raise ValueError("Refusing to replace existing package assembly state")
    if output.exists() or output.is_symlink():
        raise ValueError("Candidate output must be new")
    products = inspect_products(root)
    source = (root / "make-package.sh").read_text(encoding="utf-8")
    pinned_source = subprocess.check_output(["git", "-C", str(root), "show", "HEAD:make-package.sh"]).decode("utf-8")
    if source != pinned_source:
        raise ValueError("Refusing modified upstream packaging commands")
    receipt = {"kind": "ergopti-karabiner-candidate", "coverage": "fixture_only",
               "upstream_revision": REVISION, "products": products}
    with tempfile.TemporaryDirectory(prefix="ergopti-candidate-") as temporary:
        temporary = Path(temporary)
        identity = temporary / "identity.json"
        identity.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8", newline="\n")
        script = temporary / "assemble.sh"
        script.write_text(packaging_script(source, identity), encoding="utf-8", newline="\n")
        subprocess.run(["/bin/bash", str(script)], cwd=root, check=True)
        if not archive.is_file() or archive.is_symlink():
            raise RuntimeError("Native package assembly did not produce its image")
        output.mkdir()
        destination = output / ("Ergopti-Karabiner-candidate-" + version + ".dmg")
        shutil.copyfile(archive, destination)
        with destination.open("rb") as image:
            digest = hashlib.file_digest(image, "sha256").hexdigest()
        receipt["package"] = {"file_name": destination.name, "sha256": digest}
        (output / "identity.json").write_text(json.dumps(receipt, indent=2) + "\n",
                                             encoding="utf-8", newline="\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--root", type=Path)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    if arguments.build and arguments.root is not None and arguments.output is None:
        build(arguments.root)
    elif not arguments.build and arguments.root is not None and arguments.output is not None:
        assemble(arguments.root, arguments.output)
    else:
        parser.error("choose --build --root or both --root and --output")
