#!/usr/bin/env python3
"""Verify actual managed native assets and the catalogue sealed in both app archives."""

from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import stat
import tarfile
import zipfile

CATALOGUE = "managed_ollama_release.json"
BUNDLE_CATALOGUE = (
    "ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/_shared/modules/llm/" + CATALOGUE
)


def module(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    owner = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(owner)
    return owner


OWNER = module(
    "ergopti_managed_catalogue_owner",
    Path(__file__).with_name("stage-macos-managed-ollama-catalogue.py"),
)


def bound_catalogue(path, expected):
    """Compare exact catalogue bytes without extracting either sealed app archive."""
    OWNER.ordinary(path)
    if path.name.endswith(".zip"):
        with zipfile.ZipFile(path) as archive:
            records = [
                record for record in archive.infolist() if record.filename == BUNDLE_CATALOGUE
            ]
            if (
                len(records) != 1
                or records[0].file_size != len(expected)
                or not stat.S_ISREG(records[0].external_attr >> 16)
                or archive.read(records[0]) != expected
            ):
                raise ValueError("The signed ZIP catalogue differs from publication")
    else:
        with tarfile.open(path, "r|xz") as archive:
            count = 0
            for record in archive:
                if record.name.removeprefix("./") != BUNDLE_CATALOGUE:
                    continue
                count += 1
                if not record.isfile() or record.size != len(expected):
                    raise ValueError("The signed TAR catalogue is not an ordinary exact file")
                with archive.extractfile(record) as stream:
                    if stream.read(len(expected) + 1) != expected:
                        raise ValueError("The signed TAR catalogue differs from publication")
            if count != 1:
                raise ValueError("The signed TAR catalogue is missing or duplicated")


def verify(options):
    """Require both runtime downloads before the release's first publication side effect."""
    repository = OWNER.physical_directory(options.repository)
    assets = OWNER.physical_directory(options.assets)
    inputs = OWNER.Inputs()
    contract, _ = OWNER.read_contract(repository, inputs)
    catalogue_path = OWNER.source_file(assets, CATALOGUE)
    catalogue = inputs.read_json(catalogue_path)
    expected_plan = OWNER.publication(
        repository,
        inputs,
        release=True,
        tag=options.tag,
        version=options.version,
        channel=options.channel,
        node=options.node,
    )
    if (
        catalogue["publication"] != expected_plan
        or catalogue["repository_commit"]
        != OWNER.run(["git", "-C", str(repository), "rev-parse", "HEAD"])
        or set(catalogue["assets"]) != {"macos-arm64", "macos-amd64"}
        or catalogue["repository_source_sha256"]
        != {
            name: inputs.admit(OWNER.source_file(repository, name))
            for name in contract["source_fingerprint_paths"]
        }
    ):
        raise ValueError("The actual native catalogue source or release plan differs")
    policy = module(
        "ergopti_managed_runtime_policy",
        repository / "static/ergopti_plus/_shared/python/managed_ollama_runtime.py",
    )
    contract_bytes = OWNER.source_file(repository, OWNER.CONTRACT).read_bytes()
    catalogue_bytes = catalogue_path.read_bytes()
    for host in ("macos-arm64", "macos-amd64"):
        _, asset = policy.select_asset(contract_bytes, catalogue_bytes, host)
        archive = OWNER.source_file(assets, asset["filename"])
        expected_url = (
            "https://github.com/"
            + expected_plan["repository"]
            + "/releases/download/"
            + expected_plan["tag"]
            + "/"
            + asset["filename"]
        )
        if (
            asset["url"] != expected_url
            or archive.stat().st_size != asset["bytes"]
            or inputs.admit(archive) != asset["sha256"]
        ):
            raise ValueError("A native release asset or its exact download URL differs")
    for filename in ("ErgoptiPlus.app.zip", "ErgoptiPlus.app.tar.xz"):
        archive = OWNER.source_file(assets, filename)
        inputs.admit(archive)
        bound_catalogue(archive, catalogue_bytes)
    inputs.current()
    return 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--node", default="node")
    print("Verified actual managed native release assets:", verify(parser.parse_args()))


if __name__ == "__main__":
    main()
