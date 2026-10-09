"""Export fixed genuine upstream inputs without generating behavioral expectations.

The historical 1,019-file VHD fixture is conserved. Only the independently
specified 21-source supplement is reproduced from its genuine pinned Git tree.
This source-input exporter is outside the product generation traversal, as is
its unchanged historical input owner; it is not a product drift generator.
"""

import argparse
import hashlib
import os
from pathlib import Path
import sys

import remap_runtime_inventory_fixture as inventory

ORIGINAL_GENERATOR_SHA256 = "25a7ee679572a620d3ef4fd5a736386120499d8b8fd80c328c290705d0dd5f71"


def generate(source_root, output_root, *, check=False):
    fixture = inventory.bootstrap_fixture()
    source_root, output_root = fixture.owner(source_root), fixture.owner(output_root)
    source_before = fixture.stamp(source_root.lstat())[:4]
    output_before = fixture.stamp(output_root.lstat())[:4]
    census = inventory.manifest(fixture)
    sys.modules["remap_runtime_vhd_fixture"] = fixture
    original_generator = inventory.fixed_test(
        fixture,
        "inventory_original_source_verifier",
        inventory.BUILD / "generate_remap_runtime_vhd_fixture.py",
        ORIGINAL_GENERATOR_SHA256,
    )
    original_generator.verify_checkout(source_root, inventory.UPSTREAM)
    entries = []
    for row in census["files"]:
        name = row["path"]
        fixture.require(fixture.canonical_name(name), "inventory_input_name")
        data = fixture.read_owned(source_root / name, row["bytes"], "inventory_input_bytes")
        fixture.require(
            len(data) == row["bytes"]
            and hashlib.sha256(data).hexdigest() == row["sha256"]
            and hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\x00" + data).hexdigest()
            == row["git_blob_oid"],
            "inventory_input_bytes",
        )
        entries.append((name, data.decode("utf-8")))
    resource = inventory.resource_bytes(entries)
    fixture.require(
        len(entries) == 21
        and len(resource) == inventory.RESOURCE_BYTES
        and hashlib.sha256(resource).hexdigest() == inventory.RESOURCE_SHA256,
        "inventory_resource",
    )
    retained = fixture.read_owned(inventory.MANIFEST, 20000, "inventory_manifest")
    fixture.require(
        hashlib.sha256(retained).hexdigest() == inventory.MANIFEST_SHA256, "inventory_manifest"
    )
    original_generator.verify_checkout(source_root, inventory.UPSTREAM)
    fixture.require(
        fixture.stamp(source_root.lstat())[:4] == source_before, "inventory_current_root"
    )
    outputs = ((inventory.RESOURCE.name, resource), (inventory.MANIFEST.name, retained))
    fixture.require(
        len({name for name, _ in outputs}) == 2
        and all(Path(name).name == name for name, _ in outputs),
        "inventory_output_name",
    )
    if check:
        fixture.require(
            {path.name for path in output_root.iterdir()} == {name for name, _ in outputs},
            "inventory_output_count",
        )
    else:
        fixture.require(not any(output_root.iterdir()), "inventory_output_absence")
    for name, data in outputs:
        target = output_root / name
        if check:
            fixture.require(
                fixture.read_owned(target, len(data), "inventory_output") == data,
                "inventory_output",
            )
        else:
            descriptor = os.open(
                target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644
            )
            with os.fdopen(descriptor, "wb") as stream:
                fixture.require(stream.write(data) == len(data), "inventory_output")
    fixture.require(
        fixture.stamp(output_root.lstat())[:4] == output_before
        and {path.name for path in output_root.iterdir()} == {name for name, _ in outputs},
        "inventory_output_count",
    )
    return 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    try:
        count = generate(options.source_root, options.output_root, check=options.check)
    except (RuntimeError, OSError, ValueError) as error:
        print("Refused owned inventory source export: " + str(error), file=sys.stderr)
        return 1
    print(f"PASS genuine inventory input supplement files=21 outputs={count}; native=unexecuted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
