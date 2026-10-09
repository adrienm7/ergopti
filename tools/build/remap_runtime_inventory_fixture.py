"""Run unchanged producer/inventory controls with authentic offline source inputs.

The native platform ports remain explicitly modeled. This does not qualify
Darwin enumeration, queue cutover, installation or activation. Original fixture
bytes and both original test bodies are conserved; no network is used.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest

BUILD = Path(__file__).resolve().parent
FIXTURES = BUILD / "fixtures"
UPSTREAM = "9312593e1a3bf72b94c63c524ebabe2637442e8a"
MANIFEST = FIXTURES / "remap_runtime_inventory_inputs_manifest.json"
RESOURCE = FIXTURES / "remap_runtime_inventory_inputs.json"
MANIFEST_SHA256 = "ac6c531494aeeaa7388ee85799231a86b67c7ef447f7cdc52bcd5364ebaea67e"
RESOURCE_SHA256 = "3c3d988bd24ac6c2157bd8062c9f9149525ce71d3cf57c0f2c75f4ecd85a7e87"
RESOURCE_BYTES = 141900
FIXTURE_SHA256 = "a4d62ba7da04436f438248b998a702b89d3b8475de7a2de947270cfbfb088c02"
PRODUCER_SHA256 = "5510a12ba6616351c04d2e9d6a9af46dd0d2603a4d39a4279503941ee936dab1"
INVENTORY_SHA256 = "4f9d2076f01785b31086efdaf65470fd0e4cd203cfe55b83aed8d0cd80c2716e"
INPUT_PATHS = (
    "src/apps/ConsoleUserServer/include/console_user_server/components_manager.hpp",
    "src/apps/ConsoleUserServer/include/console_user_server/runtime.h",
    "src/apps/ConsoleUserServer/include/console_user_server/ui_bridge.h",
    "src/apps/ConsoleUserServer/project.yml",
    "src/apps/ConsoleUserServer/src/runtime.cpp",
    "src/apps/ConsoleUserServer/swift/KarabinerConsoleUserServerApp.swift",
    "src/apps/CoreService/include/core_service/agent/permission_checker.hpp",
    "src/apps/CoreService/include/core_service/daemon/device_grabber_details/entry.hpp",
    "src/apps/CoreService/include/core_service/main/agent.hpp",
    "src/apps/CoreService/include/core_service/main/daemon.hpp",
    "src/apps/CoreService/project.yml",
    "src/bin/cli/project.yml",
    "src/bin/cli/src/main.cpp",
    "src/share/constants.hpp",
    "src/share/device_properties.hpp",
    "src/share/hid_device_events_monitor.hpp",
    "src/share/iokit_utility.hpp",
    "src/share/process_lifecycle_manager.hpp",
    "src/share/types/device_id.hpp",
    "src/share/types/device_identifiers.hpp",
    "src/share/types/operation_type.hpp",
)
REPORT = "PASS owned runtime production=7 inventory=37 unknown=1; modeled platform ports only\n"


def bootstrap_fixture():
    """Hold and authenticate the unchanged source before executing its helpers."""
    path = BUILD / "remap_runtime_vhd_fixture.py"
    before = path.lstat()
    if (
        path.resolve(strict=True) != path
        or not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.getuid()
        or before.st_nlink != 1
        or before.st_size > 100000
    ):
        raise RuntimeError("inventory_fixture_owner")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        data = stream.read(100001)
        final = os.fstat(stream.fileno())
        after = path.lstat()
    fields = (
        "st_dev",
        "st_ino",
        "st_uid",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    snapshots = [
        tuple(getattr(info, field) for field in fields) for info in (before, opened, final, after)
    ]
    if (
        len(set(snapshots)) != 1
        or len(data) != opened.st_size
        or path.resolve(strict=True) != path
        or hashlib.sha256(data).hexdigest() != FIXTURE_SHA256
    ):
        raise RuntimeError("inventory_fixture_source")
    return module_from_bytes("inventory_original_offline_fixture", path, data)


def module_from_bytes(name, path, data):
    specification = importlib.util.spec_from_loader(name, loader=None)
    module = importlib.util.module_from_spec(specification)
    module.__file__ = str(path)
    sys.modules[name] = module
    exec(compile(data, str(path), "exec"), module.__dict__)
    return module


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise RuntimeError("inventory_fixture_duplicate")
        result[name] = value
    return result


def manifest(fixture):
    data = fixture.read_owned(MANIFEST, 20000, "inventory_manifest")
    fixture.require(hashlib.sha256(data).hexdigest() == MANIFEST_SHA256, "inventory_manifest")
    result = json.loads(data, object_pairs_hook=unique_object)
    fixture.require(
        result["schema"] == 1
        and result["upstream"] == UPSTREAM
        and result["supplement_files"] == 21
        and result["supplement_source_bytes"] == 135664
        and result["combined_files"] == 1040
        and result["resource_bytes"] == RESOURCE_BYTES
        and result["resource_sha256"] == RESOURCE_SHA256
        and tuple(row["path"] for row in result["files"]) == INPUT_PATHS
        and sum(row["bytes"] for row in result["files"]) == 135664,
        "inventory_manifest",
    )
    fixture.require(
        result["original_fixture"]
        == {
            "files": fixture.FILE_COUNT,
            "manifest_sha256": fixture.MANIFEST_SHA256,
            "archive_sha256": fixture.ARCHIVE_SHA256,
        },
        "inventory_original_fixture",
    )
    return result


def resource_bytes(entries):
    """Serialize only original source inputs, never behavioral expectations."""
    return (
        json.dumps({"schema": 1, "sources": dict(entries)}, ensure_ascii=False, indent="\t") + "\n"
    ).encode("utf-8")


def supplemental_entries(fixture, census):
    raw = fixture.read_owned(RESOURCE, RESOURCE_BYTES, "inventory_resource")
    fixture.require(
        len(raw) == RESOURCE_BYTES and hashlib.sha256(raw).hexdigest() == RESOURCE_SHA256,
        "inventory_resource",
    )
    result = json.loads(raw, object_pairs_hook=unique_object)
    fixture.require(
        set(result) == {"schema", "sources"}
        and result["schema"] == 1
        and type(result["sources"]) is dict
        and tuple(result["sources"]) == INPUT_PATHS,
        "inventory_inputs",
    )
    entries = []
    for row in census["files"]:
        name = row["path"]
        fixture.require(fixture.canonical_name(name), "inventory_input_name")
        text = result["sources"][name]
        fixture.require(type(text) is str, "inventory_input_bytes")
        data = text.encode("utf-8")
        fixture.require(
            len(data) == row["bytes"]
            and hashlib.sha256(data).hexdigest() == row["sha256"]
            and hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\x00" + data).hexdigest()
            == row["git_blob_oid"],
            "inventory_input_bytes",
        )
        entries.append((name, data))
    return tuple(entries)


def composed_entries(fixture):
    owner = fixture.owner(BUILD)
    initial = fixture.stamp(owner.lstat())[:4]
    census = manifest(fixture)
    original = fixture.sources(census=fixture.manifest())
    extra = supplemental_entries(fixture, census)
    old_names, new_names = {name for name, _ in original}, {name for name, _ in extra}
    fixture.require(
        len(original) == len(old_names) == 1019
        and len(extra) == len(new_names) == 21
        and not old_names.intersection(new_names),
        "inventory_input_collision",
    )
    entries = original + extra
    fixture.require(len(entries) == len(old_names | new_names) == 1040, "inventory_input_count")
    fixture.require(fixture.stamp(owner.lstat())[:4] == initial, "inventory_current_root")
    return entries


def fixed_test(fixture, name, path, expected):
    data = fixture.read_owned(path, 100000, "inventory_test_source")
    fixture.require(hashlib.sha256(data).hexdigest() == expected, "inventory_test_source")
    return module_from_bytes(name, path, data)


def run_controls(directory, compiler, blocks_root=None):
    fixture = bootstrap_fixture()
    directory = fixture.owner(directory)
    before = fixture.stamp(directory.lstat())[:4]
    entries = composed_entries(fixture)
    producer = fixed_test(
        fixture,
        "inventory_original_producer_tests",
        BUILD / "remap_runtime_producer_test.py",
        PRODUCER_SHA256,
    )
    inventory = fixed_test(
        fixture,
        "inventory_original_inventory_tests",
        BUILD / "remap_runtime_inventory_test.py",
        INVENTORY_SHA256,
    )
    loader = unittest.TestLoader()
    production = loader.loadTestsFromTestCase(producer.FixedProducerBehavior)
    enumeration = loader.loadTestsFromTestCase(inventory.NativeInventoryBehavior)
    fixture.require(
        production.countTestCases() == 7
        and enumeration.countTestCases() == 2
        and len(inventory.SCENARIOS) == len(set(inventory.SCENARIOS)) == 37,
        "inventory_control_count",
    )
    with tempfile.TemporaryDirectory(prefix="owned-inventory-offline-", dir=directory) as temporary:
        work = fixture.owner(Path(temporary))
        source = work / "source"
        source.mkdir(mode=0o700)
        fixture.publish_sources(source, entries)
        vendor = source / "vendor/vendor/include"
        producer.UPSTREAM, producer.VENDOR = source, vendor
        inventory.OPTIONS = SimpleNamespace(
            upstream=source,
            vendor=vendor,
            compiler=compiler,
            blocks_root=blocks_root,
        )
        previous_temporary = tempfile.tempdir
        try:
            tempfile.tempdir = str(work)
            result = unittest.TextTestRunner(verbosity=2).run(
                unittest.TestSuite([production, enumeration])
            )
        finally:
            tempfile.tempdir = previous_temporary
        fixture.require(
            result.testsRun == 9 and not result.skipped and result.wasSuccessful(),
            "inventory_controls",
        )
        fixture.require(fixture.stamp(directory.lstat())[:4] == before, "inventory_current_root")
    sys.stdout.write(REPORT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner", type=Path, required=True)
    parser.add_argument("--compiler", default="clang++")
    parser.add_argument(
        "--blocks-root",
        type=Path,
        help="Linux signed BlocksRuntime usr; Darwin uses libSystem",
    )
    options = parser.parse_args()
    try:
        run_controls(options.owner, options.compiler, options.blocks_root)
    except (RuntimeError, OSError, ValueError) as error:
        print("Refused owned inventory fixture: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
