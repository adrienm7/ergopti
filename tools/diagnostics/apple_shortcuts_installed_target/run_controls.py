"""Run one closed portable unittest group; never invoke the native collector."""

import argparse
import importlib
import json
from pathlib import Path
import sys
import unittest


def flatten(suite):
    """Enumerate the actual suite before execution, preserving loader order."""
    result = []
    for item in suite:
        result.extend(flatten(item) if isinstance(item, unittest.TestSuite) else [item])
    return result


class ObservedResult(unittest.TextTestResult):
    """Record actual successes and order without deriving results from predictions."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.seen = []
        self.successes = []

    def startTest(self, test):
        self.seen.append(test.id())
        super().startTest(test)

    def addSuccess(self, test):
        self.successes.append(test.id())
        super().addSuccess(test)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--group", choices=("reader", "loader_output"), required=True)
    parser.add_argument("--result", type=Path, required=True)
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    names = plan["groups"][args.group]
    if not names or len(names) != len(set(names)):
        raise RuntimeError("selection_refused")
    module_name = (
        "test_installed_target_reader"
        if args.group == "reader"
        else "test_collector_source_binding"
    )
    sys.path.insert(0, str(args.worker / "candidate"))
    module = importlib.import_module(module_name)
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    actual = [test.id() for test in flatten(suite)]
    if actual != names or any(not name.startswith(module_name + ".") for name in actual):
        raise RuntimeError("selection_refused")
    result = unittest.TextTestRunner(verbosity=2, resultclass=ObservedResult).run(suite)
    census_valid = result.seen == names and result.testsRun == len(names)
    packet = {
        "schema": 1,
        "group": args.group,
        "tests": result.testsRun,
        "seen": result.seen,
        "successes": result.successes,
        "failures": sorted(test.id() for test, _text in result.failures),
        "errors": sorted(test.id() for test, _text in result.errors),
        "skipped": sorted(test.id() for test, _reason in result.skipped),
        "expected_failures": sorted(test.id() for test, _text in result.expectedFailures),
        "unexpected_successes": sorted(test.id() for test in result.unexpectedSuccesses),
        "census_valid": census_valid,
        "native_observation": False,
    }
    args.result.write_text(json.dumps(packet, indent="\t") + "\n")
    return 0 if census_valid and result.wasSuccessful() and not result.skipped else 1


if __name__ == "__main__":
    raise SystemExit(main())
