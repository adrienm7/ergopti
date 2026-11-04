"""Exercise the source-selected main finalizer with finite, inert cleanup ports."""

import argparse
import ast
import copy
import hashlib
import io
import json
import pathlib
import sys
import types
import unittest


class CleanupFailure(Exception):
    """Sentinel retirement failure whose exact identity must be retained."""


class FakeTimeoutExpired(Exception):
    """No subprocess module or native process is needed by the finalizer port."""


def select_finalizer(source_path):
    """Compile only main's complete finalizer, never the production module."""
    source_bytes = source_path.read_bytes()
    source = source_bytes.decode("utf-8")
    tree = ast.parse(source, filename=str(source_path))
    mains = [
        node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "main"
    ]
    if len(mains) != 1:
        raise AssertionError("Expected exactly one main function")
    owners = [
        node
        for scope in mains[0].body
        if isinstance(scope, ast.With)
        for node in scope.body
        if isinstance(node, ast.Try) and node.finalbody
    ]
    if len(owners) != 1:
        raise AssertionError("Expected exactly one main-owned finalizer")
    finalbody = owners[0].finalbody
    if any(
        isinstance(node, (ast.Import, ast.ImportFrom))
        for part in finalbody
        for node in ast.walk(part)
    ):
        raise AssertionError("The selected finalizer must not import a module")
    wrapper = ast.parse(
        "def invoke(primary):\n"
        "    failure = None\n"
        "    try:\n"
        "        if primary is not None:\n"
        "            raise primary\n"
        "    except Exception as error:\n"
        "        failure = error\n"
        "        raise\n"
        "    finally:\n"
        "        pass\n"
    )
    wrapper.body[0].body[1].finalbody = copy.deepcopy(finalbody)
    ast.fix_missing_locations(wrapper)
    selected_text = (
        "\n".join(source.splitlines()[finalbody[0].lineno - 1 : finalbody[-1].end_lineno]) + "\n"
    )
    return compile(wrapper, str(source_path) + "::selected-finalizer", "exec"), {
        "source_path": str(source_path),
        "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
        "selected_first_line": finalbody[0].lineno,
        "selected_last_line": finalbody[-1].end_lineno,
        "selected_source_sha256": hashlib.sha256(selected_text.encode("utf-8")).hexdigest(),
        "production_module_imported": False,
        "production_main_executed": False,
    }


def observe_finalizer(code, primary):
    """Record actual finalizer behavior through closed fake child/stream ports."""
    events = []
    metadata_lines = []
    cleanup_error = CleanupFailure("owned child retirement refused")
    output = io.BytesIO()
    child_bytes = b"complete child stdout\ncomplete child stderr\x00\xff\n"

    class Child:
        def __init__(self, pid, refuses):
            self.pid = pid
            self.refuses = refuses
            self.status = None

        def poll(self):
            events.append(["poll", self.pid])
            return self.status

        def terminate(self):
            events.append(["terminate", self.pid])
            if self.refuses:
                raise cleanup_error

        def wait(self, *, timeout):
            events.append(["wait", self.pid, timeout])
            if timeout != 3:
                raise AssertionError("The original retirement timeout changed")
            self.status = 0
            return self.status

        def kill(self):
            raise AssertionError("This finite control does not admit a kill branch")

    class Log:
        def close(self):
            events.append(["log-close"])

    def close(descriptor):
        events.append(["descriptor-close", descriptor])

    def resume(pid, signum):
        events.append(["resume", pid, signum])

    def report(line, *, flush):
        if flush is not True:
            raise AssertionError("Diagnostic reporting must flush")
        metadata_lines.append(line)

    def emit(path, write):
        events.append(["emit-child-log", str(path)])
        if path != pathlib.PurePosixPath("/inert-owned-fixture/native.log"):
            raise AssertionError("Finalizer selected an unexpected child log")
        if write(child_bytes) != len(child_bytes):
            raise AssertionError("Fake stream refused a complete write")

    healthy_child = Child(101, False)
    refusing_child = Child(102, True)
    ports = {
        "__builtins__": {"Exception": Exception, "type": type, "reversed": reversed},
        "children": [healthy_child, refusing_child],
        "reader": 41,
        "writer": 42,
        "wm": healthy_child,
        "os": types.SimpleNamespace(close=close, kill=resume),
        "signal": types.SimpleNamespace(SIGCONT="fake-SIGCONT"),
        "subprocess": types.SimpleNamespace(TimeoutExpired=FakeTimeoutExpired),
        "log": Log(),
        "observations": {"phase": "controlled-primary-failure"},
        "root": pathlib.PurePosixPath("/inert-owned-fixture"),
        "_emit_complete_child_log": emit,
        "sys": types.SimpleNamespace(
            exc_info=sys.exc_info, stdout=types.SimpleNamespace(buffer=output)
        ),
        "json": types.SimpleNamespace(dumps=json.dumps),
        "print": report,
    }
    exec(code, ports)
    observed = None
    try:
        ports["invoke"](primary)
    except BaseException as error:
        observed = error
    expected = primary if primary is not None else cleanup_error
    documents = [
        json.loads(line[len("# native_window_setup_failure ") :])
        for line in metadata_lines
        if line.startswith("# native_window_setup_failure ")
    ]
    return {
        "expected_class": type(expected).__name__,
        "observed_class": type(observed).__name__,
        "expected_exception_identity_preserved": observed is expected,
        "cleanup_exception_identity_observed": observed is cleanup_error,
        "events": events,
        "metadata": documents,
        "complete_child_output_retained": output.getvalue() == child_bytes,
        "complete_child_log_markers": metadata_lines[-2:]
        == ["# native_window_child_log_begin", "\n# native_window_child_log_end"],
    }


class WindowCleanupExceptionPrecedenceTests(unittest.TestCase):
    source_path = pathlib.Path(__file__).with_name("run_window_switch_receipts.py")
    observations = []
    selection = None

    @classmethod
    def setUpClass(cls):
        cls.code, cls.selection = select_finalizer(cls.source_path)
        cls.observations = []

    def check_primary(self, name, primary):
        result = observe_finalizer(self.code, primary)
        result["case"] = name
        type(self).observations.append(result)
        self.assertEqual(
            result["observed_class"],
            result["expected_class"],
            "A cleanup Exception must not replace an active primary exception",
        )
        self.assertTrue(result["expected_exception_identity_preserved"])
        self.assertEqual(
            [event for event in result["events"] if event[0] == "terminate"],
            [["terminate", 102], ["terminate", 101]],
        )
        self.assertIn(["wait", 101, 3], result["events"])
        self.assertEqual(
            [event for event in result["events"] if event[0] == "descriptor-close"],
            [["descriptor-close", 41], ["descriptor-close", 42]],
        )
        self.assertIn(["resume", 101, "fake-SIGCONT"], result["events"])
        self.assertLess(
            result["events"].index(["terminate", 101]), result["events"].index(["log-close"])
        )
        self.assertEqual(len(result["metadata"]), 1)
        self.assertEqual(
            result["metadata"][0]["cleanup_errors"],
            [{"phase": "owned-child-retirement", "error": "CleanupFailure"}],
        )
        self.assertTrue(result["complete_child_output_retained"])
        self.assertTrue(result["complete_child_log_markers"])

    def test_keyboard_interrupt_survives_recorded_retirement_error(self):
        self.check_primary("keyboard_interrupt", KeyboardInterrupt("primary interrupt"))

    def test_system_exit_survives_recorded_retirement_error(self):
        self.check_primary("system_exit", SystemExit(73))

    def test_ordinary_primary_survives_recorded_retirement_error(self):
        self.check_primary("ordinary_exception", ValueError("primary operation failure"))

    def test_no_primary_raises_recorded_retirement_error(self):
        self.check_primary("no_primary", None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=pathlib.Path)
    parser.add_argument("--receipt", type=pathlib.Path)
    args = parser.parse_args()
    if args.source is not None:
        WindowCleanupExceptionPrecedenceTests.source_path = args.source
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(WindowCleanupExceptionPrecedenceTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    receipt = {
        "state": "PASS" if result.wasSuccessful() else "RED",
        "python_version": sys.version,
        "selection": WindowCleanupExceptionPrecedenceTests.selection,
        "tests_run": result.testsRun,
        "failures": len(result.failures),
        "errors": len(result.errors),
        "skipped": len(result.skipped),
        "native_actor_executed": False,
        "cases": WindowCleanupExceptionPrecedenceTests.observations,
        "scope": "Actual AST-selected finalizer with inert ports; no production import or main/native actor execution.",
    }
    if args.receipt is not None:
        with args.receipt.open("x", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    raise SystemExit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
