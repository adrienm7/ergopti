# tools/diagnostics/macos_ollama_alias_selector_test.py
"""Actual sealed private files plus injected catalogue and native socket ports."""

import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


FIXTURE = load(
    "alias_selection_fixture", Path(__file__).with_name("macos_ollama_daemon_authority_test.py")
)
CALLER = load(
    "alias_selection_caller", ROOT / "static/ergopti_plus/macos/modules/llm/managed_ollama_pull.py"
)


@unittest.skipUnless(os.name == "posix", "Actual private POSIX file receiving required")
class AliasSelectionControls(unittest.TestCase):
    def setUp(self):
        self.case = FIXTURE.DaemonAuthorityControls("runTest")
        self.case.setUp()
        self.addCleanup(self.case.doCleanups)
        self.case.publish()
        old = self.case.session.directory
        new = self.case.root / "ollama-native-sessions"
        old.rename(new)
        self.case.session.directory = self.case.authority.directory = new
        self.case.session.path = new / self.case.session.name
        self.case.authority.path = new / self.case.authority.name
        self.verify_calls = []
        self.requests = []
        self.discoveries = []
        self.listener = dict(self.case.operation.listener)
        self.contract = {"binary_path": "ollama"}
        self.asset = {
            "source_commit": self.case.session_data["source_commit"],
            "binary_sha256": self.case.session_data["binary_sha256"],
            "sha256": self.case.session_data["asset_sha256"],
        }
        policy = ROOT / "static/ergopti_plus/_shared/modules/llm/managed_ollama_bootstrap.json"
        self.catalogue = json.dumps(
            {
                "repository_source_sha256": {
                    "static/ergopti_plus/_shared/modules/llm/managed_ollama_bootstrap.json": hashlib.sha256(
                        policy.read_bytes()
                    ).hexdigest()
                }
            }
        ).encode()
        self.clock = [100.0]
        self.native_refusal = None
        self.control = self

        def discover(*arguments, source_alias=None):
            self.discoveries.append((arguments, source_alias))
            return dict(self.listener)

        def open_request(*arguments, source_alias=None):
            self.requests.append((arguments, source_alias))
            return "admitted-request"

        self.ports = SimpleNamespace(
            discover=discover, open_request=open_request, ENGINE=CALLER.PORTS.ENGINE
        )

        class AdmissionOwner:
            def __init__(owned, session, executable, ports, idle, maximum):
                owned.session, owned.executable, owned.ports = session, executable, ports
                owned.budget = None

            def admit(owned, remaining):
                owned.budget = remaining
                observed = owned.ports.discover(
                    owned.executable,
                    owned.session["device"],
                    owned.session["inode"],
                    11434,
                    remaining,
                    60,
                )
                owned.ports.open_request(
                    owned.executable,
                    owned.session["device"],
                    owned.session["inode"],
                    11434,
                    observed,
                    "GET",
                    "/api/ergopti-native-http",
                    (),
                    b"",
                    remaining,
                    60,
                )

        self.owner_type = AdmissionOwner

    def verify(self, *arguments, **options):
        self.verify_calls.append((arguments, options))
        if not options:
            raise CALLER.RUNTIME.POLICY.RuntimeRefusal("runtime")
        if self.native_refusal:
            raise CALLER.RUNTIME.POLICY.RuntimeRefusal(self.native_refusal)
        self.clock[0] += 1.5
        return self.case.binary

    def select(self):
        with (
            patch.object(
                CALLER.RUNTIME,
                "inputs",
                return_value=(
                    b"contract",
                    self.catalogue,
                    "macos-arm64",
                    self.contract,
                    self.asset,
                ),
            ),
            patch.object(CALLER.RUNTIME, "owned_directory", return_value=self.case.runtime),
            patch.object(CALLER.RUNTIME, "native_verify", side_effect=self.verify),
            patch.object(
                CALLER.RUNTIME.POLICY,
                "receipt",
                return_value={"source": "injected native qualification"},
            ),
            patch.object(CALLER.PULL, "PullOwner", self.owner_type),
            patch.object(CALLER, "PORTS", self.ports),
            patch.object(CALLER.time, "monotonic", side_effect=lambda: self.clock[0]),
        ):
            return CALLER.select_owner({"port": 11434}, 102.0, 60, 65536)

    def test_real_sealed_source_requalifies_catalogue_and_original_socket_before_request(self):
        owner = self.select()
        self.assertEqual(len(self.verify_calls), 2)
        self.assertEqual(
            self.verify_calls[1][1],
            {
                "source_alias": self.case.alias.proof,
                "source_identity": {
                    key: self.case.session_data[key] for key in ("device", "inode")
                },
            },
        )
        self.assertEqual(owner.source_alias, self.case.alias.proof)
        self.assertEqual(owner.budget, 0.5)
        self.assertEqual(len(self.discoveries), 1)
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.discoveries[0][1], self.case.alias.proof)
        self.assertEqual(self.requests[0][1], self.case.alias.proof)
        self.assertEqual(owner.session, self.case.session_data)

    def test_different_start_refuses_before_any_private_request(self):
        self.listener["start_microseconds"] = "457"
        with self.assertRaises(CALLER.SESSIONS.POLICY.RuntimeRefusal):
            self.select()
        self.assertEqual(len(self.discoveries), 1)
        self.assertEqual(self.requests, [])

    def test_alias_catalogue_refusal_never_contacts_listener(self):
        self.native_refusal = "signature"
        with self.assertRaises(CALLER.SESSIONS.POLICY.RuntimeRefusal):
            self.select()
        self.assertEqual(self.discoveries, [])
        self.assertEqual(self.requests, [])

    def test_unsealed_or_changed_source_sidecar_never_requalifies_or_contacts(self):
        original = self.case.authority.path.read_bytes()
        self.case.authority.path.write_bytes(b"{}")
        try:
            with self.assertRaises(CALLER.SESSIONS.POLICY.RuntimeRefusal):
                self.select()
            self.assertEqual(len(self.verify_calls), 1)
            self.assertEqual(self.discoveries, [])
            self.assertEqual(self.requests, [])
        finally:
            self.case.authority.path.write_bytes(original)

    def test_initial_signature_refusal_does_not_try_alias_claims(self):
        def refuse(*arguments, **options):
            self.verify_calls.append((arguments, options))
            raise CALLER.RUNTIME.POLICY.RuntimeRefusal("signature")

        self.verify = refuse
        with self.assertRaises(CALLER.RUNTIME.POLICY.RuntimeRefusal):
            self.select()
        self.assertEqual(len(self.verify_calls), 1)
        self.assertEqual(self.discoveries, [])
        self.assertEqual(self.requests, [])

    def test_original_deadline_exhausted_by_native_source_check_sends_no_private_header(self):
        actual = self.verify

        def delayed(*arguments, **options):
            result = actual(*arguments, **options)
            self.clock[0] += 1
            return result

        self.verify = delayed
        with self.assertRaises(CALLER.SESSIONS.POLICY.RuntimeRefusal):
            self.select()
        self.assertEqual(self.discoveries, [])
        self.assertEqual(self.requests, [])

    def test_shared_port_refuses_foreign_expected_tuple_before_native_request(self):
        authority = {"source_alias": self.case.alias.proof, "listener": self.listener}
        bound = FIXTURE.AUTH.POLICY.BoundAliasPorts(
            self.ports, authority, self.case.session_data, os.geteuid()
        )
        with self.assertRaises(FIXTURE.AUTH.POLICY.AuthorityRefusal):
            bound.open_request("source", "1", "2", 11434, self.listener | {"pid": 1})
        self.assertEqual(self.requests, [])

    def test_unknown_reader_close_never_tries_a_second_real_private_pair(self):
        directory = self.case.session.directory
        daemon = directory / ("daemon-" + "0" * 32 + ".json")
        sidecar = directory / ("source-" + "0" * 32 + ".json")
        daemon.write_bytes(self.case.session._written)
        sidecar.write_bytes(self.case.authority._written)
        daemon.chmod(0o600)
        sidecar.chmod(0o600)
        native_close = os.close
        uncertain = []

        def close(descriptor):
            native_close(descriptor)
            caller = sys._getframe(1)
            if caller.f_code.co_name == "read_pair" and not uncertain:
                uncertain.append(descriptor)
                raise OSError("independent physical-close uncertainty")

        try:
            with patch.object(os, "close", close):
                with self.assertRaises(RuntimeError) as observed:
                    self.select()
            self.assertIsInstance(observed.exception.cleanup, OSError)
            self.assertEqual(len(uncertain), 1)
            with self.assertRaises(OSError):
                os.fstat(uncertain[0])
            self.assertEqual(len(self.verify_calls), 1)
            self.assertEqual(self.discoveries, [])
            self.assertEqual(self.requests, [])
            self.assertEqual(daemon.read_bytes(), self.case.session._written)
            self.assertEqual(sidecar.read_bytes(), self.case.authority._written)
        finally:
            daemon.unlink()
            sidecar.unlink()


if __name__ == "__main__":
    unittest.main()
