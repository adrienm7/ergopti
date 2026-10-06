#!/usr/bin/env python3
"""Prepare two real validation-only curl ELFs; never alter product curl.

Source proposal only. Invoke in a dedicated Linux CI setup process with no
other direct children. The canonical build owner supplies WNOWAIT/session and
subreaper retirement. Retain the private destination on every refusal/debt.
"""

import argparse
import datetime
import email.utils
import hashlib
import importlib.util
import json
import lzma
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import tarfile
import time


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def checked(path, expected, size=None):
    fact = path.lstat()
    if not stat.S_ISREG(fact.st_mode) or (size is not None and fact.st_size != size):
        raise RuntimeError("Artifact admission refused.")
    if digest(path) != expected:
        raise RuntimeError("Artifact checksum refused.")


def records(text):
    result = []
    for paragraph in text.strip().split("\n\n"):
        fields = {}
        for line in paragraph.splitlines():
            if line.startswith((" ", "\t")):
                continue
            key, separator, value = line.partition(":")
            value = value.lstrip(" ")
            if not separator or key in fields:
                raise RuntimeError("Signed package schema refused.")
            fields[key] = value
        result.append(fields)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--openssl-prefix", required=True, type=Path)
    parser.add_argument("--keyring", required=True, type=Path)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError("Linux x86_64 validation tools required.")
    if not 1 <= args.jobs <= 4:
        raise RuntimeError("Build concurrency refused.")
    pins = json.loads(Path(__file__).with_name("PINS.json").read_text())
    owner_path = args.repo.resolve(strict=True) / "tools/build/stage-linux-network-runtime.py"
    checked(owner_path, pins["command_owner_sha256"])
    spec = importlib.util.spec_from_file_location("validation_curl_native_owner", owner_path)
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    owner._STAGE_DEADLINE = time.monotonic() + 1800
    if owner.direct_children():
        raise RuntimeError("Exclusive setup ownership required.")
    # Destination is newly allocated, private, canonical, and belongs to this
    # trusted same-UID setup process. Existing caches are never adopted here.
    parent = args.destination.parent.resolve(strict=True)
    root = parent / args.destination.name
    root.mkdir(mode=0o700)
    root_fact = root.lstat()
    if root_fact.st_uid != os.geteuid() or stat.S_IMODE(root_fact.st_mode) != 0o700:
        raise RuntimeError("Private setup destination refused.")
    root_identity = (root_fact.st_dev, root_fact.st_ino)

    def current():
        if time.monotonic() >= owner._STAGE_DEADLINE:
            raise RuntimeError("Original setup deadline refused.")
        fact = root.lstat()
        if (
            not stat.S_ISDIR(fact.st_mode)
            or fact.st_uid != os.geteuid()
            or stat.S_IMODE(fact.st_mode) != 0o700
            or (fact.st_dev, fact.st_ino) != root_identity
        ):
            raise RuntimeError("Setup destination replacement refused.")

    environment = dict(os.environ)
    command_curl = shutil.which("curl")
    if command_curl is None:
        raise RuntimeError("Trusted bootstrap HTTPS client required.")

    def run(argv, budget=120, env=None):
        current()
        result = owner.run([str(x) for x in argv], env=env or environment, budget_seconds=budget)
        current()
        return result

    def fetch(url, destination, expected, size=None):
        if not url.startswith("https://"):
            raise RuntimeError("HTTPS artifact authority required.")
        if destination.exists():
            raise RuntimeError("Artifact overwrite refused.")
        run(
            [
                command_curl,
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
                destination,
                url,
            ],
            budget=190,
        )
        checked(destination, expected, size)

    modern = pins["modern"]
    source_archive = root / "modern.tar.xz"
    fetch(modern["url"], source_archive, modern["sha256"], modern["size"])
    source_dir = root / "source"
    source_dir.mkdir(mode=0o700)
    with tarfile.open(source_archive, "r:xz") as archive:
        archive.extractall(source_dir, filter="data")
    source = source_dir / ("curl-" + modern["version"])
    if not source.is_dir() or source.is_symlink():
        raise RuntimeError("Official source root refused.")
    prefix = args.openssl_prefix.resolve(strict=True)
    if not prefix.is_dir() or not (prefix / "include/openssl/ssl.h").is_file():
        raise RuntimeError("Selected local OpenSSL SDK unavailable.")
    build = root / "build"
    build.mkdir(mode=0o700)
    modern_prefix = root / "modern"
    previous_cwd = Path.cwd()
    try:
        os.chdir(build)
        run(
            [
                source / "configure",
                "--prefix=" + str(modern_prefix),
                "--with-openssl=" + str(prefix),
                "--disable-shared",
                "--enable-static",
                "--disable-docs",
                "--disable-ldap",
                "--disable-ldaps",
                "--without-libidn2",
                "--without-libpsl",
                "--without-brotli",
                "--without-zstd",
                "--without-nghttp2",
                "--without-libssh2",
                "--without-libssh",
                "--without-librtmp",
            ],
            budget=300,
        )
        run(["make", "-s", "-j" + str(args.jobs)], budget=900)
        run(["make", "-s", "install"], budget=180)
    finally:
        os.chdir(previous_cwd)

    legacy = pins["legacy"]
    inrelease = root / "InRelease"
    fetch(legacy["inrelease_url"], inrelease, legacy["inrelease_sha256"])
    keyring = args.keyring.resolve(strict=True)
    if not stat.S_ISREG(keyring.stat().st_mode):
        raise RuntimeError("Distribution trust anchor refused.")
    release = root / "Release"
    status = run(["gpgv", "--keyring", keyring, "--status-fd", "1", "--output", release, inrelease])
    valid = [
        line.split()[2] for line in status.splitlines() if line.startswith("[GNUPG:] VALIDSIG ")
    ]
    if legacy["required_signer"] not in valid:
        raise RuntimeError("Required Debian signer refused.")
    release_text = release.read_text()
    release_fields = records(release_text)[0]
    if release_fields.get("Codename") != "bookworm":
        raise RuntimeError("Distribution identity refused.")
    now = datetime.datetime.now(datetime.timezone.utc)
    release_date = email.utils.parsedate_to_datetime(release_fields["Date"])
    if release_date > now:
        raise RuntimeError("Future signed release refused.")
    if "Valid-Until" in release_fields:
        if email.utils.parsedate_to_datetime(release_fields["Valid-Until"]) <= now:
            raise RuntimeError("Expired signed release refused.")
    metadata = legacy["metadata"]
    exact_row = [metadata["sha256"], str(metadata["size"]), metadata["path"]]
    # Test the SHA256 section itself, not an unbound occurrence elsewhere.
    lines = release_text.splitlines()
    sha_start = lines.index("SHA256:") + 1
    sha_rows = []
    for line in lines[sha_start:]:
        if not line.startswith(" "):
            break
        sha_rows.append(line.split())
    if exact_row not in sha_rows:
        raise RuntimeError("Signed package index commitment refused.")
    package_index = root / "Packages.xz"
    fetch(
        "https://deb.debian.org/debian/dists/bookworm/" + metadata["path"],
        package_index,
        metadata["sha256"],
        metadata["size"],
    )
    index = records(lzma.decompress(package_index.read_bytes()).decode("utf-8"))
    legacy_root = root / "legacy-root"
    legacy_root.mkdir(mode=0o700)
    for package in legacy["packages"]:
        filename = package["url"].removeprefix("https://deb.debian.org/debian/")
        matches = [
            item
            for item in index
            if item.get("Package") == package["package"]
            and item.get("Version") == package["version"]
            and item.get("Architecture") == "amd64"
        ]
        if len(matches) != 1 or any(
            matches[0].get(key) != value
            for key, value in {
                "Filename": filename,
                "SHA256": package["sha256"],
                "Size": str(package["size"]),
            }.items()
        ):
            raise RuntimeError("Signed exact package identity refused.")
        deb = root / Path(filename).name
        fetch(package["url"], deb, package["sha256"], package["size"])
        run(["dpkg-deb", "--extract", deb, legacy_root])
    legacy_curl = legacy_root / "usr/bin/curl"
    checked(legacy_curl, legacy["curl_file_sha256"])
    legacy_libraries = root / "legacy-libraries"
    legacy_libraries.mkdir(mode=0o700)
    for library in legacy["libraries"]:
        selected = legacy_root / "usr/lib/x86_64-linux-gnu" / library["source_basename"]
        checked(selected, library["file_sha256"])
        destination = legacy_libraries / library["soname"]
        with selected.open("rb") as source_stream, destination.open("xb") as target:
            shutil.copyfileobj(source_stream, target)
        checked(destination, library["file_sha256"])
    # Keep the host libc/loader. Only this legacy probe receives the three
    # selected older SONAMEs; inherited native dependencies remain a suffix.
    old_env = dict(environment)
    suffix = old_env.get("LD_LIBRARY_PATH")
    old_env["LD_LIBRARY_PATH"] = str(legacy_libraries) + (":" + suffix if suffix else "")
    admissions = {}
    for name, executable, version, env in [
        ("modern", modern_prefix / "bin/curl", modern["version"], environment),
        ("legacy", legacy_curl, legacy["version"], old_env),
    ]:
        header = executable.read_bytes()[:20]
        if header[:5] != b"\x7fELF\x02" or header[5] != 1 or header[18:20] != b"\x3e\x00":
            raise RuntimeError("Actual x86_64 ELF required.")
        elf = run(["readelf", "--program-headers", executable], env=env)
        match = re.search(r"Requesting program interpreter: (/[^\]\n]+)\]", elf)
        if match is None:
            raise RuntimeError("Actual ELF loader unavailable.")
        loader = Path(match.group(1)).resolve(strict=True)
        closure = run([loader, "--list", executable], env=env)
        if "not found" in closure:
            raise RuntimeError("Actual loader closure refused.")
        text = run([executable, "--disable", "--version"], env=env)
        first = text.splitlines()[0]
        if (
            not first.startswith("curl " + version + " ")
            or "libcurl/" + version not in first.split()
        ):
            raise RuntimeError("Actual curl/libcurl version refused.")
        if "OpenSSL/" not in first:
            raise RuntimeError("Verified TLS backend required.")
        protocols = next(
            (line.split()[1:] for line in text.splitlines() if line.startswith("Protocols: ")), []
        )
        if not {"http", "https"}.issubset(protocols):
            raise RuntimeError("Actual HTTP/HTTPS protocols required.")
        admissions[name] = {
            "path": str(executable),
            "sha256": digest(executable),
            "actual_version": first,
            "actual_loader_closure": closure,
        }
    current()
    receipt = {
        "schema_version": 1,
        "state": "tools_admitted",
        "native_30_qualification": "UNEXECUTED",
        "pins_sha256": digest(Path(__file__).with_name("PINS.json")),
        "openssl_sdk_prefix": str(prefix),
        "tools": admissions,
        "legacy_library_path": str(legacy_libraries),
        "inherited_library_suffix_preserved": True,
    }
    receipt_path = root / "TOOLS-ADMISSION.json"
    descriptor = os.open(receipt_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(receipt, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    current()
    print("Validation-only curl tools admitted; native request suite remains unexecuted.")


if __name__ == "__main__":
    main()
