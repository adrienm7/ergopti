# tools/build/karabiner_candidate_repack.py
"""Repair installer policy while retaining every compiled native payload byte."""

import argparse
from contextlib import contextmanager
import copy
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

from karabiner_candidate import native
from karabiner_candidate_install import digest, reference, verify_download
from karabiner_package_policy import postinstall_policy

POSTINSTALL = "Installer.pkg/Scripts/postinstall"


def archive_inventory(directory):
    """Account for the entire expanded archive, including scripts and empty folders."""
    root = Path(directory)
    result = {}
    def unreadable(error):
        raise error
    for parent, directories, files in os.walk(root, onerror=unreadable, followlinks=False):
        for name in directories + files:
            path = Path(parent) / name
            if path.is_symlink():
                raise ValueError("Redirected expanded package entry")
            key = path.relative_to(root).as_posix()
            if path.is_dir():
                result[key] = {"kind": "directory"}
            elif path.is_file():
                result[key] = {"kind": "file", "sha256": digest(path),
                               "mode": stat.S_IMODE(path.stat().st_mode)}
            else:
                raise ValueError("Unexpected special expanded package entry")
    if POSTINSTALL not in result or not any(name.endswith("/Payload") for name in result):
        raise ValueError("Expanded archive lacks its expected installer or payload")
    return result


def repair_expanded(directory):
    """Keep both component payloads and all other installer operations byte-identical."""
    directory = Path(directory)
    before = archive_inventory(directory)
    script = directory / POSTINSTALL
    replacement = postinstall_policy(script.read_bytes())
    script.write_bytes(replacement)
    after = archive_inventory(directory)
    expected = copy.deepcopy(before)
    expected[POSTINSTALL]["sha256"] = hashlib.sha256(replacement).hexdigest()
    if after != expected:
        raise ValueError("Package repair changed more than the pinned postinstall")
    return after


@contextmanager
def mounted_image(image, mount):
    """Release the exact read-only mount before temporary files can be removed."""
    native(["/usr/bin/hdiutil", "attach", str(image), "-nobrowse", "-readonly",
            "-mountpoint", str(mount)])
    try:
        yield mount / "Karabiner-Elements.pkg"
    finally:
        native(["/usr/bin/hdiutil", "detach", str(mount), "-quiet"])


def repack(directory, output):
    """Authenticate the retained producer, repackage once, and verify the round trip."""
    if sys.platform != "darwin":
        raise RuntimeError("Candidate repackaging requires native macOS tools")
    selected = reference()
    original_image = verify_download(directory, selected)
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("Repackaged candidate output must be new")
    with tempfile.TemporaryDirectory(prefix="ergopti-repack-") as temporary:
        temporary = Path(temporary)
        mount = temporary / "mount"
        mount.mkdir()
        expanded = temporary / "expanded"
        with mounted_image(original_image, mount) as original_package:
            native(["/usr/sbin/pkgutil", "--expand", str(original_package), str(expanded)])
        expected = repair_expanded(expanded)
        image_contents = temporary / "image"
        image_contents.mkdir()
        package = image_contents / "Karabiner-Elements.pkg"
        native(["/usr/sbin/pkgutil", "--flatten", str(expanded), str(package)])
        roundtrip = temporary / "roundtrip"
        native(["/usr/sbin/pkgutil", "--expand", str(package), str(roundtrip)])
        if archive_inventory(roundtrip) != expected:
            raise ValueError("Repackaging altered the preserved installer archive")
        output.mkdir(parents=True)
        image = output / "Ergopti-Karabiner-candidate-immutable.dmg"
        native(["/usr/bin/hdiutil", "create", "-srcfolder", str(image_contents), "-format", "UDZO",
                "-volname", "Ergopti Karabiner", str(image)])
        identity = copy.deepcopy(selected["identity"])
        identity["package"] = {"file_name": image.name, "sha256": digest(image)}
        receipt = {"kind": "installer-policy-repackage", "source_run": selected["run_id"],
                   "source_package_sha256": selected["identity"]["package"]["sha256"],
                   "unchanged_archive": expected, "identity": identity}
        (output / "identity.json").write_text(json.dumps(identity, indent=2) + "\n", encoding="utf-8", newline="\n")
        (output / "repackage.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8", newline="\n")
        return image


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory")
    parser.add_argument("output")
    arguments = parser.parse_args()
    image = repack(arguments.directory, arguments.output)
    print("image=" + str(image))
