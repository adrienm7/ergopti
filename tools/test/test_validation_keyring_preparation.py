#!/usr/bin/env python3
# tools/test/test_validation_keyring_preparation.py
"""Independent pure receiving and actual-file controls; no child/native proof."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile

SOURCE = Path(__file__).parent / "fixtures/validation-curl/prepare_validation_keyring.py"
spec = importlib.util.spec_from_file_location("validation_keyring_controls", SOURCE)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

# Literal signed-package/aggregate observations from the independent Root proof.
CFG = {
    "authority": "official_debian_signed_distribution_package",
    "qualification_sha256": "58acaaa4dde2d3a7e806dec460db5c836e3f94e1c96533d742b15d1b0cf30e3f",
    "inrelease_sha256": "77737fa4b34f2693e982cc9ee35736816c35a7778fc2d326cc1bbf5b301fe1aa",
    "required_signer": "4D64FEC119C2029067D6E791F8D2585B8783D481",
    "index": {
        "path": "main/binary-amd64/Packages.xz",
        "size": 8790396,
        "sha256": "9e0b5aabb2465b3d2e7a7fe27f9913846277833f7a2826e7767acccff5b588c5",
    },
    "package": {
        "name": "debian-archive-keyring",
        "version": "2023.3+deb12u2",
        "architecture": "all",
        "publisher": "Debian Release Team <packages@release.debian.org>",
        "filename": "pool/main/d/debian-archive-keyring/debian-archive-keyring_2023.3+deb12u2_all.deb",
        "url": "https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/debian-archive-keyring_2023.3+deb12u2_all.deb",
        "sha256": "f699e2f88dca05212f2a452b58475f2993cb6993dfbafb1d0205a3291eb8b4b8",
        "size": 178572,
    },
    "aggregate": {
        "path": "usr/share/keyrings/debian-archive-keyring.gpg",
        "sha256": "506b815cbb32d9b6066b4a2aa524071e071761e7e7f68c3ac74f3061ba852017",
        "size": 55918,
    },
}
PINS = {
    "validation_keyring": CFG,
    "legacy": {
        "inrelease_sha256": CFG["inrelease_sha256"],
        "required_signer": CFG["required_signer"],
        "metadata": copy.deepcopy(CFG["index"]),
    },
}
passed = 0


def check(name, body):
    global passed
    body()
    passed += 1
    print("PASS private keyring receiving " + name)


def refused(body):
    try:
        body()
    except RuntimeError:
        return
    raise AssertionError("Expected closed admission refusal")


def literal_authority():
    captured = helper.capture_pins(copy.deepcopy(PINS))
    assert (
        captured["package"]["sha256"]
        == "f699e2f88dca05212f2a452b58475f2993cb6993dfbafb1d0205a3291eb8b4b8"
    )
    assert captured["aggregate"]["size"] == 55918


check("literal authority", literal_authority)
for name, path, replacement in (
    ("foreign authority", ("authority",), "unverified_https"),
    ("unknown field", ("raw_stderr",), "foreign"),
    ("wrong required signer", ("required_signer",), "0" * 40),
    ("wrong signed release", ("inrelease_sha256",), "0" * 64),
    ("wrong signed index", ("index", "sha256"), "0" * 64),
    ("foreign artifact URL", ("package", "url"), "https://foreign.invalid/keyring.deb"),
    ("mismatched package version", ("package", "version"), "2025.1"),
    ("Boolean package size", ("package", "size"), True),
    ("foreign aggregate path", ("aggregate", "path"), "../../host-keyring"),
    ("malformed aggregate hash", ("aggregate", "sha256"), "secret"),
):
    value = copy.deepcopy(PINS)
    cursor = value["validation_keyring"]
    for segment in path[:-1]:
        cursor = cursor[segment]
    cursor[path[-1]] = replacement
    check(name, lambda value=value: refused(lambda: helper.capture_pins(value)))


def detached():
    value = copy.deepcopy(PINS)
    captured = helper.capture_pins(value)
    value["validation_keyring"]["package"]["version"] = "foreign"
    value["validation_keyring"]["aggregate"]["sha256"] = "0" * 64
    assert captured["package"]["version"] == "2023.3+deb12u2"
    assert (
        captured["aggregate"]["sha256"]
        == "506b815cbb32d9b6066b4a2aa524071e071761e7e7f68c3ac74f3061ba852017"
    )


check("captured scalar records detached", detached)
check(
    "literal native package fields",
    lambda: helper.receive_package_fields(
        "debian-archive-keyring\n2023.3+deb12u2\nall\n", CFG["package"]
    ),
)
for name, value in (
    ("wrong package name", "foreign\n2023.3+deb12u2\nall\n"),
    ("wrong package version", "debian-archive-keyring\n2025.1\nall\n"),
    ("wrong package architecture", "debian-archive-keyring\n2023.3+deb12u2\namd64\n"),
    ("extra native metadata", "debian-archive-keyring\n2023.3+deb12u2\nall\nforeign\n"),
    ("truncated native metadata", "debian-archive-keyring\n2023.3+deb12u2\nall"),
):
    check(
        name,
        lambda value=value: refused(lambda: helper.receive_package_fields(value, CFG["package"])),
    )

with tempfile.TemporaryDirectory(prefix="ergopti-keyring-receiving-") as directory:
    root = Path(directory).absolute()
    member = root / "member"
    member.write_bytes(b"abc")
    exact = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    def actual_bytes():
        assert helper.regular_bytes(member, exact, 3) == b"abc"

    check("actual literal bytes", actual_bytes)
    check(
        "actual digest mismatch", lambda: refused(lambda: helper.regular_bytes(member, "0" * 64, 3))
    )
    alias = root / "alias"
    alias.symlink_to(member)
    check("actual alias refused", lambda: refused(lambda: helper.regular_bytes(alias, exact, 3)))

assert passed == 21, "Complete independent receiving inventory required"
print("Private validation keyring receiving: 21 checks; 0 failed; no native signature credit.")
