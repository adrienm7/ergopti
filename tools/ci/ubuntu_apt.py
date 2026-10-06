#!/usr/bin/env python3
# tools/ci/ubuntu_apt.py
"""Acquire CI dependencies from the runner's signed Ubuntu archives only."""

import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


SOURCE = Path("/etc/apt/sources.list.d/ubuntu.sources")
KEYRING_NAME = "/usr/share/keyrings/ubuntu-archive-keyring.gpg"
KEYRING = Path(KEYRING_NAME)


def admitted_source(raw):
    """Refuse foreign archives, unsigned stanzas and weakened trust directives."""
    if not raw or len(raw) > 65536:
        raise ValueError("Ubuntu archive source size refused")
    text = raw.decode("utf-8", errors="strict")
    records, current = [], {}
    for line in text.splitlines() + [""]:
        if line.startswith("#"):
            continue
        if not line.strip():
            if current:
                records.append(current)
                current = {}
            continue
        if line[0].isspace() or ":" not in line:
            raise ValueError("Ubuntu archive source record refused")
        key, value = line.split(":", 1)
        if key in current or key not in {
            "Types",
            "URIs",
            "Suites",
            "Components",
            "Signed-By",
            "Architectures",
            "Enabled",
        }:
            raise ValueError("Ubuntu archive source field refused")
        current[key] = value.strip()
    if not records:
        raise ValueError("Ubuntu archive source is empty")
    for record in records:
        if (
            record.get("Types") != "deb"
            or record.get("Signed-By") != KEYRING_NAME
            or record.get("Enabled", "yes") != "yes"
            or not record.get("Suites")
            or not record.get("Components")
            or not record.get("URIs")
        ):
            raise ValueError("Ubuntu archive signature policy refused")
        for uri in record["URIs"].split():
            address = urlsplit(uri)
            host = address.hostname or ""
            if (
                address.scheme not in ("http", "https")
                or address.username is not None
                or address.password is not None
                or address.port is not None
                or address.query
                or address.fragment
                or address.path.rstrip("/") != "/ubuntu"
                or not (
                    host == "archive.ubuntu.com"
                    or host.endswith(".archive.ubuntu.com")
                    or host == "security.ubuntu.com"
                )
            ):
                raise ValueError("Foreign Ubuntu archive authority refused")
    return raw


def package_arguments(arguments):
    """Keep package selection while prohibiting an override of archive policy."""
    packages = 0
    for argument in arguments:
        if not argument or "\x00" in argument:
            raise ValueError("APT package argument refused")
        if argument.startswith("-"):
            if argument not in ("-y", "--no-install-recommends"):
                raise ValueError("APT policy override refused")
        else:
            packages += 1
    if not packages:
        raise ValueError("APT package selection is empty")
    return list(arguments)


def command_prefix(directory):
    """Use the same isolated indexes and signature policy for both operations."""
    options = {
        "Dir::Etc::SourceList": str(directory / "ubuntu.sources"),
        "Dir::Etc::SourceParts": "-",
        "Dir::State::lists": str(directory / "lists"),
        "Dir::Cache": str(directory / "cache"),
        "APT::Update::Error-Mode": "any",
        "APT::Get::AllowUnauthenticated": "false",
        "Acquire::AllowInsecureRepositories": "false",
        "Acquire::AllowDowngradeToInsecureRepositories": "false",
    }
    return ["/usr/bin/apt-get"] + [
        value for key, item in options.items() for value in ("-o", key + "=" + item)
    ]


def acquire(raw, arguments, execute=subprocess.run):
    """Wait for each actual APT operation before disposing its private indexes."""
    raw = admitted_source(raw)
    arguments = package_arguments(arguments)
    with tempfile.TemporaryDirectory(prefix="ergopti-ubuntu-apt-") as temporary:
        directory = Path(temporary)
        # APT's unprivileged fetch worker needs traversal, while this fresh
        # root-owned directory remains unwritable by other users.
        directory.chmod(0o755)
        for name in ("lists", "cache"):
            (directory / name).mkdir(mode=0o755)
        (directory / "ubuntu.sources").write_bytes(raw)
        prefix = command_prefix(directory)
        execute(prefix + ["update"], check=True)
        execute(prefix + ["install", *arguments], check=True)


def main(arguments):
    """Require the actual hosted Ubuntu source and archive trust anchor."""
    if sys.platform != "linux" or os.geteuid() != 0:
        raise RuntimeError("Ubuntu CI acquisition requires its privileged Linux owner")
    for path in (SOURCE, KEYRING):
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
            raise RuntimeError("Ubuntu archive authority ownership refused")
    acquire(SOURCE.read_bytes(), arguments)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except subprocess.CalledProcessError as failure:
        sys.exit(failure.returncode or 1)
