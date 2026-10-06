#!/usr/bin/env python3
# tools/test/fixtures/validation-curl/prepare_validation_keyring.py
"""Stage an independently authenticated validation keyring, never a host keyring.

The original setup_validation_curl verifier remains responsible for fresh full
InRelease signature verification, command-zero and the exact required signer.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import sys
import time

MAX_INPUT = 8 * 1048576


def refuse():
    raise RuntimeError("Private validation keyring admission refused.")


def fields(value, names):
    if type(value) is not dict or set(value) != set(names):
        refuse()


def sha(value):
    if type(value) is not str or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        refuse()


def length(value):
    if type(value) is not int or not 0 < value <= MAX_INPUT:
        refuse()


def capture_pins(pins):
    if type(pins) is not dict:
        refuse()
    cfg = pins.get("validation_keyring")
    fields(
        cfg,
        (
            "authority",
            "qualification_sha256",
            "inrelease_sha256",
            "required_signer",
            "index",
            "package",
            "aggregate",
        ),
    )
    if cfg["authority"] != "official_debian_signed_distribution_package":
        refuse()
    sha(cfg["qualification_sha256"])
    legacy = pins.get("legacy")
    if type(legacy) is not dict:
        refuse()
    if cfg["inrelease_sha256"] != legacy.get("inrelease_sha256") or cfg[
        "required_signer"
    ] != legacy.get("required_signer"):
        refuse()
    sha(cfg["inrelease_sha256"])
    if (
        type(cfg["required_signer"]) is not str
        or re.fullmatch(r"[0-9A-F]{40}", cfg["required_signer"]) is None
    ):
        refuse()
    index = cfg["index"]
    fields(index, ("path", "sha256", "size"))
    if index != legacy.get("metadata"):
        refuse()
    sha(index["sha256"])
    if type(index["size"]) is not int or index["size"] <= 0:
        refuse()
    package = cfg["package"]
    fields(
        package,
        ("name", "version", "architecture", "publisher", "filename", "url", "sha256", "size"),
    )
    if (
        package["name"] != "debian-archive-keyring"
        or package["architecture"] != "all"
        or package["publisher"] != "Debian Release Team <packages@release.debian.org>"
    ):
        refuse()
    version = package["version"]
    if (
        type(version) is not str
        or re.fullmatch(r"[0-9]{4}\.[0-9]+(?:\+deb[0-9]+u[0-9]+)?", version) is None
    ):
        refuse()
    filename = "pool/main/d/debian-archive-keyring/debian-archive-keyring_" + version + "_all.deb"
    if (
        package["filename"] != filename
        or package["url"] != "https://deb.debian.org/debian/" + filename
    ):
        refuse()
    sha(package["sha256"])
    length(package["size"])
    aggregate = cfg["aggregate"]
    fields(aggregate, ("path", "sha256", "size"))
    if aggregate["path"] != "usr/share/keyrings/debian-archive-keyring.gpg":
        refuse()
    sha(aggregate["sha256"])
    length(aggregate["size"])
    # Detach the immutable scalar records before any native command.
    return {**cfg, "index": dict(index), "package": dict(package), "aggregate": dict(aggregate)}


def receive_package_fields(text, package):
    if (
        type(text) is not str
        or text != "\n".join((package["name"], package["version"], package["architecture"])) + "\n"
    ):
        refuse()


def regular_bytes(path, expected=None, size=None):
    path = Path(path)
    if not path.is_absolute():
        refuse()
    at = Path(path.anchor)
    for part in path.parts[1:]:
        if part in (".", ".."):
            refuse()
        at /= part
        if stat.S_ISLNK(at.lstat().st_mode):
            refuse()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    primary = None
    result = None
    try:
        before = os.fstat(fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or not 0 < before.st_size <= MAX_INPUT
            or (size is not None and before.st_size != size)
        ):
            refuse()
        result = os.pread(fd, MAX_INPUT + 1, 0)
        after = os.fstat(fd)
        if len(result) != before.st_size or (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_size,
            before.st_mtime_ns,
        ) != (after.st_dev, after.st_ino, after.st_mode, after.st_size, after.st_mtime_ns):
            refuse()
        if expected is not None and hashlib.sha256(result).hexdigest() != expected:
            refuse()
    except BaseException as error:
        primary = error
    finally:
        try:
            os.close(fd)  # once only; uncertainty cannot authorize a receipt
        except BaseException as error:
            if primary is None:
                primary = error
    if primary is not None:
        raise primary
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    if (
        platform.system() != "Linux"
        or platform.machine() != "x86_64"
        or os.getenv("LD_PRELOAD")
        or os.getenv("LD_AUDIT")
    ):
        refuse()
    repo = args.repo
    if not repo.is_absolute() or repo.is_symlink() or not repo.is_dir():
        refuse()
    pins_path = Path(__file__).with_name("PINS.json").absolute()
    pins_raw = regular_bytes(pins_path)
    pins = json.loads(pins_raw)
    cfg = capture_pins(pins)
    owner_path = repo / "tools/build/stage-linux-network-runtime.py"
    owner_raw = regular_bytes(owner_path, pins["command_owner_sha256"])
    inputs = [
        (pins_path, pins_raw),
        (owner_path, owner_raw),
        (repo / "tools/lib/git_bash.py", regular_bytes(repo / "tools/lib/git_bash.py")),
        (repo / "tools/__init__.py", regular_bytes(repo / "tools/__init__.py")),
        (Path(__file__).absolute(), regular_bytes(Path(__file__).absolute())),
    ]
    spec = importlib.util.spec_from_file_location("validation_keyring_native_owner", owner_path)
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    for path, raw in inputs:
        if regular_bytes(path) != raw:
            refuse()
    owner._STAGE_DEADLINE = time.monotonic() + 300
    if owner.direct_children():
        refuse()
    root = args.destination
    if not root.is_absolute():
        refuse()
    root.mkdir(mode=0o700)  # existing files, dirs and broken symlinks all refuse
    fact = root.lstat()
    if (
        not stat.S_ISDIR(fact.st_mode)
        or fact.st_uid != os.geteuid()
        or stat.S_IMODE(fact.st_mode) != 0o700
    ):
        refuse()
    root_identity = (fact.st_dev, fact.st_ino)
    tools = {}
    for name in ("curl", "dpkg-deb"):
        selected = shutil.which(name)
        if selected is None:
            refuse()
        path = Path(selected).resolve(strict=True)
        raw = regular_bytes(path)
        if raw[:4] != b"\x7fELF":
            refuse()
        os.access(path, os.X_OK) or refuse()
        tools[name] = (path, raw)

    def current():
        if time.monotonic() >= owner._STAGE_DEADLINE or owner.direct_children():
            refuse()
        now = root.lstat()
        if (
            not stat.S_ISDIR(now.st_mode)
            or now.st_uid != os.geteuid()
            or stat.S_IMODE(now.st_mode) != 0o700
            or (now.st_dev, now.st_ino) != root_identity
        ):
            refuse()
        for path, raw in inputs + list(tools.values()):
            if regular_bytes(path) != raw:
                refuse()

    def run(argv, seconds):
        current()
        result = owner.run([str(x) for x in argv], env=dict(os.environ), budget_seconds=seconds)
        current()
        return result

    package = cfg["package"]
    aggregate = cfg["aggregate"]
    archive = root / "keyring.deb"
    extracted = root / "package"
    trusted = root / "trusted.gpg"
    with owner.owned_root(root):
        run(
            [
                tools["curl"][0],
                "--disable",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--tlsv1.2",
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--retry",
                "0",
                "--connect-timeout",
                "20",
                "--max-time",
                "180",
                "--output",
                archive,
                package["url"],
            ],
            190,
        )
        regular_bytes(archive, package["sha256"], package["size"])
        actual = run(
            [
                tools["dpkg-deb"][0],
                "--show",
                "--showformat=${Package}\n${Version}\n${Architecture}\n",
                archive,
            ],
            20,
        )
        receive_package_fields(actual, package)
        extracted.mkdir(mode=0o700)
        run([tools["dpkg-deb"][0], "--extract", archive, extracted], 30)
        original = extracted / aggregate["path"]
        regular_bytes(original, aggregate["sha256"], aggregate["size"])
        owner.copy_unique(original, trusted, {})
        regular_bytes(original, aggregate["sha256"], aggregate["size"])
        regular_bytes(trusted, aggregate["sha256"], aggregate["size"])
        current()
    # Original root capability close must ACK before any preparation receipt.
    current()
    receipt = {
        "schema_version": 1,
        "state": "private_validation_keyring_prepared",
        "qualification_sha256": cfg["qualification_sha256"],
        "package_sha256": package["sha256"],
        "aggregate_sha256": aggregate["sha256"],
        "aggregate_size": aggregate["size"],
        "keyring_path": str(trusted),
        "physical_closed": True,
        "scope": "tool_preparation_only_original_setup_signature_verification_required",
    }
    with (root / "KEYRING-ADMISSION.json").open("x", encoding="utf-8") as output:
        output.write(json.dumps(receipt, separators=(",", ":")) + "\n")
    current()
    regular_bytes(trusted, aggregate["sha256"], aggregate["size"])
    current()
    print("PASS private validation keyring prepared; original setup signatures remain mandatory.")


if __name__ == "__main__":
    try:
        main()
    except BaseException as error:
        if type(error) is SystemExit and type(error.code) is int and error.code == 0:
            raise
        try:
            sys.stderr.write("Private validation keyring preparation refused; inputs retained.\n")
        except BaseException:
            pass
        raise
