# tools/build/remap_runtime_queue_fixture.py
"""Run fixed queue acquisition controls with the genuine offline input owner.

The complete actual vendor class uses explicitly modeled native ports. This
qualifies the create prerequisite only, not Darwin delivery or queue cutover.
"""

import argparse
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

import remap_runtime_inventory_fixture as inventory

QUEUE_SOURCE_SHA256 = "c45241a8eaec6a85ac2c501a7adc794391722244aa90ea1052adb30e5a61187b"
REPORT = "PASS owned runtime queue acquisition=6 unknown=1; modeled platform ports only\n"
SCENARIOS = (
    "null-queue",
    "healthy",
    "retry-recovery",
    "failed-stop-restart",
    "unobserved-values",
    "pending-native-before-dispatch",
)


def run_controls(directory, compiler, blocks_root=None):
    fixture = inventory.bootstrap_fixture()
    directory = fixture.owner(directory)
    before = fixture.stamp(directory.lstat())[:4]
    entries = inventory.composed_entries(fixture)
    queue = inventory.fixed_test(
        fixture,
        "queue_fixed_acquisition_controls",
        inventory.BUILD / "remap_runtime_queue_test.py",
        QUEUE_SOURCE_SHA256,
    )
    suite = unittest.TestLoader().loadTestsFromTestCase(queue.NativeQueueAcquisitionBehavior)
    fixture.require(
        suite.countTestCases() == 2 and queue.SCENARIOS == SCENARIOS,
        "queue_control_count",
    )
    with tempfile.TemporaryDirectory(prefix="owned-queue-offline-", dir=directory) as temporary:
        work = fixture.owner(Path(temporary))
        source = work / "source"
        source.mkdir(mode=0o700)
        fixture.publish_sources(source, entries)
        queue.OPTIONS = SimpleNamespace(
            upstream=source,
            vendor=source / "vendor/vendor/include",
            compiler=compiler,
            blocks_root=blocks_root,
            original_monitor=False,
        )
        previous_temporary = tempfile.tempdir
        try:
            tempfile.tempdir = str(work)
            result = unittest.TextTestRunner(verbosity=2).run(suite)
        finally:
            tempfile.tempdir = previous_temporary
        fixture.require(
            result.testsRun == 2 and not result.skipped and result.wasSuccessful(),
            "queue_controls",
        )
        fixture.require(fixture.stamp(directory.lstat())[:4] == before, "queue_current_root")
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
        print("Refused owned queue fixture: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
