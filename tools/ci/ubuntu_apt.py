#!/usr/bin/env python3
# tools/ci/ubuntu_apt.py
"""Acquire CI dependencies from the runner's signed Ubuntu archives only."""

import hashlib
import json
import os
import re
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


SOURCE = Path("/etc/apt/sources.list.d/ubuntu.sources")
KEYRING_NAME = "/usr/share/keyrings/ubuntu-archive-keyring.gpg"
KEYRING = Path(KEYRING_NAME)
MIRRORS = Path("/etc/apt/apt-mirrors.txt")
MIRROR_URI = "mirror+file:/etc/apt/apt-mirrors.txt"
PINNED_KEYRING = Path(__file__).with_name("ubuntu-archive-keyring.gpg")
PIN_POLICY = Path(__file__).with_name("ubuntu-keyring.json")
ORIGIN_MAX_BYTES = 65536


def authority_refused(role, metadata):
    """Keep exact bounded role/type/UID/mode facts, never a source body or path."""
    if (
        role
        not in {
            "source",
            "mirrors",
            "private-keyring",
            "private-mirrors",
            "private-source",
            "private-namespace",
        }
        or type(metadata.st_mode) is not int
        or type(metadata.st_uid) is not int
        or not 0 <= metadata.st_uid <= 4294967295
    ):
        raise RuntimeError("Ubuntu archive authority metadata unavailable")
    kind = (
        "regular"
        if stat.S_ISREG(metadata.st_mode)
        else "directory"
        if stat.S_ISDIR(metadata.st_mode)
        else "symlink"
        if stat.S_ISLNK(metadata.st_mode)
        else "other"
    )
    facts = {
        "role": role,
        "kind": kind,
        "uid": metadata.st_uid,
        "mode": format(stat.S_IMODE(metadata.st_mode), "04o"),
    }
    raise RuntimeError(
        "Ubuntu archive authority ownership refused: " + json.dumps(facts, sort_keys=True)
    )


def require_owned(metadata, role, directory=False):
    """Only actual root-owned nonwritable source/private authorities are admitted."""
    valid = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if not valid or metadata.st_uid != 0 or metadata.st_mode & 0o022:
        authority_refused(role, metadata)


def origin_identity(metadata):
    """Compare native descriptor identity and mutation facts without path reopening."""
    values = tuple(
        getattr(metadata, name)
        for name in (
            "st_dev",
            "st_ino",
            "st_size",
            "st_mode",
            "st_uid",
            "st_mtime_ns",
            "st_ctime_ns",
        )
    )
    if any(type(value) is not int for value in values):
        raise RuntimeError("Ubuntu archive origin descriptor metadata unavailable")
    return values


def read_owned_origin(path, role):
    """Capture one bounded owned regular origin through one no-follow descriptor."""
    if role not in ("source", "mirrors"):
        raise ValueError("Ubuntu archive origin role refused")
    # Nonblocking open prevents an unexpected FIFO from hanging before fstat;
    # only the admitted regular descriptor can reach the read loop.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    primary = None
    try:
        before = os.fstat(descriptor)
        require_owned(before, role)
        identity = origin_identity(before)
        if not 0 < before.st_size <= ORIGIN_MAX_BYTES:
            raise ValueError("Ubuntu archive origin size refused: " + role)
        chunks, length = [], 0
        while length <= ORIGIN_MAX_BYTES:
            requested = ORIGIN_MAX_BYTES + 1 - length
            block = os.read(descriptor, requested)
            if type(block) is not bytes or len(block) > requested:
                raise RuntimeError("Ubuntu archive origin read shape refused: " + role)
            if not block:
                break
            chunks.append(block)
            length += len(block)
            if length > ORIGIN_MAX_BYTES:
                raise ValueError("Ubuntu archive origin size refused: " + role)
        after = os.fstat(descriptor)
        require_owned(after, role)
        if identity != origin_identity(after) or length != before.st_size:
            raise RuntimeError("Ubuntu archive origin changed during capture: " + role)
        return b"".join(chunks)
    except BaseException as error:
        primary = error
        raise
    finally:
        try:
            os.close(descriptor)
        except BaseException as close_error:
            if primary is None or (
                isinstance(close_error, (KeyboardInterrupt, SystemExit))
                and not isinstance(primary, (KeyboardInterrupt, SystemExit))
            ):
                raise
            # Preserve the first primary (especially cancellation). Never retry
            # close: its native outcome may already have consumed this descriptor.
            primary.add_note("Ubuntu archive origin descriptor close refused: " + role)


def keyring_policy():
    """One package-derived public-key pin; the mutable image is never an anchor."""
    data = json.loads(PIN_POLICY.read_text(encoding="utf-8"))
    if (
        type(data) is not dict
        or set(data) != {"schema", "package", "keyring"}
        or type(data["schema"]) is not int
        or data["schema"] != 1
        or type(data["keyring"]) is not dict
        or set(data["keyring"]) != {"file", "bytes", "sha256"}
        or data["keyring"]["file"] != PINNED_KEYRING.name
        or type(data["keyring"]["bytes"]) is not int
        or not 0 < data["keyring"]["bytes"] <= 65536
        or type(data["keyring"]["sha256"]) is not str
        or re.fullmatch("[0-9a-f]{64}", data["keyring"]["sha256"]) is None
    ):
        raise ValueError("Pinned Ubuntu keyring policy refused")
    return data["keyring"]


def authentic_keyring(raw):
    """Byte authenticity is independent of the image keyring's permission bits."""
    pin = keyring_policy()
    if (
        type(raw) is not bytes
        or len(raw) != pin["bytes"]
        or hashlib.sha256(raw).hexdigest() != pin["sha256"]
    ):
        raise ValueError("Pinned Ubuntu keyring bytes refused")
    return raw


def read_pinned_keyring():
    """Read only the bounded regular public asset; reauthenticate the RAM bytes."""
    pin = keyring_policy()
    descriptor = os.open(PINNED_KEYRING, os.O_RDONLY | os.O_NOFOLLOW)
    primary = None
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != pin["bytes"]:
            raise ValueError("Pinned Ubuntu keyring image shape refused")
        raw = os.read(descriptor, pin["bytes"] + 1)
        return authentic_keyring(raw)
    except BaseException as error:
        primary = error
        raise
    finally:
        try:
            os.close(descriptor)
        except OSError:
            if primary is None:
                raise


def admitted_uri(uri):
    """No unlisted host, local archive, credentials, port or hidden URI component."""
    address = urlsplit(uri)
    host = address.hostname or ""
    return (
        address.scheme in ("http", "https")
        and address.username is None
        and address.password is None
        and address.port is None
        and not address.query
        and not address.fragment
        and address.path.rstrip("/") == "/ubuntu"
        and (
            host == "archive.ubuntu.com"
            or host.endswith(".archive.ubuntu.com")
            or host == "security.ubuntu.com"
        )
    )


def admitted_mirrors(raw):
    """Preserve the runner's exact signed-Ubuntu mirror order and priority bytes."""
    if type(raw) is not bytes or not 0 < len(raw) <= ORIGIN_MAX_BYTES:
        raise ValueError("Ubuntu mirror source size refused")
    count = 0
    for line in raw.decode("utf-8", errors="strict").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split()
        if (
            not 1 <= len(parts) <= 2
            or not admitted_uri(parts[0])
            or (len(parts) == 2 and re.fullmatch(r"priority:[1-9][0-9]*", parts[1]) is None)
        ):
            raise ValueError("Foreign Ubuntu mirror authority refused")
        count += 1
    if count == 0:
        raise ValueError("Ubuntu mirror source is empty")
    return raw


def source_records(raw):
    """Parse the one canonical stanza grammar before selecting active origins."""
    if type(raw) is not bytes or not raw or len(raw) > ORIGIN_MAX_BYTES:
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
            if uri != MIRROR_URI and not admitted_uri(uri):
                raise ValueError("Foreign Ubuntu archive authority refused")
    return records


def source_uses_mirrors(raw):
    """Only a URI in an admitted active stanza selects the mirror-list origin."""
    return any(MIRROR_URI in record["URIs"].split() for record in source_records(raw))


def admitted_source(raw, mirrors=None):
    """Refuse foreign archives, unsigned stanzas and weakened trust directives."""
    if source_uses_mirrors(raw):
        admitted_mirrors(mirrors)
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


def private_sources(raw, directory):
    """Relocate only the admitted key/mirror references; preserve all other bytes."""
    text = raw.decode("utf-8", errors="strict")
    lines = []
    for line in text.splitlines(keepends=True):
        if line.startswith("Signed-By:"):
            before = line.split(":", 1)[1].strip()
            if before != KEYRING_NAME:
                raise ValueError("Ubuntu private signer relocation refused")
            line = line.replace(before, str(directory / "ubuntu-archive-keyring.gpg"), 1)
        elif line.startswith("URIs:"):
            line = line.replace(MIRROR_URI, "mirror+file:" + str(directory / "apt-mirrors.txt"))
        lines.append(line)
    return "".join(lines).encode("utf-8")


def write_private(path, raw, role):
    """Publish a closed exclusive read-only file before the first APT dispatch."""
    with path.open("xb") as stream:
        if stream.write(raw) != len(raw):
            raise OSError("Incomplete Ubuntu private authority write")
        stream.flush()
        os.fsync(stream.fileno())
    path.chmod(0o444)
    require_owned(path.lstat(), role)
    if path.read_bytes() != raw:
        raise ValueError("Ubuntu private authority bytes changed")


def acquire(raw, arguments, execute=subprocess.run, *, keyring=None, mirrors=None):
    """Wait for each actual APT operation before disposing its private authorities."""
    raw = admitted_source(raw, mirrors)
    arguments = package_arguments(arguments)
    keyring = authentic_keyring(read_pinned_keyring() if keyring is None else keyring)
    temporary = tempfile.TemporaryDirectory(prefix="ergopti-ubuntu-apt-")
    primary = None
    try:
        directory = Path(temporary.name)
        for name in ("lists", "cache"):
            (directory / name).mkdir(mode=0o755)
        write_private(directory / "ubuntu-archive-keyring.gpg", keyring, "private-keyring")
        if source_uses_mirrors(raw):
            write_private(
                directory / "apt-mirrors.txt", admitted_mirrors(mirrors), "private-mirrors"
            )
        write_private(
            directory / "ubuntu.sources", private_sources(raw, directory), "private-source"
        )
        # Read/traverse is enough for _apt; only private lists/cache are mutable.
        directory.chmod(0o555)
        require_owned(directory.lstat(), "private-namespace", directory=True)
        prefix = command_prefix(directory)
        execute(prefix + ["update"], check=True)
        execute(prefix + ["install", *arguments], check=True)
    except BaseException as error:
        primary = error
        raise
    finally:
        try:
            temporary.cleanup()
        except OSError:
            if primary is None:
                raise
            # Preserve the actual status and a typed refusal even when optional
            # stderr reporting is unavailable. New cancellation still propagates.
            primary.add_note("Ubuntu private authority cleanup refused")
            try:
                print("Ubuntu private authority cleanup refused", file=sys.stderr)
            except (KeyboardInterrupt, SystemExit):
                raise
            except Exception:
                primary.add_note("Ubuntu private authority cleanup reporting unavailable")


def main(arguments):
    """Require owned origins; supply the independently authenticated private anchor."""
    if sys.platform != "linux" or os.geteuid() != 0:
        raise RuntimeError("Ubuntu CI acquisition requires its privileged Linux owner")
    raw = read_owned_origin(SOURCE, "source")
    mirrors = None
    if source_uses_mirrors(raw):
        mirrors = read_owned_origin(MIRRORS, "mirrors")
    keyring = read_pinned_keyring()
    acquire(raw, arguments, keyring=keyring, mirrors=mirrors)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except subprocess.CalledProcessError as failure:
        sys.exit(failure.returncode or 1)
