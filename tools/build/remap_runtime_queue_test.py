"""Execute the complete actual vendor events-monitor and owned wrapper with modeled native ports.

This bounded acquisition prerequisite gate does not qualify Darwin queues,
retirement of in-flight delivery, sampling/open cutover, installation or physical capture.
"""

import argparse
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
    "null-queue",
    "healthy",
    "retry-recovery",
    "failed-stop-restart",
    "unobserved-values",
    "pending-native-before-dispatch",
)
MODELED_HEADERS = [
    "CoreFoundation/CoreFoundation.h",
    "IOKit/IOKitLib.h",
    "IOKit/hid/IOHIDLib.h",
    "IOKit/hid/IOHIDKeys.h",
    "IOKit/hid/IOHIDDevice.h",
    "IOKit/hid/IOHIDQueue.h",
    "IOKit/hidsystem/IOHIDParameter.h",
    "mach/mach_time.h",
    "uuid/uuid.h",
    "device_properties.hpp",
    "hid_report_only_events.hpp",
    "nod/nod.hpp",
    "pqrs/cf/run_loop_thread.hpp",
    "pqrs/dispatcher.hpp",
    "pqrs/gsl.hpp",
    "pqrs/osx/chrono.hpp",
    "pqrs/osx/iokit_hid_device.hpp",
    "pqrs/osx/iokit_hid_value.hpp",
    "pqrs/osx/iokit_return.hpp",
    "pqrs/osx/iokit_types.hpp",
]
# The events-monitor class is deliberately NOT a modeled header. Its complete
# genuine vendor source is included from the closed source factory output.


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
    result = dict(factory._assemble_vhd_outputs(originals, dependencies, deadline))
    if OPTIONS.original_monitor:
        path = "vendor/vendor/include/pqrs/osx/iokit_hid_device_events_monitor.hpp"
        result[path] = originals[path]
    return result


def executable(directory, source):
    share, ports = directory / "actual-source", directory / "modeled-ports"
    vendor_source = directory / "actual-vendor-source"
    share.mkdir(parents=True)
    ports.mkdir()
    vendor_source.mkdir()
    for relative, data in source.items():
        if relative.startswith("src/share/"):
            target = share / relative.removeprefix("src/share/")
        elif relative == "vendor/vendor/include/pqrs/osx/iokit_hid_device_events_monitor.hpp":
            target = vendor_source / relative.removeprefix("vendor/vendor/include/")
        else:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    shutil.copyfile(BUILD / "fixtures/owned_runtime_queue_ports.hpp", ports / "ports.hpp")
    for relative in MODELED_HEADERS:
        target = ports / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('#include "ports.hpp"\n')
    binary = directory / "actual-queue-acquisition"
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
        "-isystem",
        str(vendor_source),
        "-isystem",
        str(OPTIONS.upstream / "vendor/vendor/include"),
        "-I",
        str(OPTIONS.vendor),
        str(BUILD / "fixtures/owned_runtime_queue_test.cpp"),
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
        raise RuntimeError("Actual vendor queue acquisition compilation failed:\n" + result.stderr)
    return binary


class NativeQueueAcquisitionBehavior(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="actual-owned-queue-acquisition-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.binary = executable(Path(cls.temporary.name), outputs())

    def test_handwritten_queue_acquisition_scenarios(self):
        for scenario in SCENARIOS:
            with self.subTest(scenario=scenario):
                result = subprocess.run(
                    [str(self.binary), scenario],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertEqual(
                    result.stdout,
                    "PASS actual vendor queue acquisition "
                    + scenario
                    + "; modeled native ports only\n",
                )

    def test_unknown_queue_scenario_refuses(self):
        result = subprocess.run(
            [str(self.binary), "unknown-queue-case"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown independent queue acquisition scenario", result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--vendor", type=Path, required=True)
    parser.add_argument("--compiler", default="clang++")
    parser.add_argument(
        "--blocks-root",
        type=Path,
        help="Linux BlocksRuntime usr directory; Darwin uses libSystem",
    )
    parser.add_argument(
        "--original-monitor",
        action="store_true",
        help="Private genuine-before replay; replace only the queue class with authenticated pristine source",
    )
    OPTIONS = parser.parse_args()
    OPTIONS.upstream, OPTIONS.vendor = (
        OPTIONS.upstream.absolute(),
        OPTIONS.vendor.absolute(),
    )
    if OPTIONS.blocks_root:
        OPTIONS.blocks_root = OPTIONS.blocks_root.absolute()
    unittest.main(argv=[sys.argv[0]], verbosity=2)
