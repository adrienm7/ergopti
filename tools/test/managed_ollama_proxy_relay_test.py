# tools/test/managed_ollama_proxy_relay_test.py
"""The macOS managed daemon's sign-in relay decision, with injected processes.

docs/design/proxy-auth-relay.md, "macOS managed daemon". The probe reader is
pinned to the shared vectors the Go relay and the Lua policy read; the decision
and the snapshot rewrite run against real files and the real shared policy.
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

ROOT = Path(__file__).resolve().parents[2]
STATIC = ROOT / "static/ergopti_plus"


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


POLICY = load(
    "relay_policy_under_test", STATIC / "_shared/core/network/adapters/python_proxy_auth_relay.py"
)
RELAY = load(
    "managed_relay_under_test", STATIC / "macos/ai/engine/ollama/managed_ollama_proxy_relay.py"
)
PROXY = load(
    "relay_proxy_policy", STATIC / "_shared/core/network/adapters/python_network_proxy_policy.py"
)
BOOT = load("relay_bootstrap", STATIC / "_shared/ai/adapters/python/managed_ollama_bootstrap.py")
VECTORS = json.loads(
    (STATIC / "_shared/tests/corpus/network/proxy_auth_relay_probe_vectors.json").read_text(
        encoding="utf-8"
    )
)["vectors"]
TOKEN = "0123456789abcdef" * 4
HTTPS_ORDER = PROXY.ProxyPolicy().orders["https"]


class Completed:
    def __init__(self, code, stdout):
        self.returncode, self.stdout = code, stdout.encode()


class ProbeReaderTests(unittest.TestCase):
    def test_every_shared_vector_reads_as_the_lua_policy_reads_it(self):
        policy = POLICY.ProxyAuthRelay()
        for vector in VECTORS:
            with self.subTest(vector["id"]):
                code = vector["exit_code"] if vector["exit_code"] >= 0 else None
                status, detail = policy.read_probe(code, vector["stdout"])
                if "result" in vector:
                    self.assertEqual(status, vector["result"]["status"])
                    self.assertEqual(detail, vector["result"].get("scheme"))
                else:
                    self.assertEqual((status, detail), ("refused", vector["reason"]))

    def test_only_a_plain_http_proxy_without_credentials_is_probed(self):
        upstream = POLICY.ProxyAuthRelay.upstream
        self.assertEqual(
            upstream("http://Proxy.Corp.example:8080/"), "http://proxy.corp.example:8080"
        )
        for value in (
            "http://user:secret@proxy:8080",
            "https://proxy:8080",
            "socks5://proxy:1080",
            "http://proxy",
            "http://proxy:0",
            "http://proxy:65536",
            "http://pro xy:8080",
            None,
        ):
            self.assertIsNone(upstream(value), value)
        self.assertEqual(
            POLICY.ProxyAuthRelay.authority("https://registry.ollama.ai"), "registry.ollama.ai:443"
        )
        self.assertIsNone(POLICY.ProxyAuthRelay.authority("http://registry.ollama.ai"))


@unittest.skipUnless(os.name == "posix", "the receipt and launcher paths are POSIX paths")
class DecisionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.launcher = self.root / "ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
        self.launcher.parent.mkdir(parents=True)
        self.relay = self.launcher.parent / "ergopti-proxy-relay"
        self.relay.write_text("#!/bin/sh\n")
        self.relay.chmod(0o755)
        self.receipt = self.root / "caches/proxy_relay_refusal"
        self.options = RELAY.RelayOptions(
            str(self.receipt), "registry.ollama.ai:443", 10000, 15000, 300000, 30000
        )
        self.calls = []

    def decide(self, environment, answer):
        def run(arguments, **keywords):
            self.calls.append((arguments, keywords))
            if isinstance(answer, BaseException):
                raise answer
            return answer

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            decision = RELAY.decide(
                self.options, environment, HTTPS_ORDER, str(self.launcher), run=run
            )
        self.log = stderr.getvalue()
        return decision

    def test_a_route_the_relay_cannot_sign_in_to_is_kept_without_a_probe(self):
        for environment in (
            [],
            [["HTTPS_PROXY", "http://user:secret@proxy:8080"]],
            [["https_proxy", "socks5://proxy:1080"]],
        ):
            self.assertEqual(self.decide(environment, None).outcome, "keep")
        self.assertEqual(self.calls, [])
        self.assertEqual(self.log, "")

    def test_a_missing_relay_keeps_the_proxy_with_one_warning(self):
        self.relay.unlink()
        decision = self.decide([["HTTPS_PROXY", "http://proxy:8080"]], None)
        self.assertEqual(decision.outcome, "keep")
        self.assertEqual(self.log, "Managed Ollama proxy sign-in relay: not_installed.\n")

    def test_not_needed_keeps_the_snapshot(self):
        decision = self.decide(
            [["HTTPS_PROXY", "http://proxy:8080"]],
            Completed(0, '{"schema":1,"status":"not_needed"}\n'),
        )
        self.assertEqual(decision.outcome, "keep")
        self.assertEqual(
            self.calls[0][0],
            [
                str(self.relay),
                "probe",
                "--upstream",
                "http://proxy:8080",
                "--authority",
                "registry.ollama.ai:443",
                "--dial-timeout-ms",
                "10000",
                "--handshake-timeout-ms",
                "15000",
            ],
        )
        self.assertEqual(self.calls[0][1]["timeout"], 30)
        self.assertFalse(self.receipt.exists())

    def test_required_names_the_selected_variable_and_the_request_fields(self):
        environment = [["HTTPS_PROXY", "http://other:1"], ["https_proxy", "http://proxy:8080/"]]
        decision = self.decide(
            environment, Completed(0, '{"schema":1,"status":"required","scheme":"negotiate"}\n')
        )
        self.assertEqual(
            (decision.outcome, decision.name, decision.upstream),
            ("required", "https_proxy", "http://proxy:8080"),
        )
        self.assertEqual(
            decision.request_fields(self.options),
            {
                "relay_upstream": "http://proxy:8080",
                "relay_dial_ms": 10000,
                "relay_handshake_ms": 15000,
                "relay_idle_ms": 300000,
            },
        )
        self.assertEqual(self.log, "Managed Ollama proxy sign-in relay: required negotiate.\n")
        self.assertNotIn("proxy:8080", self.log)

    def test_a_refusal_writes_the_receipt_and_removes_an_old_one_first(self):
        self.receipt.parent.mkdir(parents=True)
        self.receipt.write_text("sign_in_rejected\n")
        self.decide(
            [["HTTPS_PROXY", "http://proxy:8080"]],
            Completed(0, '{"schema":1,"status":"not_needed"}\n'),
        )
        self.assertFalse(self.receipt.exists(), "a receipt names the daemon of its own start")
        decision = self.decide(
            [["HTTPS_PROXY", "http://proxy:8080"]],
            Completed(3, '{"schema":1,"status":"refused","reason":"sign_in_unavailable"}\n'),
        )
        self.assertEqual((decision.outcome, decision.reason), ("refused", "sign_in_unavailable"))
        self.assertEqual(self.receipt.read_text(), "sign_in_unavailable\n")
        self.assertEqual(
            self.log, "Managed Ollama proxy sign-in relay: refused sign_in_unavailable.\n"
        )

    def test_a_probe_that_does_not_answer_is_relay_unavailable(self):
        for answer in (
            subprocess.TimeoutExpired("probe", 30),
            OSError("exec"),
            Completed(0, "garbage"),
        ):
            decision = self.decide([["HTTPS_PROXY", "http://proxy:8080"]], answer)
            self.assertEqual(decision.reason, "relay_unavailable")
            self.assertEqual(self.receipt.read_text(), "relay_unavailable\n")

    def test_the_startup_clock_bounds_the_probe(self):
        def run(arguments, **keywords):
            self.calls.append(keywords)
            return Completed(0, '{"schema":1,"status":"not_needed"}\n')

        with contextlib.redirect_stderr(io.StringIO()):
            RELAY.decide(
                self.options,
                [["HTTPS_PROXY", "http://proxy:8080"]],
                HTTPS_ORDER,
                str(self.launcher),
                remaining=2.5,
                run=run,
            )
        self.assertEqual(self.calls[0]["timeout"], 2.5)

    def test_options_refuse_what_the_relay_cannot_take(self):
        for arguments in (
            ("relative/receipt", "registry.ollama.ai:443", 1, 1, 1, 1),
            ("/a/../receipt", "registry.ollama.ai:443", 1, 1, 1, 1),
            ("/receipt", "registry.ollama.ai:80", 1, 1, 1, 1),
            ("/receipt", "user@registry.ollama.ai:443", 1, 1, 1, 1),
            ("/receipt", "registry.ollama.ai:443", 0, 1, 1, 1),
            ("/receipt", "registry.ollama.ai:443", 1, 1, 1.5, 1),
        ):
            with self.assertRaises(ValueError, msg=str(arguments)):
                RELAY.RelayOptions(*arguments)

    def test_route_carries_the_relay_user_and_token(self):
        self.assertEqual(RELAY.route(40123, TOKEN), "http://ergopti:%s@127.0.0.1:40123" % TOKEN)


class SnapshotTests(unittest.TestCase):
    def snapshot(self, environment):
        policy = BOOT.BootstrapPolicy(
            STATIC / "_shared/ai/data/managed_ollama_bootstrap.json", PROXY.ProxyPolicy()
        )
        payload = BOOT.encode(
            {
                "environment": environment,
                "store": {"mode": "default", "value": "", "cwd": "/"},
                "idle_timeout_ms": 1000,
            }
        )
        return BOOT.NetworkSnapshot(policy, payload, {"mode": "default", "value": "", "cwd": "/"})

    def test_the_relay_route_replaces_only_the_selected_proxy(self):
        original = self.snapshot(
            [["https_proxy", "http://proxy:8080"], ["NO_PROXY", "corp.example"]]
        )
        relayed = original.with_environment({"https_proxy": RELAY.route(40123, TOKEN)})
        self.assertEqual(
            relayed.environment(),
            [["https_proxy", RELAY.route(40123, TOKEN)], ["NO_PROXY", "corp.example"]],
        )
        self.assertEqual(original.environment()[0], ["https_proxy", "http://proxy:8080"])

    def test_a_refusal_removes_every_proxy_and_keeps_the_bypass(self):
        names = PROXY.ProxyPolicy().system_lookup_environment_exclusions
        original = self.snapshot(
            [["HTTPS_PROXY", "http://proxy:8080"], ["ALL_PROXY", "http://p:1"], ["no_proxy", "x"]]
        )
        cleared = original.with_environment({name: None for name in names})
        self.assertEqual(cleared.environment(), [["no_proxy", "x"]])

    def test_a_name_the_policy_does_not_capture_is_refused(self):
        original = self.snapshot([])
        for changes in ({"PATH": "/bin"}, {"https_proxy": "a\0b"}, {"https_proxy": 1}, []):
            with self.assertRaises(BOOT.BootstrapRefusal):
                original.with_environment(changes)


if __name__ == "__main__":
    unittest.main()
