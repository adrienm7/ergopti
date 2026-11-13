"""Controlled diagnostic query ports only; no native command or display is launched."""

import argparse
import ast
import hashlib
import io
import json
import pathlib
import re
import subprocess
import sys
import types
import unittest


def select_helpers(source_path):
    """Select the exact diagnostic helpers without importing the Linux owner."""
    source_bytes = source_path.read_bytes()
    source = source_bytes.decode("utf-8")
    tree = ast.parse(source, filename=str(source_path))
    names = ("_window_failure_snapshot", "_emit_complete_child_log")
    selected = [
        node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names
    ]
    if tuple(node.name for node in selected) != names:
        raise AssertionError("Expected exactly the two diagnostic helpers in owner order")
    if any(
        isinstance(node, (ast.Import, ast.ImportFrom))
        for part in selected
        for node in ast.walk(part)
    ):
        raise AssertionError("Selected helpers must not import a module")

    def unused_clock():
        raise AssertionError("Each control must supply its finite clock explicitly")

    ports = {
        "__builtins__": {
            "Exception": Exception,
            "ValueError": ValueError,
            "OSError": OSError,
            "type": type,
            "bytes": bytes,
            "int": int,
            "len": len,
            "list": list,
            "dict": dict,
            "min": min,
            "max": max,
            "zip": zip,
        },
        "subprocess": types.SimpleNamespace(
            CompletedProcess=subprocess.CompletedProcess, TimeoutExpired=subprocess.TimeoutExpired
        ),
        "time": types.SimpleNamespace(monotonic=unused_clock),
        "re": types.SimpleNamespace(
            search=re.search, match=re.match, findall=re.findall, MULTILINE=re.MULTILINE
        ),
    }
    module = ast.Module(body=selected, type_ignores=[])
    exec(compile(module, str(source_path) + "::selected-diagnostics", "exec"), ports)
    return ports, {
        "source_path": str(source_path),
        "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
        "selected_functions": [
            {
                "name": node.name,
                "first_line": node.lineno,
                "last_line": node.end_lineno,
                "source_sha256": hashlib.sha256(
                    ast.get_source_segment(source, node).encode("utf-8")
                ).hexdigest(),
            }
            for node in selected
        ],
        "production_module_imported": False,
        "production_main_executed": False,
    }


class MemoryLogPath:
    """Expose only the selected log helper's read-only binary stream port."""

    def __init__(self, content):
        self.content = content

    def open(self, mode):
        if mode != "rb":
            raise AssertionError("Child log must be opened read-only in binary mode")
        return io.BytesIO(self.content)


class WindowSetupFailureDiagnosticsTests(unittest.TestCase):
    source_path = pathlib.Path(__file__).with_name("run_window_switch_receipts.py")
    selection = None

    @classmethod
    def setUpClass(cls):
        global _window_failure_snapshot, _emit_complete_child_log
        ports, cls.selection = select_helpers(cls.source_path)
        _window_failure_snapshot = ports["_window_failure_snapshot"]
        _emit_complete_child_log = ports["_emit_complete_child_log"]

    def test_reciprocal_wm_and_observed_clients_are_read_only_queries(self):
        calls = []

        def query(argv, timeout):
            calls.append((argv, timeout))
            if argv == ("xprop", "-root", "_NET_SUPPORTING_WM_CHECK"):
                stdout = b"_NET_SUPPORTING_WM_CHECK(WINDOW): window id # 0x10\n"
            elif argv[:3] == ("xprop", "-id", "0x10"):
                stdout = b"_NET_SUPPORTING_WM_CHECK(WINDOW): window id # 0x11\n"
            elif argv == ("xprop", "-root", "_NET_CLIENT_LIST_STACKING", "_NET_CLIENT_LIST"):
                stdout = b"_NET_CLIENT_LIST_STACKING(WINDOW): window id # 0x30, 0x30\n"
            elif argv == ("xwininfo", "-root", "-tree"):
                stdout = (
                    b'  0x20 "owned111_active": ("owned111_active" "Xmessage")\n'
                    b'  0x99 "other": ("other" "Other")\n'
                )
            else:
                stdout = b"_NET_WM_PID:  not found.\n"
            return subprocess.CompletedProcess(argv, 0, stdout, b"")

        result = _window_failure_snapshot(query, now=lambda: 0.0)
        self.assertEqual(result["observed_client_ids"], 2)
        self.assertEqual(result["omitted_client_ids"], 0)
        self.assertEqual(
            calls[1][0],
            ("xprop", "-id", "0x10", "_NET_SUPPORTING_WM_CHECK", "_NET_WM_NAME", "_NET_WM_PID"),
        )
        self.assertIn("window id # 0x11", result["queries"][1]["stdout"])
        self.assertEqual(
            [argv for argv, _ in calls if argv[:2] == ("xwininfo", "-id")],
            [("xwininfo", "-id", "0x20"), ("xwininfo", "-id", "0x30")],
        )
        self.assertTrue(all(timeout == 0.5 for _, timeout in calls))
        self.assertFalse(any("0x99" in argv for argv, _ in calls))
        self.assertFalse(any("pid" in record for record in result["queries"]))
        self.assertTrue(all(argv[0] in ("xprop", "xwininfo") for argv, _ in calls))

    def test_one_shared_budget_prevents_later_query_calls(self):
        clock = [0.0]
        calls = []

        def query(argv, timeout):
            calls.append((argv, timeout))
            clock[0] = 3.0
            return subprocess.CompletedProcess(
                argv, 0, b"_NET_SUPPORTING_WM_CHECK(WINDOW): window id # 0x10\n", b""
            )

        result = _window_failure_snapshot(query, now=lambda: clock[0])
        self.assertEqual(len(calls), 1)
        self.assertEqual(
            [record["state"] for record in result["queries"]],
            ["completed", "budget-exhausted", "budget-exhausted", "budget-exhausted"],
        )

    def test_timeout_foreign_receipt_and_nonzero_status_do_not_select_ids(self):
        calls = []

        def query(argv, timeout):
            calls.append(argv)
            if len(calls) == 1:
                raise subprocess.TimeoutExpired(argv, timeout, output=b"partial", stderr=b"late")
            if len(calls) == 2:
                return subprocess.CompletedProcess(("foreign",), 0, b"0x20", b"")
            return subprocess.CompletedProcess(
                argv, 1, b'  0x20 "owned111_active": ("owned111_active" "Xmessage")\n', b""
            )

        result = _window_failure_snapshot(query, now=lambda: 0.0)
        self.assertEqual(result["observed_client_ids"], 0)
        self.assertEqual(
            [record["state"] for record in result["queries"]],
            ["timeout", "query-error", "completed"],
        )
        self.assertEqual(result["queries"][0]["stdout"], "partial")
        self.assertEqual(result["queries"][2]["status"], 1)
        self.assertEqual(len(calls), 3)

    def test_retained_streams_and_selected_windows_have_finite_limits(self):
        calls = []

        def query(argv, timeout):
            calls.append(argv)
            if argv[:2] == ("xprop", "-root") and "_NET_CLIENT_LIST" in argv:
                stdout = b"_NET_CLIENT_LIST(WINDOW): window id # " + b", ".join(
                    ("0x%x" % value).encode("ascii") for value in range(1, 10)
                )
            else:
                stdout = b"x" * 70000
            return subprocess.CompletedProcess(argv, 0, stdout, b"y" * 70000)

        result = _window_failure_snapshot(query, now=lambda: 0.0)
        self.assertEqual(result["observed_client_ids"], 9)
        self.assertEqual(result["omitted_client_ids"], 3)
        self.assertEqual(len([argv for argv in calls if argv[:2] == ("xwininfo", "-id")]), 6)
        self.assertEqual(result["queries"][0]["stdout_bytes"], 70000)
        self.assertEqual(len(result["queries"][0]["stdout"]), 65536)
        self.assertTrue(result["queries"][0]["stdout_truncated"])
        self.assertTrue(all(len(record["stderr"]) == 65536 for record in result["queries"]))

    def test_child_log_keeps_every_byte_across_chunks(self):
        expected = b"before\x00\xff" + b"x" * 131072 + b"after cleanup\n"
        chunks = []

        def write(chunk):
            chunks.append(chunk)
            return len(chunk)

        _emit_complete_child_log(MemoryLogPath(expected), write)
        self.assertGreater(len(chunks), 1)
        self.assertEqual(b"".join(chunks), expected)

    def test_short_child_log_write_cannot_claim_complete_emission(self):
        with self.assertRaisesRegex(OSError, "incomplete child-log write"):
            _emit_complete_child_log(
                MemoryLogPath(b"owned child output"), lambda chunk: len(chunk) - 1
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=pathlib.Path)
    parser.add_argument("--receipt", type=pathlib.Path)
    args = parser.parse_args()
    if args.source is not None:
        WindowSetupFailureDiagnosticsTests.source_path = args.source
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(WindowSetupFailureDiagnosticsTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    receipt = {
        "state": "PASS" if result.wasSuccessful() else "RED",
        "python_version": sys.version,
        "selection": WindowSetupFailureDiagnosticsTests.selection,
        "tests_run": result.testsRun,
        "failures": len(result.failures),
        "errors": len(result.errors),
        "skipped": len(result.skipped),
        "native_actor_executed": False,
        "scope": "Exact AST-selected diagnostic helpers with fake query/clock/stream ports; no production import or actor.",
    }
    if args.receipt is not None:
        with args.receipt.open("x", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    raise SystemExit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
