"""Failed native C frames retain fixed provenance after an actual child is reaped.

The executable wire peer is a Linux subprocess, not a signed Darwin producer.
The stage/reason/status expectations are independent protocol literals.
"""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(
    os.environ.get("ERGOPTI_FAILURE_STAGE_SOURCE_ROOT", Path(__file__).resolve().parents[2])
)
MACOS = ROOT / "static/ergopti_plus/macos"
CASES = (
    ("native_policy_load", "unavailable", 78),
    ("native_selection_bound", "unavailable", 78),
    ("native_proxy_lookup", "unavailable", 78),
    ("native_proxy_dictionary", "proxy", 78),
    ("native_route_empty", "unavailable", 78),
    ("native_certificate_load", "certificate", 74),
    ("native_lookup_deadline", "deadline", 75),
    ("native_dispatch_deadline", "deadline", 75),
    ("native_session_terminal", "connect", 74),
)
PEER = """
import json, os, struct, sys
request = json.loads(sys.stdin.buffer.read())
assert request['url'] == 'https://private-company.invalid/model?private=payload'
assert request['headers'] == [['Authorization', 'Bearer private-secret-token']]
assert sys.argv[3] == '--managed-http-worker'
if json.loads(sys.argv[1]).get('success') is True or sys.argv[-1] == 'body':
    head = b'H' + b'{"version":1,"status":200,"headers":[["Content-Length","0"]]}'
    sys.stdout.buffer.write(struct.pack('>I', len(head)) + head)
payload = b'C' + sys.argv[1].encode('utf-8')
sys.stdout.buffer.write(struct.pack('>I', len(payload)) + payload)
sys.stdout.buffer.flush()
os._exit(int(sys.argv[2]))
"""


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class NativeFailureStages(unittest.TestCase):
    def setUp(self):
        self.engine = load("failure_stage_engine", MACOS / "platform/network/native_http.py")
        self.reporter = load(
            "failure_stage_reporter", MACOS / "modules/llm/managed_bootstrap_http.py"
        )
        self.children = []
        self.directory = tempfile.TemporaryDirectory(prefix="native-failure-stage-")
        self.addCleanup(self.directory.cleanup)
        self.peer = Path(self.directory.name) / "wire_peer.py"
        self.peer.write_text(PEER, encoding="utf-8")

    def receive(self, payload, status, *, through_bootstrap=False, body_phase=False):
        real_popen = subprocess.Popen

        def spawn(arguments, **kwargs):
            self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
            self.assertTrue(kwargs["close_fds"])
            child = real_popen(
                [
                    sys.executable,
                    "-B",
                    str(self.peer),
                    payload,
                    str(status),
                    *arguments[1:],
                    "body" if body_phase else "initial",
                ],
                **kwargs,
            )
            self.children.append(child)
            return child

        with (
            mock.patch.object(self.engine, "_resolve_worker", return_value="owned-native-edge"),
            mock.patch.object(self.engine.subprocess, "Popen", side_effect=spawn),
            mock.patch.dict(sys.modules, {"_ergopti_native_http": self.engine}),
        ):
            try:
                acquire = (
                    self.reporter._native_request
                    if through_bootstrap
                    else self.engine.NativeHTTPResponse
                )
                response = acquire(
                    "https://private-company.invalid/model?private=payload",
                    [["Authorization", "Bearer private-secret-token"]],
                    timeout=3,
                    idle_timeout=3,
                )
                self.assertEqual(response.read(), b"", "Zero-length success requires its terminal")
            except self.engine.NativeHTTPError as failure:
                return failure
            response.close()
            return response

    def assert_retired(self, result, expected_status=None):
        self.assertEqual(len(self.children), 1)
        child = self.children[0]
        self.assertIsInstance(child.returncode, int)
        if expected_status is not None:
            self.assertEqual(child.returncode, expected_status)
        self.assertTrue(child.stdin.closed)
        self.assertTrue(child.stdout.closed)
        with self.assertRaises(ProcessLookupError):
            os.kill(child.pid, 0)
        if hasattr(result, "native_diagnostic"):
            facts = result.native_diagnostic
            self.assertEqual(facts["cleanup"], "confirmed")
            self.assertEqual(facts["native_child_pid"], child.pid)
            self.assertEqual(facts["native_child_status"], child.returncode)
        self.children.clear()

    def test_nine_allowed_failures_preserve_reason_exit_and_exact_retirement(self):
        for stage, reason, status, body_phase in (
            *((stage, reason, status, False) for stage, reason, status in CASES),
            ("native_session_terminal", "connect", 74, True),
        ):
            with self.subTest(stage=stage, body_phase=body_phase):
                result = self.receive(
                    json.dumps(
                        {
                            "version": 1,
                            "success": False,
                            "reason": reason,
                            "native_refusal_stage": stage,
                        }
                    ),
                    status,
                    body_phase=body_phase,
                )
                self.assertIsInstance(result, self.engine.NativeHTTPError)
                self.assertEqual(result.reason, reason)
                self.assertEqual(result.native_diagnostic["stage"], stage)
                self.assertEqual(result.native_diagnostic["native_receipt_reason"], reason)
                self.assert_retired(result, status)

    def test_closed_stage_schema_rejects_eight_ambiguous_or_success_inputs(self):
        payloads = (
            '{"version":1,"success":false,"reason":"unavailable","native_refusal_stage":null}',
            '{"version":1,"success":false,"reason":"unavailable","native_refusal_stage":false}',
            '{"version":1,"success":false,"reason":"unavailable","native_refusal_stage":"raw/private-secret-token"}',
            '{"version":1,"success":false,"reason":"certificate","native_refusal_stage":"native_policy_load"}',
            '{"version":1,"success":true,"reason":"complete","native_refusal_stage":"native_session_terminal"}',
            '{"version":1,"success":false,"reason":"unavailable","native_refusal_stage":"native_policy_load","native_refusal_stage":"native_proxy_lookup"}',
            '{"version":1,"success":false,"reason":"unavailable","native_refusal_stage":"native_policy_load","extra":"private-company.invalid"}',
            '{"version":1,"success":false,"reason":"complete","native_refusal_stage":"native_session_terminal"}',
        )
        for payload in payloads:
            with self.subTest(payload=payload):
                result = self.receive(payload, 78)
                self.assertEqual(result.reason, "protocol")
                self.assertEqual(result.native_diagnostic["stage"], "native_terminal")
                self.assertIsNone(result.native_diagnostic["native_receipt_reason"])
                self.assert_retired(result)

    def test_legacy_success_and_failure_keep_three_field_wire(self):
        failure = self.receive('{"version":1,"success":false,"reason":"unavailable"}', 78)
        self.assertEqual(failure.reason, "unavailable")
        self.assertEqual(failure.native_diagnostic["stage"], "native_terminal")
        self.assert_retired(failure, 78)
        success = self.receive('{"version":1,"success":true,"reason":"complete"}', 0)
        self.assertTrue(success._complete)
        self.assertEqual(
            success._terminal_value, {"version": 1, "success": True, "reason": "complete"}
        )
        self.assert_retired(success, 0)

    def test_emitted_failure_projection_is_fixed_and_contains_no_private_data(self):
        for stage, reason, status, body_phase in (
            *((stage, reason, status, False) for stage, reason, status in CASES),
            ("native_session_terminal", "connect", 74, True),
        ):
            with self.subTest(stage=stage, body_phase=body_phase):
                failure = self.receive(
                    json.dumps(
                        {
                            "version": 1,
                            "success": False,
                            "reason": reason,
                            "native_refusal_stage": stage,
                        }
                    ),
                    status,
                    through_bootstrap=True,
                    body_phase=body_phase,
                )
                captured = io.StringIO()
                with (
                    mock.patch.dict(sys.modules, {"_ergopti_native_http": self.engine}),
                    contextlib.redirect_stderr(captured),
                ):
                    self.reporter._report_failure(failure, failure.reason)
                text = captured.getvalue()
                facts = json.loads(
                    text.splitlines()[0].removeprefix("# managed_bootstrap_failure ")
                )
                self.assertEqual(
                    facts,
                    {
                        "version": 1,
                        "stage": stage,
                        "exception_class": "NativeHTTPError",
                        "native_child_pid": self.children[0].pid,
                        "native_child_status": status,
                        "native_receipt_reason": reason,
                        "cleanup": "confirmed",
                    },
                )
                for private in (
                    "private-company",
                    "private-secret",
                    "payload",
                    str(self.peer),
                    str(self.directory.name),
                ):
                    self.assertNotIn(private, text)
                self.assert_retired(failure, status)

    def test_projection_refuses_four_forged_or_malformed_diagnostic_inputs(self):
        for stage, terminal, kind in (
            ("native_policy_load", "certificate", "NativeHTTPError"),
            ("native_policy_load", ["unavailable"], "NativeHTTPError"),
            ("private-secret-token", "unavailable", "NativeHTTPError"),
            ("native_policy_load", "unavailable", "private-company-exception"),
        ):
            with self.subTest(stage=stage, terminal=terminal, kind=kind):
                failure = self.engine.NativeHTTPError("unavailable")
                failure.native_diagnostic = {
                    "stage": stage,
                    "exception_class": kind,
                    "native_child_pid": 123,
                    "native_child_status": 78,
                    "native_receipt_reason": terminal,
                    "cleanup": "confirmed",
                }
                captured = io.StringIO()
                with (
                    mock.patch.dict(sys.modules, {"_ergopti_native_http": self.engine}),
                    contextlib.redirect_stderr(captured),
                ):
                    self.reporter._report_failure(failure, failure.reason)
                text = captured.getvalue()
                facts = json.loads(
                    text.splitlines()[0].removeprefix("# managed_bootstrap_failure ")
                )
                self.assertEqual(
                    facts,
                    {
                        "version": 1,
                        "stage": "bootstrap",
                        "exception_class": "NativeHTTPError",
                        "native_child_pid": None,
                        "native_child_status": None,
                        "native_receipt_reason": None,
                        "cleanup": "unconfirmed",
                    },
                )
                self.assertNotIn("private-secret", text)
                self.assertNotIn("private-company", text)

    def test_failed_receipt_never_renames_the_observed_child_exit(self):
        failure = self.receive(
            '{"version":1,"success":false,"reason":"unavailable",'
            '"native_refusal_stage":"native_policy_load"}',
            91,
        )
        self.assertEqual(failure.reason, "unavailable")
        self.assertEqual(failure.native_diagnostic["stage"], "native_policy_load")
        self.assert_retired(failure, 91)


if __name__ == "__main__":
    unittest.main()
