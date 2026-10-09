"""Actual fixed producer behavior through bounded modeled native ports.

No Darwin, queue cutover, enumeration-completeness, installed artifact or physical
capture is qualified. Original experimental routes are executed independently.
"""

import argparse
from contextlib import contextmanager
import importlib.util
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

BUILD = Path(__file__).resolve().parent
REPOSITORY = BUILD.parent.parent
UPSTREAM = VENDOR = None
MONITOR = "src/share/hid_device_events_monitor.hpp"
DAEMON = "src/apps/CoreService/include/core_service/main/daemon.hpp"


@contextmanager
def refused_output():
    # A real read-only descriptor rejects child writes with EBADF. It needs no
    # Linux-only device, signal-resistant child or synthetic fprintf override.
    with tempfile.NamedTemporaryFile() as target:
        with open(target.name, "rb") as descriptor:
            yield descriptor


def retained_module(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


def outputs():
    factory = retained_module("producer_fixed_factory", BUILD / "remap_runtime_source.py")
    provider = retained_module("producer_namespace_provider", BUILD / "remap_runtime_patch.py")
    expected = dict(provider.PARENT_PREIMAGES)
    expected[provider.PARENT_LIFECYCLE_PREIMAGE[0]] = provider.PARENT_LIFECYCLE_PREIMAGE[1]
    expected.update(factory.AUTH_VENDOR_ORIGINAL_PREIMAGES)
    expected.update(factory.STREAM_INPUTS)
    expected.update(factory.OWNED_INVENTORY_INPUTS)
    expected.update(factory.VHD_ORIGINAL_INPUTS)
    originals = {path: (UPSTREAM / path).read_bytes() for path in expected}
    end = time.monotonic() + 60
    dependencies = factory.capture_dependencies(REPOSITORY, end) + factory.capture_vhd_dependencies(
        REPOSITORY, end
    )
    owned = dict(factory._assemble_vhd_outputs(originals, dependencies, end))
    sys.path.insert(0, str(REPOSITORY / "tools/diagnostics"))
    stream = retained_module(
        "producer_original_diagnostic", REPOSITORY / "tools/diagnostics/hs274_stream_patch.py"
    )
    raw = retained_module(
        "producer_original_raw", REPOSITORY / "tools/diagnostics/hs274_raw_patch.py"
    )
    diagnostic = {
        MONITOR: stream.stream_monitor(originals[MONITOR].decode()).encode(),
        DAEMON: raw.instrument_shutdown(originals[DAEMON].decode()).encode(),
    }
    for name in factory.STREAM_HEADERS:
        diagnostic["src/share/" + name] = (REPOSITORY / "tools/diagnostics" / name).read_bytes()
    return owned, diagnostic


def executable(directory, source, diagnostic=False):
    share = directory / "actual-source"
    share.mkdir(parents=True)
    for path, data in source.items():
        if path.startswith("src/share/") and "/" not in path[len("src/share/") :]:
            (share / Path(path).name).write_bytes(data)
    # Execute the final expression from the actual assembled daemon. Native
    # daemon startup/cleanup is deliberately not modeled by this small control.
    exits = re.findall(r"\n  (return [^\n]+;)\n}\n", source[DAEMON].decode())
    if len(exits) != 1:
        raise RuntimeError("Actual assembled daemon has no unique final return expression")
    (share / "assembled_shutdown.hpp").write_text(
        '#include "hs274-raw-capture.hpp"\ninline int assembled_shutdown() { ' + exits[0] + " }\n"
    )
    ports = directory / "modeled-ports"
    ports.mkdir()
    shutil.copyfile(BUILD / "fixtures/owned_runtime_producer_ports.hpp", ports / "ports.hpp")
    for name in (
        "CoreFoundation/CoreFoundation.h",
        "IOKit/IOKitLib.h",
        "IOKit/hid/IOHIDLib.h",
        "IOKit/hid/IOHIDKeys.h",
        "IOKit/hidsystem/IOHIDParameter.h",
        "mach/mach_time.h",
        "uuid/uuid.h",
        "device_properties.hpp",
        "hid_report_only_events.hpp",
        "nod/nod.hpp",
        "pqrs/cf/run_loop_thread.hpp",
        "pqrs/dispatcher.hpp",
        "pqrs/gsl.hpp",
        "pqrs/osx/iokit_hid_device_events_monitor.hpp",
        "pqrs/osx/iokit_hid_value.hpp",
        "pqrs/osx/iokit_return.hpp",
    ):
        destination = ports / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text('#include "ports.hpp"\n')
    binary = directory / "actual-producer"
    command = [
        "c++",
        "-std=c++20",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-O2",
        "-rdynamic",
        "-I",
        str(share),
        "-I",
        str(ports),
        "-I",
        str(VENDOR),
        str(BUILD / "fixtures/owned_runtime_producer_test.cpp"),
        "-o",
        str(binary),
    ]
    if diagnostic:
        command.insert(1, "-DTEST_DIAGNOSTIC_PROFILE")
    compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if compiled.returncode:
        raise RuntimeError("Actual producer portable compilation failed:\n" + compiled.stderr)
    return binary


class FixedProducerBehavior(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="actual-owned-producer-")
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        owned, diagnostic = outputs()
        cls.owned = executable(root / "owned", owned)
        cls.diagnostic = executable(root / "diagnostic", diagnostic, True)

    def run_behavior(self, binary, scenario, **ports):
        return subprocess.run(
            [str(binary), scenario], capture_output=not ports, text=True, timeout=30, **ports
        )

    def test_owned_actual_monitor_exceeds_finite_capacity_without_reference_probe_or_receipts(self):
        result = self.run_behavior(self.owned, "route")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(
            result.stdout, "PASS actual assembled producer route; modeled native ports only\n"
        )

    def test_original_diagnostic_route_retains_independent_finite_mirror_and_receipts(self):
        result = self.run_behavior(self.diagnostic, "route")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HS274_KEY_INVENTORY ", result.stderr)
        self.assertIn("HS274_BASELINE_PROBE ", result.stderr)

    def test_owned_actual_baseline_acquisition_does_not_depend_on_stderr(self):
        with refused_output() as refused:
            result = self.run_behavior(
                self.owned, "closed-stderr", stdout=subprocess.PIPE, stderr=refused
            )
        self.assertEqual(result.returncode, 0)

    def test_owned_actual_shutdown_does_not_depend_on_diagnostic_stdout(self):
        with refused_output() as refused:
            result = self.run_behavior(
                self.owned, "shutdown", stdout=refused, stderr=subprocess.PIPE
            )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_original_diagnostic_shutdown_preserves_receipt_write_failure(self):
        with refused_output() as refused:
            result = self.run_behavior(
                self.diagnostic, "shutdown", stdout=refused, stderr=subprocess.PIPE
            )
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_actual_provenance_revalidation_remains_fail_closed(self):
        for binary in (self.owned, self.diagnostic):
            with self.subTest(binary=binary):
                result = self.run_behavior(binary, "changed-identity")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_actual_acquisition_fault_remains_sticky(self):
        for binary in (self.owned, self.diagnostic):
            with self.subTest(binary=binary):
                result = self.run_behavior(binary, "allocation")
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--vendor", type=Path, required=True)
    options = parser.parse_args()
    UPSTREAM, VENDOR = options.upstream.absolute(), options.vendor.absolute()
    unittest.main(argv=[sys.argv[0]], verbosity=2)
