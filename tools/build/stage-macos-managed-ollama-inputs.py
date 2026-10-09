#!/usr/bin/env python3
"""Stage both genuine native producer inputs through the canonical catalogue owner."""

from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import stat


def catalogue_owner():
    specification = importlib.util.spec_from_file_location(
        "ergopti_managed_catalogue_owner",
        Path(__file__).with_name("stage-macos-managed-ollama-catalogue.py"),
    )
    owner = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(owner)
    return owner


OWNER = catalogue_owner()


def physical_inputs(root: Path, contract):
    """Refuse foreign files, links and aliases before admitting either host."""
    root = root.absolute()
    current = Path(root.anchor)
    for part in root.parts[1:]:
        current /= part
        if not stat.S_ISDIR(current.lstat().st_mode):
            raise ValueError("Native producer inputs require physical directories")
    names = []
    for host in ("macos-arm64", "macos-amd64"):
        name = contract["assets"][host]["filename"]
        names.extend((name, name + ".provenance.json"))
    if set(path.name for path in root.iterdir()) != set(names):
        raise ValueError("Both exact native producer archives and receipts are required")
    identities = set()
    for name in names:
        fact = (root / name).lstat()
        identity = (fact.st_dev, fact.st_ino)
        if (
            not stat.S_ISREG(fact.st_mode)
            or fact.st_nlink != 1
            or fact.st_size <= 0
            or identity in identities
        ):
            raise ValueError("Native producer input links or aliases were refused")
        identities.add(identity)
    return [(root / name, root / (name + ".provenance.json")) for name in names[::2]]


def stage(options):
    """Delegate all provenance, native archive and publication policy to its owner."""
    if not options.go.is_absolute():
        raise ValueError("The pinned Go executable must have an absolute path")
    repository = OWNER.physical_directory(options.repository)
    contract, _ = OWNER.read_contract(repository, OWNER.Inputs())
    inputs = physical_inputs(options.inputs, contract)
    guard = OWNER.Inputs()
    for archive, receipt in inputs:
        guard.admit(archive)
        guard.admit(receipt)
    options.archive = [archive for archive, _ in inputs]
    options.producer_receipt = [receipt for _, receipt in inputs]
    output = OWNER.stage(options)
    guard.current()
    physical_inputs(options.inputs, contract)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--official-archive", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--go", type=Path, required=True)
    parser.add_argument("--node", default="node")
    parser.add_argument("--release", choices=["true", "false"], required=True)
    parser.add_argument("--release-tag", default="")
    parser.add_argument("--release-version", default="")
    parser.add_argument("--release-channel", required=True)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    options.release = options.release == "true"
    print(stage(options))


if __name__ == "__main__":
    main()
