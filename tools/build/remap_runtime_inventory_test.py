"""Execute actual assembled inventory owners and vendor classes with modeled platform ports.

This source behavior gate does not qualify Darwin enumeration, native queue
cutover, whole device_grabber construction, installation or physical capture.
"""

import argparse
import hashlib
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

BUILD = Path(__file__).resolve().parent
REPOSITORY = BUILD.parent.parent
OPTIONS = None
SCENARIOS = (
    "late-duplicate",
    "late-absent-termination",
    "pending",
    "pending-open",
    "failed-watcher",
    "failed-port",
    "failed-run-loop-source",
    "failed-terminated-watcher",
    "invalid-iterator",
    "invalid-drain",
    "create-failure",
    "missing-identity",
    "entry-mismatch",
    "missing-monitor",
    "capacity",
    "duplicate",
    "virtual",
    "consumer-only",
    "terminated-during-delay",
    "stop-restart-stale",
    "hotplug-lease",
    "hotplug-pending-baseline",
    "later-invalid-notification",
    "later-invalid-scan",
    "later-scan-error",
    "native-element-read-failure",
    "native-value-read-failure",
    "zero-native-identity",
    "stale-owner-publication",
    "same-watch-create-error",
    "create-error-recovery",
    "queued-identity-failure",
    "queued-iterator-failure",
    "native-entry-matched-iterator",
    "native-entry-terminated-iterator",
    "native-entry-matched-identity",
    "native-entry-terminated-identity",
)
SUPPORT_INPUTS = (
    (
        "vendor/vendor/include/pqrs/gsl.hpp",
        "1d8162c5b39252534b8cdb59c3b7bd8cffae83cadd6dec7a0738087721fb4db7",
    ),
    (
        "src/share/types/device_id.hpp",
        "9365d29445baf320ddb14769244d5029fc742b932d19bb598bf3dbb79a3fa52e",
    ),
    (
        "src/share/device_properties.hpp",
        "8930bdf0067f3d97de760ccb5d7cabaf1b6eb4ebb247c283fb72d7ce1277c933",
    ),
    (
        "src/share/types/device_identifiers.hpp",
        "0bf2ce65a4c05fc01a92486494bf94777b8cc8692b2756efa518a3281704198d",
    ),
    (
        "src/share/iokit_utility.hpp",
        "4942c42c58eb5c49f90d712575d3aaa1c4921efa2978ac6566e547a1d96e97b2",
    ),
    (
        "vendor/vendor/include/pqrs/osx/iokit_types/iokit_registry_entry_id.hpp",
        "fb77cb0fb46a9db0b5a2b40be7defd1524717eee134379309a86820e23df0d78",
    ),
)
MODELED_HEADERS = [
    "CoreFoundation/CoreFoundation.h",
    "IOKit/IOKitLib.h",
    "IOKit/hid/IOHIDLib.h",
    "IOKit/hid/IOHIDKeys.h",
    "IOKit/hid/IOHIDDevice.h",
    "IOKit/hidsystem/IOHIDParameter.h",
    "mach/mach_time.h",
    "uuid/uuid.h",
    "device_properties.hpp",
    "hid_report_only_events.hpp",
    "nod/nod.hpp",
    "pqrs/cf/run_loop_thread.hpp",
    "pqrs/cf/number.hpp",
    "pqrs/dispatcher.hpp",
    "pqrs/gsl.hpp",
    "pqrs/hid.hpp",
    "pqrs/osx/iokit_hid_device_events_monitor.hpp",
    "pqrs/osx/iokit_hid_value.hpp",
    "pqrs/osx/iokit_return.hpp",
    "pqrs/osx/iokit_iterator.hpp",
    "pqrs/osx/iokit_object_ptr.hpp",
    "pqrs/osx/iokit_registry_entry.hpp",
    "pqrs/osx/iokit_types.hpp",
    "pqrs/osx/kern_return.hpp",
]


def retained_module(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
    return module


def outputs():
    factory = retained_module("inventory_fixed_factory", BUILD / "remap_runtime_source.py")
    provider = retained_module("inventory_parent_provider", BUILD / "remap_runtime_patch.py")
    expected = dict(provider.PARENT_PREIMAGES)
    expected[provider.PARENT_LIFECYCLE_PREIMAGE[0]] = provider.PARENT_LIFECYCLE_PREIMAGE[1]
    expected.update(factory.AUTH_VENDOR_ORIGINAL_PREIMAGES)
    expected.update(factory.STREAM_INPUTS)
    expected.update(factory.OWNED_INVENTORY_INPUTS)
    expected.update(factory.VHD_ORIGINAL_INPUTS)
    originals = {path: (OPTIONS.upstream / path).read_bytes() for path in expected}
    deadline = time.monotonic() + 60
    dependencies = factory.capture_dependencies(
        REPOSITORY, deadline
    ) + factory.capture_vhd_dependencies(REPOSITORY, deadline)
    return dict(factory._assemble_vhd_outputs(originals, dependencies, deadline))


def executable(directory, source):
    share, ports = directory / "actual-source", directory / "modeled-ports"
    share.mkdir(parents=True)
    ports.mkdir()
    for relative, data in source.items():
        if relative.startswith("src/share/"):
            target = share / relative.removeprefix("src/share/")
        elif relative in (
            "vendor/vendor/include/pqrs/osx/iokit_service_monitor.hpp",
            "vendor/vendor/include/pqrs/osx/iokit_hid_manager.hpp",
        ):
            target = share / relative.removeprefix("vendor/vendor/include/")
        else:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    # Execute the exact assembled production callback in a bounded entry host.
    # The genuine full native device_grabber constructor is not modeled here.
    grabber = source["src/apps/CoreService/include/core_service/daemon/device_grabber.hpp"].decode(
        "utf-8"
    )
    start = grabber.index("    hid_manager_->ergopti_inventory_changed.connect(")
    end = grabber.index("\n\n    hid_manager_->device_matched.connect", start)
    (share / "assembled_inventory_callback.hpp").write_text("#pragma once\n")
    (share / "assembled_inventory_callback_body.hpp").write_text(
        "inline void inventory_callbacks::connect_actual_inventory() {\n"
        + grabber[start:end]
        + "\n}\n"
    )
    support = {}
    for relative, expected in SUPPORT_INPUTS:
        data = (OPTIONS.upstream / relative).read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise RuntimeError("Unchanged native identity/classifier input changed: " + relative)
        support[relative] = data
    (share / "actual_pqrs_gsl.hpp").write_bytes(support["vendor/vendor/include/pqrs/gsl.hpp"])
    (share / "actual_registry_identity.hpp").write_bytes(
        support["vendor/vendor/include/pqrs/osx/iokit_types/iokit_registry_entry_id.hpp"]
    )
    (share / "actual_device_id.hpp").write_bytes(support["src/share/types/device_id.hpp"])
    utility = support["src/share/iokit_utility.hpp"].decode("utf-8")
    start = utility.index("  static bool is_karabiner_virtual_hid_device(")
    end = utility.index("\n  [[nodiscard]] static std::string make_device_name", start)
    (share / "actual_virtual_classifier.hpp").write_text(
        "namespace krbn { class iokit_utility { public:\n" + utility[start:end] + "\n}; }\n"
    )
    shutil.copyfile(BUILD / "fixtures/owned_runtime_inventory_ports.hpp", ports / "ports.hpp")
    for relative in MODELED_HEADERS:
        target = ports / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('#include "ports.hpp"\n')
    target = ports / "pqrs/osx/iokit_types/extra/nlohmann_json.hpp"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("#pragma once\n")
    binary = directory / "actual-inventory"
    command = [
        OPTIONS.compiler,
        "-std=c++20",
        "-fblocks",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-O1",
        "-I",
        str(share),
        "-I",
        str(ports),
        "-I",
        str(OPTIONS.upstream / "vendor/vendor/include"),
        "-I",
        str(OPTIONS.vendor),
        str(BUILD / "fixtures/owned_runtime_inventory_test.cpp"),
    ]
    if OPTIONS.blocks_root:
        command += [
            "-I",
            str(OPTIONS.blocks_root / "include"),
            "-L",
            str(OPTIONS.blocks_root / "lib/x86_64-linux-gnu"),
            "-Wl,-rpath," + str(OPTIONS.blocks_root / "lib/x86_64-linux-gnu"),
            "-lBlocksRuntime",
        ]
    command += ["-o", str(binary)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError("Actual assembled inventory compilation failed:\n" + result.stderr)
    return binary


class NativeInventoryBehavior(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="actual-owned-inventory-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.binary = executable(Path(cls.temporary.name), outputs())

    def test_independently_declared_inventory_lifecycle_scenarios(self):
        for scenario in SCENARIOS:
            with self.subTest(scenario=scenario):
                result = subprocess.run(
                    [str(self.binary), scenario], capture_output=True, text=True, timeout=5
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertEqual(
                    result.stdout,
                    "PASS actual assembled inventory "
                    + scenario
                    + "; modeled platform ports only\n",
                )

    def test_unknown_inventory_scenario_refuses(self):
        result = subprocess.run(
            [str(self.binary), "unknown-inventory-case"], capture_output=True, text=True, timeout=5
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown independent inventory scenario", result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--vendor", type=Path, required=True)
    parser.add_argument("--compiler", default="clang++")
    parser.add_argument(
        "--blocks-root", type=Path, help="Linux BlocksRuntime usr directory; Darwin uses libSystem"
    )
    OPTIONS = parser.parse_args()
    OPTIONS.upstream, OPTIONS.vendor = OPTIONS.upstream.absolute(), OPTIONS.vendor.absolute()
    if OPTIONS.blocks_root:
        OPTIONS.blocks_root = OPTIONS.blocks_root.absolute()
    unittest.main(argv=[sys.argv[0]], verbosity=2)
