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
    ("native_proxy_budget", "unavailable", 78),
    ("native_proxy_candidates", "unavailable", 78),
    ("native_pac_download", "unavailable", 78),
    ("native_pac_evaluation", "unavailable", 78),
    ("native_proxy_routes", "unavailable", 78),
    ("native_wpad_discovery", "unavailable", 78),
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
            self.assertTrue(
                hasattr(kwargs["stderr"], "fileno"), "stderr must be the private marker file"
            )
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


FALLBACK_PEER = """
import os, struct, sys
sys.stdin.buffer.read()
sys.stderr.write(sys.argv[1] + "\\n")
sys.stderr.flush()
if sys.argv[2] == "ok":
    head = b'H' + b'{"version":1,"status":200,"headers":[["Content-Length","0"]]}'
    sys.stdout.buffer.write(struct.pack('>I', len(head)) + head)
    payload = b'C{"version":1,"success":true,"reason":"complete"}'
    status = 0
else:
    payload = b'C{"version":1,"success":false,"reason":"connect","native_refusal_stage":"native_session_terminal"}'
    status = 74
sys.stdout.buffer.write(struct.pack('>I', len(payload)) + payload)
sys.stdout.buffer.flush()
os._exit(status)
"""


class NativeRouteFallback(unittest.TestCase):
    """The worker's direct-fallback marker reaches the log as a closed stage only."""

    def setUp(self):
        self.engine = load("route_fallback_engine", MACOS / "platform/network/native_http.py")
        self.reporter = load(
            "route_fallback_reporter", MACOS / "modules/llm/managed_bootstrap_http.py"
        )
        self.directory = tempfile.TemporaryDirectory(prefix="native-route-fallback-")
        self.addCleanup(self.directory.cleanup)
        self.peer = Path(self.directory.name) / "fallback_peer.py"
        self.peer.write_text(FALLBACK_PEER, encoding="utf-8")

    def open(self, marker, mode):
        real_popen = subprocess.Popen

        def spawn(arguments, **kwargs):
            return real_popen(
                [sys.executable, "-B", str(self.peer), marker, mode, *arguments[1:]], **kwargs
            )

        with (
            mock.patch.object(self.engine, "_resolve_worker", return_value="owned-native-edge"),
            mock.patch.object(self.engine.subprocess, "Popen", side_effect=spawn),
            mock.patch.dict(sys.modules, {"_ergopti_native_http": self.engine}),
        ):
            return self.engine.NativeHTTPResponse(
                "https://private-company.invalid/model?private=payload",
                [],
                timeout=3,
                idle_timeout=3,
            )

    def report(self, function, *arguments):
        captured = io.StringIO()
        with (
            mock.patch.dict(sys.modules, {"_ergopti_native_http": self.engine}),
            contextlib.redirect_stderr(captured),
        ):
            function(*arguments)
        return captured.getvalue()

    def test_successful_transfer_names_the_step_that_gave_up(self):
        marker = "# native_http_proxy_fallback route=direct reason=native_pac_download"
        with self.open(marker, "ok") as response:
            self.assertEqual(response.route_fallback, "native_pac_download")
            self.assertEqual(response.read(), b"")
        self.assertEqual(response.route_fallback, "native_pac_download")
        self.assertEqual(
            self.report(self.reporter._report_route_fallback, response.route_fallback),
            "# managed_bootstrap_route direct_fallback=native_pac_download\n"
            "__ERGOPTI_PAC_DIRECT_FALLBACK_V1__:native_pac_download\n"
            "WARNING: The automatic network configuration could not be used"
            " (native_pac_download). Trying a direct connection.\n",
        )
        self.assertEqual(
            self.report(self.reporter._report_pac_fallback_outcome, None),
            "The direct connection worked after the automatic network configuration"
            " failed (native_pac_download).\n",
        )
        self.assertEqual(
            self.report(self.reporter._report_pac_fallback_outcome, "connect"),
            "",
            "the outcome is reported once",
        )

    def test_no_fallback_reports_no_outcome(self):
        self.assertEqual(self.report(self.reporter._report_pac_fallback_outcome, None), "")
        self.assertEqual(self.report(self.reporter._report_pac_fallback_outcome, "connect"), "")

    def test_unknown_or_private_marker_text_is_never_reported(self):
        for marker in (
            "# native_http_proxy_fallback route=direct reason=native_unapproved_stage",
            "# native_http_proxy_fallback route=direct reason=http://wpad.private-company.invalid/wpad.dat",
            "native_http_proxy_fallback route=direct reason=native_pac_download",
        ):
            with self.subTest(marker=marker):
                with self.open(marker, "ok") as response:
                    self.assertIsNone(response.route_fallback)
                    response.read()
                self.assertEqual(
                    self.report(self.reporter._report_route_fallback, response.route_fallback), ""
                )

    def test_refusal_after_a_fallback_keeps_the_step_in_the_failure_report(self):
        marker = "# native_http_proxy_fallback route=direct reason=native_pac_evaluation"
        with self.assertRaises(self.engine.NativeHTTPError) as raised:
            with self.open(marker, "fail") as response:
                response.read()
        failure = raised.exception
        self.assertEqual(failure.native_route_fallback, "native_pac_evaluation")
        text = self.report(self.reporter._report_failure, failure, failure.reason)
        self.assertIn("# managed_bootstrap_route direct_fallback=native_pac_evaluation\n", text)
        self.assertIn(
            "The automatic network configuration was unreachable (native_pac_evaluation)"
            " and the direct connection failed (connect).\n",
            text,
        )
        self.assertEqual(text.count("WARNING:"), 1, text)
        self.assertNotIn("private-company", text)


class NetworkCheckHelper(unittest.TestCase):
    """The Debug menu's network check prints closed step lines, never an address."""

    def setUp(self):
        self.helper = load("network_check_helper", MACOS / "modules/llm/managed_network_check.py")

    def lines(self, function, *arguments):
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            function(*arguments)
        return captured.getvalue().splitlines()

    def test_a_value_outside_the_closed_grammar_is_redacted(self):
        for value in ("https://pac.private-company.invalid/x.pac", "a b", "", "x" * 49):
            with self.subTest(value=value):
                self.assertEqual(
                    self.lines(self.helper.emit, "transfer", "fail", value),
                    ["step transfer fail redacted"],
                )

    def test_route_step_names_the_stage_that_made_the_transfer_go_direct(self):
        self.assertEqual(
            self.lines(self.helper.route_step, None), ["step route_lookup pass selected"]
        )
        self.assertEqual(
            self.lines(self.helper.route_step, "native_pac_download"),
            ["step route_lookup info direct_pac_download"],
        )

    def test_a_refused_trust_variable_is_not_a_route_or_tls_verdict(self):
        # Field run 2026-10-27 19:47: the worker refused SSL_CERT_FILE/SSL_CERT_DIR
        # before any lookup, and the check read "route_lookup pass selected".
        failure = Exception("certificate")
        failure.reason = "certificate"
        failure.native_diagnostic = {"stage": "native_certificate_load"}
        self.assertEqual(
            self.lines(self.helper.failure_steps, failure),
            [
                "step route_lookup skip not_reached",
                "step tls fail ssl_cert_env",
                "step transfer fail certificate",
            ],
        )

    def test_a_handshake_refusal_keeps_the_certificate_verdict(self):
        failure = Exception("certificate")
        failure.reason = "certificate"
        failure.native_diagnostic = {"stage": "native_session_terminal"}
        self.assertEqual(
            self.lines(self.helper.failure_steps, failure),
            [
                "step route_lookup pass selected",
                "step tls fail certificate",
                "step transfer fail certificate",
            ],
        )


class HostReachability(unittest.TestCase):
    """The field run's --hosts mode: one HEAD per declared host, named by its key."""

    def setUp(self):
        self.helper = load("network_check_hosts", MACOS / "modules/llm/managed_network_check.py")

    def run_hosts(self, outcomes):
        """Runs main_hosts over a stand-in transport; outcomes maps a URL to a status or a reason."""
        requests = []

        class Response:
            def __init__(self, status):
                self.status = status

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        class Bootstrap:
            @staticmethod
            def _direct_route(url):
                return False

            @staticmethod
            def _native_request(url, **options):
                requests.append((url, options["method"], options["timeout"]))
                outcome = outcomes.get(url, 200)
                if isinstance(outcome, str):
                    failure = Exception(outcome)
                    failure.reason = outcome
                    raise failure
                return Response(outcome)

        captured = io.StringIO()
        with mock.patch.object(self.helper, "load_bootstrap", return_value=Bootstrap):
            with contextlib.redirect_stdout(captured):
                self.helper.main_hosts()
        return captured.getvalue().splitlines(), requests

    def test_every_declared_host_gets_one_head_in_key_order(self):
        hosts = json.loads(
            (ROOT / "static/ergopti_plus/_shared/data/identifiers.json").read_text()
        )["hosts"]
        lines, requests = self.run_hosts({})
        paths = {"ollama_registry": "v2/"}
        self.assertEqual(
            [line.split()[1] for line in lines], ["host_" + key for key in sorted(hosts)]
        )
        self.assertEqual(
            [url for url, _, _ in requests],
            ["https://" + hosts[key] + "/" + paths.get(key, "") for key in sorted(hosts)],
        )
        self.assertTrue(all(method == "HEAD" for _, method, _ in requests))
        self.assertTrue(all(line.endswith(" pass http_200") for line in lines))

    def test_a_server_error_and_a_transport_failure_fail_their_host_only(self):
        lines, _ = self.run_hosts(
            {"https://huggingface.co/": 503, "https://registry.ollama.ai/v2/": "proxy"}
        )
        self.assertIn("step host_huggingface fail http_503", lines)
        self.assertIn("step host_ollama_registry fail proxy", lines)
        self.assertIn("step host_github pass http_200", lines)

    def test_the_registry_is_probed_at_its_api_base_where_401_proves_it(self):
        # Field run 2026-10-30 20:51: the registry root answered 503 while reachable.
        lines, _ = self.run_hosts(
            {"https://registry.ollama.ai/": 503, "https://registry.ollama.ai/v2/": 401}
        )
        self.assertIn("step host_ollama_registry pass http_401", lines)

    def test_no_line_carries_a_host_name(self):
        lines, _ = self.run_hosts({"https://github.com/": 404})
        self.assertIn("step host_github pass http_404", lines)
        for line in lines:
            self.assertNotIn(".com", line)
            self.assertNotIn(".co", line.split()[-1])


class OllamaBlobHost(unittest.TestCase):
    """The field run's --ollama-blob mode: is the registry's blob host planned?"""

    def setUp(self):
        self.helper = load("network_check_blob", MACOS / "modules/llm/managed_network_check.py")
        self.registry, self.planned = self.helper.ollama_planned_hosts()

    def run_blob(self, manifest_status=200, manifest=None, blob=(307, None)):
        """Runs main_blob over a stand-in transport; blob is (status, location)."""
        requests = []
        body = json.dumps(
            manifest if manifest is not None else {"config": {"digest": "sha256:" + "a" * 64}}
        ).encode()

        class Response:
            def __init__(self, status, headers=(), payload=b""):
                self.status, self.headers, self._payload = status, list(headers), payload

            def read(self, maximum=None):
                chunk, self._payload = self._payload, b""
                return chunk

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        class Bootstrap:
            @staticmethod
            def _direct_route(url):
                return False

            @staticmethod
            def _native_request(url, **options):
                requests.append((url, options["method"]))
                if "/manifests/" in url:
                    return Response(manifest_status, payload=body)
                status, location = blob
                return Response(status, [["Location", location]] if location else [])

        captured = io.StringIO()
        with mock.patch.object(self.helper, "load_bootstrap", return_value=Bootstrap):
            with contextlib.redirect_stdout(captured):
                self.helper.main_blob("tiny:0.5b")
        return captured.getvalue().splitlines(), requests

    def planned_blob_host(self):
        return sorted(host for host in self.planned if host != self.registry.split("://")[1])[0]

    def test_a_redirect_to_the_planned_blob_host_passes(self):
        location = (
            "https://" + self.planned_blob_host() + "/ollama/docker/registry/v2/blobs/x?sig=1"
        )
        lines, requests = self.run_blob(blob=(307, location))
        self.assertEqual(lines, ["step blob_manifest pass http_200", "step blob_host pass planned"])
        self.assertEqual(
            requests,
            [
                (self.registry + "/v2/library/tiny/manifests/0.5b", "GET"),
                (self.registry + "/v2/library/tiny/blobs/sha256:" + "a" * 64, "HEAD"),
            ],
        )

    def test_a_redirect_to_an_unplanned_host_fails_without_naming_it(self):
        lines, _ = self.run_blob(blob=(302, "https://blobs.elsewhere.example/x"))
        self.assertIn("step blob_host fail unplanned_host", lines)
        self.assertFalse(any("elsewhere" in line for line in lines))

    def test_a_refused_manifest_or_a_missing_location_fail_their_own_step(self):
        lines, requests = self.run_blob(manifest_status=404)
        self.assertEqual(
            lines, ["step blob_manifest fail http_404", "step blob_host skip no_manifest"]
        )
        self.assertEqual(len(requests), 1, "no blob request without a manifest")
        self.assertIn("step blob_host fail no_location", self.run_blob(blob=(307, None))[0])
        self.assertIn("step blob_manifest fail no_digest", self.run_blob(manifest={})[0])
        self.assertIn("step blob_host pass registry_served", self.run_blob(blob=(200, None))[0])

    def test_the_inventory_plans_the_registry_and_its_blob_host(self):
        self.assertTrue(self.registry.startswith("https://registry.ollama.ai"))
        self.assertGreaterEqual(len(self.planned), 2)


if __name__ == "__main__":
    unittest.main()
