#!/usr/bin/env python3
"""Create independent synthetic publication files, never native producer evidence."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import zipfile

SOURCE_COMMIT = "c28ddc0a7b273cd286b680a6db0bef0c17bc0ec0"
SOURCE_FILES = (
    "tools/build/build-macos-managed-ollama.py",
    "static/ergopti_plus/_shared/go/native_http/transport.go",
    "static/ergopti_plus/_shared/go/native_http/worker_darwin.go",
    "static/ergopti_plus/_shared/go/native_http/worker_other.go",
    "static/ergopti_plus/_shared/go/native_http/admission.go",
    "static/ergopti_plus/_shared/go/native_http/network_bootstrap.go",
    "static/ergopti_plus/_shared/go/native_http/network_bootstrap_posix.go",
    "static/ergopti_plus/_shared/go/native_http/network_bootstrap_unsupported.go",
    "static/ergopti_plus/_shared/go/native_http/transport_test.go",
    "static/ergopti_plus/_shared/go/native_http/admission_test.go",
    "static/ergopti_plus/_shared/go/native_http/network_bootstrap_test.go",
    "static/ergopti_plus/_shared/go/native_http/network_bootstrap_darwin_test.go",
    "static/ergopti_plus/_shared/modules/llm/managed_ollama_bootstrap.json",
    "static/ergopti_plus/_shared/modules/network/proxy_policy.json",
    "tools/diagnostics/macos_owned_process.py",
)
VERSION = "0.24.0"
CAPABILITY = "ERGOPTI_OLLAMA_NATIVE_HTTP_V1"
REPOSITORY = "adrienm7/ergopti"
CATALOGUE = "managed_ollama_release.json"
BUNDLE_CATALOGUE = (
    "ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/_shared/modules/llm/" + CATALOGUE
)
NATIVE_ASSETS = (
    ("arm64", "ollama-ergopti-native-http-darwin-arm64.tgz"),
    ("amd64", "ollama-ergopti-native-http-darwin-amd64.tgz"),
)
BINARY = b"Independent synthetic publication fixture; not a native executable.\n"
LIBRARY = b"Independent synthetic publication fixture; not a native library.\n"
LICENSE = b"Independent fixture text; not an upstream license admission.\n"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def write_tar(stream, records):
    """Write literal ordinary member bytes without extraction or production code."""
    with tarfile.open(fileobj=stream, mode="w|") as archive:
        for name, data, mode in records:
            record = tarfile.TarInfo(name)
            record.size = len(data)
            record.mode = mode
            record.mtime = 0
            archive.addfile(record, io.BytesIO(data))


def native_archive(path):
    with path.open("wb") as stream:
        with gzip.GzipFile(filename="", fileobj=stream, mode="wb", mtime=0) as compressed:
            write_tar(
                compressed,
                (
                    ("ollama", BINARY, 0o755),
                    ("lib/independent.dylib", LIBRARY, 0o644),
                    ("LICENSE.ollama", LICENSE, 0o644),
                ),
            )


def fixture(repository, assets, tag, channel):
    """Bind handwritten fixture metadata to actual private source and file bytes."""
    contract_path = (
        repository / "static/ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json"
    )
    contract_bytes = contract_path.read_bytes()
    contract = json.loads(contract_bytes)
    # These are independent reviewed declarations, not a generated oracle.
    if (
        contract["version"] != VERSION
        or contract["source_commit"] != SOURCE_COMMIT
        or contract["capability"] != CAPABILITY
        or contract["source_fingerprint_paths"] != list(SOURCE_FILES)
        or {host: value["filename"] for host, value in contract["assets"].items()}
        != {"macos-" + architecture: name for architecture, name in NATIVE_ASSETS}
    ):
        raise ValueError("The independently reviewed publication fixture declarations changed")
    defaults = json.loads(
        (repository / "static/ergopti_plus/_shared/modules/updater/defaults.json").read_bytes()
    )
    if defaults["github"]["owner"] + "/" + defaults["github"]["repo"] != REPOSITORY:
        raise ValueError("The independently reviewed publication repository changed")
    commit = subprocess.check_output(
        ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True
    ).strip()
    catalogue = {
        "schema_version": 1,
        "version": VERSION,
        "source_commit": SOURCE_COMMIT,
        "capability": CAPABILITY,
        "native_http_capability": 1,
        "runtime_contract_sha256": sha256(contract_bytes),
        "repository_commit": commit,
        "repository_source_sha256": {
            name: sha256((repository / name).read_bytes()) for name in SOURCE_FILES
        },
        "publication": {
            "mode": "planned-release",
            "tag": tag,
            "version": tag.removeprefix("v"),
            "channel": channel,
            "repository": REPOSITORY,
        },
        "assets": {},
    }
    receipts = repository / "managed-publication-fixture-receipts"
    receipts.mkdir(exist_ok=True)
    for architecture, filename in NATIVE_ASSETS:
        archive = assets / filename
        native_archive(archive)
        # This independent receipt deliberately lacks every native producer
        # authority field. It can never pass the production catalogue generator.
        receipt = (
            json.dumps(
                {
                    "fixture_role": "synthetic publication admission only",
                    "native_execution": False,
                    "architecture": architecture,
                    "archive_sha256": sha256(archive.read_bytes()),
                },
                sort_keys=True,
            )
            + "\n"
        ).encode()
        (receipts / (filename + ".fixture.json")).write_bytes(receipt)
        catalogue["assets"]["macos-" + architecture] = {
            "os": "darwin",
            "architecture": architecture,
            "filename": filename,
            "url": "https://github.com/"
            + REPOSITORY
            + "/releases/download/"
            + tag
            + "/"
            + filename,
            "sha256": sha256(archive.read_bytes()),
            "bytes": archive.stat().st_size,
            "version": VERSION,
            "source_commit": SOURCE_COMMIT,
            "capability": CAPABILITY,
            "native_http_capability": 1,
            "binary_sha256": sha256(BINARY),
            "runtime_libraries_sha256": {"lib/independent.dylib": sha256(LIBRARY)},
            "provenance_sha256": sha256(receipt),
        }
    encoded = (json.dumps(catalogue, sort_keys=True) + "\n").encode()
    (assets / CATALOGUE).write_bytes(encoded)
    with zipfile.ZipFile(assets / "ErgoptiPlus.app.zip", "w") as archive:
        record = zipfile.ZipInfo(BUNDLE_CATALOGUE)
        record.create_system = 3
        record.external_attr = 0o100644 << 16
        archive.writestr(record, encoded)
    with tarfile.open(assets / "ErgoptiPlus.app.tar.xz", "w:xz") as archive:
        record = tarfile.TarInfo(BUNDLE_CATALOGUE)
        record.mode = 0o644
        record.size = len(encoded)
        archive.addfile(record, io.BytesIO(encoded))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--channel", required=True)
    options = parser.parse_args()
    fixture(options.repository, options.assets, options.tag, options.channel)


if __name__ == "__main__":
    main()
