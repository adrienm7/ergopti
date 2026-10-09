#!/usr/bin/env python3
# tools/diagnostics/program_actions/test_permission_observation.py
"""Independent closed diagnostic vectors; no native consent or catalogue claim."""

import base64
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

from permission_observation import OPERATION, PermissionProtocol, PermissionQuery
from run_signed_query_probe import QueryProtocol, Refused, SignedQuery


def packet():
    return {
        "version": 1,
        "nonce": 19,
        "operation": "permission-observation",
        "observation": "native-returned",
        "target": "shortcuts-events",
        "event_class": "core",
        "event_id": "getd",
        "ask_user": False,
        "osstatus": -1744,
    }


def transcript(raw, receipt=b"Q1 RETIRED 0\n", pending=b""):
    return b"Q1 HELD\nQ1 DATA " + base64.b64encode(raw) + b"\n" + pending + receipt


def protocol(value=None, raw=None, **options):
    result = PermissionProtocol()
    result.feed(
        transcript(json.dumps(value or packet()).encode() if raw is None else raw, **options)
    )
    return result


class PermissionObservationControls(unittest.TestCase):
    def test_all_native_codes_are_metadata_only(self):
        for code in (0, -600, -1743, -1744, -2147483648, 2147483647):
            with self.subTest(code=code):
                value = packet()
                value["osstatus"] = code
                observed = protocol(value).decode(OPERATION, 19)
                self.assertEqual(observed, value)
                self.assertNotIn("status", observed)
                self.assertNotIn("rows", observed)
                self.assertNotIn("permission_granted", observed)

    def test_address_failure_is_distinct_and_nonzero(self):
        value = packet()
        value.update(observation="address-refused", osstatus=-50)
        self.assertEqual(protocol(value).decode(OPERATION, 19), value)
        value["osstatus"] = 0
        with self.assertRaises(Refused):
            protocol(value).decode(OPERATION, 19)

    def test_closed_schema_refuses_every_missing_key_and_extra_business_data(self):
        for key in packet():
            value = packet()
            del value[key]
            with self.subTest(missing=key), self.assertRaises(Refused):
                protocol(value).decode(OPERATION, 19)
        for key, extra in (
            ("rows", []),
            ("status", "observed"),
            ("reason", "native_refused"),
            ("message", "private"),
        ):
            value = packet()
            value[key] = extra
            with self.subTest(extra=key), self.assertRaises(Refused):
                protocol(value).decode(OPERATION, 19)

    def test_prompt_target_event_role_and_status_domains_are_closed(self):
        changes = {
            "ask_user": [True, 0, "false", None],
            "target": ["other", "com.apple.shortcuts.events"],
            "event_class": ["****", "aevt"],
            "event_id": ["****", "run "],
            "observation": ["granted", "unknown", None],
            "operation": ["discover", "invoke"],
            "nonce": [True, 18, "19", 19.5],
            "version": [True, 2, "1", 1.5],
            "osstatus": [True, False, "0", 0.5, -2147483649, 2147483648, None],
        }
        for key, values in changes.items():
            for change in values:
                value = packet()
                value[key] = change
                with self.subTest(key=key, value=change), self.assertRaises(Refused):
                    protocol(value).decode(OPERATION, 19)

    def test_no_payload_is_visible_before_exact_retirement(self):
        held = protocol(receipt=b"")
        with self.assertRaises(Refused):
            held.decode(OPERATION, 19)
        held.feed(b"Q1 RETIRED 0\n")
        self.assertEqual(held.decode(OPERATION, 19), packet())
        for options in (
            {"receipt": b"Q1 RETIRED 137\n"},
            {"pending": b"Q1 PENDING 0\n"},
        ):
            with self.subTest(options=options), self.assertRaises(Refused):
                protocol(**options).decode(OPERATION, 19)
        buffered = protocol()
        buffered.feed(b"x")
        with self.assertRaises(Refused):
            buffered.decode(OPERATION, 19)

    def test_wire_limits_duplicates_and_utf8_remain_closed(self):
        for raw in (b"\xff", b"[]", b'{"version":1,"version":1}', b"{}" + b" " * 65535):
            with self.subTest(bytes=len(raw)), self.assertRaises(Refused):
                protocol(raw=raw).decode(OPERATION, 19)
        with self.assertRaises(Refused):
            PermissionProtocol().feed(b"x" * 90001)
        repeated = protocol()
        with self.assertRaises(Refused):
            repeated.feed(b"Q1 RETIRED 0\n")

    def test_business_decoder_and_diagnostic_decoder_are_disjoint(self):
        raw = json.dumps(packet()).encode()
        business = QueryProtocol()
        business.feed(transcript(raw))
        with self.assertRaises(Refused):
            business.decode(OPERATION, 19)
        business_value = {
            "version": 1,
            "nonce": 19,
            "operation": "discover",
            "status": "observed",
            "rows": [],
            "truncated": False,
        }
        with self.assertRaises(Refused):
            protocol(business_value).decode(OPERATION, 19)
        self.assertIs(PermissionProtocol.feed, QueryProtocol.feed)

    def test_invalid_request_cannot_acquire_any_native_group(self):
        query = PermissionQuery("admitted-by-caller-only", None, None)
        with patch.object(SignedQuery, "query", side_effect=AssertionError("native acquisition")):
            for nonce in (True, 0, -1, 9007199254740992, "19", 19.5):
                with self.subTest(nonce=nonce), self.assertRaises(Refused):
                    query.observe(nonce)
            with self.assertRaises(Refused):
                query.query("discover", 19)
            with self.assertRaises(Refused):
                query.query(OPERATION, 19, identifier="arbitrary")

    def test_fixed_observation_reuses_the_original_custody_call(self):
        query = PermissionQuery("admitted-by-caller-only", None, None)
        with patch.object(SignedQuery, "query", return_value=packet()) as original:
            self.assertEqual(query.observe(19, cancel_held=True), packet())
            original.assert_called_once_with(OPERATION, 19, cancel_held=True)
        self.assertIsInstance(query._make_protocol(), PermissionProtocol)
        self.assertIsInstance(SignedQuery("owned", None, None)._make_protocol(), QueryProtocol)
        self.assertIs(PermissionQuery.acquire, SignedQuery.acquire)
        self.assertIs(PermissionQuery.cancel, SignedQuery.cancel)

    def test_actual_controlled_pipe_preserves_capture_and_retirement(self):
        from test_signed_query_probe import ControlledGroup

        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / "owned-metadata-fixture"
            script = "#!" + sys.executable + "\nimport base64,json,sys\n"
            script += "print('Q1 HELD',flush=True)\ncommand=sys.stdin.readline()\n"
            script += "assert sys.argv[1:] == ['--automation-query-worker','permission-observation','19']\n"
            script += "if command == 'ACTIVATE\\n':\n"
            script += "    packet=" + repr(packet()) + "\n"
            script += "    print('Q1 DATA '+base64.b64encode(json.dumps(packet).encode()).decode(),flush=True)\n"
            script += "    print('Q1 RETIRED 0',flush=True)\n"
            script += "else:\n    print('Q1 RETIRED 15',flush=True)\n"
            helper.write_text(script)
            helper.chmod(0o700)
            query = PermissionQuery(
                helper, types.SimpleNamespace(OwnedProcessGroup=ControlledGroup), object()
            )
            try:
                self.assertEqual(query.observe(19), packet())
                self.assertIsNone(query.group)
                self.assertTrue(query.receipts[0]["inner_retired"])
                self.assertEqual(query.receipts[0]["outer_owner"]["signals"], [])
                self.assertIsNone(query.observe(19, cancel_held=True))
                self.assertIsNone(query.group)
                self.assertTrue(query.receipts[1]["cancel_requested"])
                self.assertEqual(query.receipts[1]["payload_bytes"], 0)
                self.assertEqual(query.receipts[1]["outer_owner"]["signals"], [])
            finally:
                if query.group is not None:
                    query.cancel()
                    query.group.process.wait(timeout=2)


class PermissionAdmissionControls(unittest.TestCase):
    def fixture(self, raw=None):
        import hashlib
        import run_signed_query_probe as probe

        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        relative = "tools/diagnostics/program_actions/permission_observation.py"
        target = root / relative
        target.parent.mkdir(parents=True)
        raw = (
            Path(__file__).with_name("permission_observation.py").read_bytes()
            if raw is None
            else raw
        )
        target.write_bytes(raw)
        return probe, root, target, relative, raw, {relative: hashlib.sha256(raw).hexdigest()}

    def test_verified_bytes_bind_original_custody_and_restore_module(self):
        probe, root, target, relative, raw, hashes = self.fixture()
        before = sys.modules.get("run_signed_query_probe")
        with patch.object(probe.subprocess, "check_output", return_value=raw):
            constructor = probe.load_permission_query(root, "a" * 40, hashes)
        self.assertTrue(issubclass(constructor, SignedQuery))
        self.assertIs(constructor.acquire, SignedQuery.acquire)
        self.assertIs(constructor.cancel, SignedQuery.cancel)
        self.assertIs(sys.modules.get("run_signed_query_probe"), before)
        with self.assertRaises(Refused):
            constructor("unused", None, None).observe(0)

    def test_prior_module_membership_and_value_survive_success_and_execution_exception(self):
        key = "run_signed_query_probe"
        original = sys.modules[key]
        for state in ("absent", "existing", "blocked-none"):
            for raises in (False, True):
                with self.subTest(state=state, raises=raises):
                    raw = (
                        b'raise RuntimeError("admitted controlled code exception")\n'
                        if raises
                        else None
                    )
                    probe, root, target, relative, raw, hashes = self.fixture(raw)
                    expected = original if state == "existing" else None
                    if state == "absent":
                        del sys.modules[key]
                    else:
                        sys.modules[key] = expected
                    try:
                        with patch.object(probe.subprocess, "check_output", return_value=raw):
                            if raises:
                                with self.assertRaisesRegex(
                                    RuntimeError, "admitted controlled code exception"
                                ):
                                    probe.load_permission_query(root, "a" * 40, hashes)
                            else:
                                constructor = probe.load_permission_query(root, "a" * 40, hashes)
                                self.assertTrue(issubclass(constructor, SignedQuery))
                                self.assertIs(constructor.acquire, SignedQuery.acquire)
                                self.assertIs(constructor.cancel, SignedQuery.cancel)
                        self.assertEqual(key in sys.modules, state != "absent")
                        if state != "absent":
                            self.assertIs(sys.modules[key], expected)
                    finally:
                        sys.modules[key] = original

    def test_missing_receipt_hash_refuses_before_code_execution(self):
        probe, root, target, relative, raw, hashes = self.fixture(
            b'raise AssertionError("unverified decoder executed")'
        )
        with (
            patch.object(probe.subprocess, "check_output", return_value=raw),
            self.assertRaisesRegex(Refused, "source_refused"),
        ):
            probe.load_permission_query(root, "a" * 40, {})

    def test_tracked_and_current_hash_mismatch_refuse_before_execution(self):
        probe, root, target, relative, raw, hashes = self.fixture(
            b'raise AssertionError("unverified decoder executed")'
        )
        with (
            patch.object(probe.subprocess, "check_output", return_value=b"different tracked bytes"),
            self.assertRaisesRegex(Refused, "source_refused"),
        ):
            probe.load_permission_query(root, "a" * 40, hashes)
        hashes[relative] = "0" * 64
        with (
            patch.object(probe.subprocess, "check_output", return_value=raw),
            self.assertRaisesRegex(Refused, "source_refused"),
        ):
            probe.load_permission_query(root, "a" * 40, hashes)

    def test_linked_decoder_refuses_even_when_bytes_hash_and_git_match(self):
        probe, root, target, relative, raw, hashes = self.fixture()
        real = root / "retained-decoder"
        target.rename(real)
        target.symlink_to(real)
        with (
            patch.object(probe.subprocess, "check_output", return_value=raw),
            self.assertRaisesRegex(Refused, "source_refused"),
        ):
            probe.load_permission_query(root, "a" * 40, hashes)

    def test_source_census_explicitly_enrolls_decoder_and_independent_tests(self):
        import run_signed_query_probe as probe

        native = "static/ergopti_plus/macos/launcher/Sources/Main.swift"
        with patch.object(probe.subprocess, "check_output", return_value=(native + "\n").encode()):
            selected = probe.source_paths(Path("unused"), "a" * 40)
        self.assertEqual(
            set(selected),
            {
                native,
                "tools/diagnostics/program_actions/run_signed_query_probe.py",
                "tools/diagnostics/program_actions/permission_observation.py",
                "tools/diagnostics/program_actions/test_permission_observation.py",
                "tools/diagnostics/macos_owned_process.py",
                "static/ergopti_plus/macos/adapters/apple_shortcuts_native.lua",
                "static/ergopti_plus/macos/adapters/apple_shortcuts.lua",
            },
        )


class PermissionMainAdmissionControls(unittest.TestCase):
    def run_probe(
        self,
        cancel=False,
        invalid_receipt=False,
        invalid_signature=False,
        change_helper=False,
        change_source=False,
    ):
        import contextlib
        import hashlib
        import io
        import os
        import run_signed_query_probe as probe
        from test_signed_query_probe import ControlledGroup

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_root = Path(__file__).parent
            inputs = {}
            for relative in (
                "tools/diagnostics/program_actions/run_signed_query_probe.py",
                "tools/diagnostics/program_actions/permission_observation.py",
                "tools/diagnostics/program_actions/test_permission_observation.py",
            ):
                inputs[relative] = (source_root / Path(relative).name).read_bytes()
            # Controlled direct-child owner has no descendants; no Darwin ABI proof.
            import inspect

            owner_code = (
                inspect.getsource(ControlledGroup)
                + "\nOwnedProcessGroup = ControlledGroup\ndef NativeProcessGroups(): return object()\n"
            )
            inputs["tools/diagnostics/macos_owned_process.py"] = (
                "import os\n" + owner_code
            ).encode()
            for relative in (
                "static/ergopti_plus/macos/adapters/apple_shortcuts.lua",
                "static/ergopti_plus/macos/adapters/apple_shortcuts_native.lua",
            ):
                inputs[relative] = b"controlled tracked adapter"
            native = "static/ergopti_plus/macos/launcher/Sources/Main.swift"
            inputs[native] = b"controlled tracked native input"
            for relative, raw in inputs.items():
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(raw)
            app = root / "Bound.app"
            helper = app / "Contents/MacOS/ErgoptiAutomationQuery"
            helper.parent.mkdir(parents=True)
            script = (
                "#!" + sys.executable + "\nimport base64,json,sys\nprint('Q1 HELD',flush=True)\n"
            )
            script += "command=sys.stdin.readline()\nif command == 'ACTIVATE\\n':\n"
            script += (
                "    if sys.argv[2] == 'permission-observation':\n        packet="
                + repr(dict(packet(), nonce=3, osstatus=0))
                + "\n"
            )
            script += "    else:\n        packet={'version':1,'nonce':int(sys.argv[3]),'operation':'discover','status':'refused','reason':'automation_permission_refused'}\n"
            script += "    print('Q1 DATA '+base64.b64encode(json.dumps(packet).encode()).decode(),flush=True)\n    print('Q1 RETIRED 0',flush=True)\n"
            script += "else:\n    print('Q1 RETIRED 15',flush=True)\n"
            if change_helper:
                script += "if sys.argv[2] == 'permission-observation':\n    from pathlib import Path\n    p=Path(__file__)\n    p.write_bytes(p.read_bytes()+b'\\n')\n"
            if change_source:
                decoder = root / "tools/diagnostics/program_actions/permission_observation.py"
                script += (
                    "if sys.argv[2] == 'permission-observation':\n    from pathlib import Path\n    p=Path("
                    + repr(str(decoder))
                    + ")\n    p.write_bytes(p.read_bytes()+b'\\n')\n"
                )
            helper.write_text(script)
            helper.chmod(0o700)
            hashes = {relative: hashlib.sha256(raw).hexdigest() for relative, raw in inputs.items()}
            receipt = {
                "schema": 1,
                "contract": "signed-native-query-build",
                "source_sha": "a" * 40,
                "source_hashes": hashes,
                "helper_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
                "ci_run_id": "17",
                "ci_run_attempt": "2",
            }
            if invalid_receipt:
                receipt["source_hashes"] = dict(hashes)
                del receipt["source_hashes"][
                    "tools/diagnostics/program_actions/permission_observation.py"
                ]
            resource = app / "Contents/Resources/automation-query-build.json"
            resource.parent.mkdir(parents=True)
            resource.write_text(json.dumps(receipt))
            output = root / "observation"
            arguments = [
                "probe",
                "--source-root",
                str(root),
                "--source-sha",
                "a" * 40,
                "--app",
                str(app),
                "--output",
                str(output),
                "--build-receipt",
                str(resource),
            ]
            if cancel:
                arguments.append("--cancel-held")

            def git(arguments, **options):
                if arguments == ["git", "rev-parse", "HEAD"]:
                    return b"a" * 40 + b"\n"
                if arguments[:2] == ["git", "ls-tree"]:
                    return (native + "\n").encode()
                if arguments[:2] == ["git", "show"]:
                    return inputs[arguments[2].split(":", 1)[1]]
                raise AssertionError("unexpected authentication command")

            with (
                patch.object(probe.sys, "platform", "darwin"),
                patch.object(probe.sys, "version_info", (3, 13)),
                patch.object(probe.sys, "argv", arguments),
                patch.dict(
                    os.environ,
                    {"GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "17", "GITHUB_RUN_ATTEMPT": "2"},
                ),
                patch.object(probe.subprocess, "check_output", side_effect=git),
                patch.object(
                    probe.subprocess,
                    "run",
                    return_value=types.SimpleNamespace(returncode=1 if invalid_signature else 0),
                ),
                patch.object(
                    probe, "load_permission_query", wraps=probe.load_permission_query
                ) as load,
                contextlib.redirect_stdout(io.StringIO()),
            ):
                result = probe.main()
            return result, json.loads((output / "observation.json").read_bytes()), load.call_count

    def test_main_admits_metadata_without_forgiving_business_permission_refusal(self):
        code, observed, calls = self.run_probe()
        self.assertEqual(code, 1)
        self.assertEqual(calls, 1)
        self.assertEqual(observed["result"], "REFUSED")
        self.assertEqual(observed["reason"], "automation_permission_refused")
        self.assertFalse(observed["native_query_observed"])
        self.assertFalse(observed["service_invocation_available"])
        self.assertTrue(observed["sdk_permission_observation"]["local_retired"])
        self.assertEqual(observed["sdk_permission_observation"]["metadata"]["osstatus"], 0)
        self.assertTrue(observed["local_retired"])
        self.assertEqual(
            observed["sdk_permission_observation"]["operations"][0]["outer_owner"]["signals"], []
        )

    def test_original_cancel_held_skips_new_diagnostic(self):
        code, observed, calls = self.run_probe(cancel=True)
        self.assertEqual(code, 2)
        self.assertEqual(calls, 0)
        self.assertNotIn("sdk_permission_observation", observed)
        self.assertTrue(observed["local_cancellation_observed"])
        self.assertTrue(observed["local_retired"])
        self.assertEqual(observed["operations"][0]["outer_owner"]["signals"], [])

    def test_missing_decoder_receipt_hash_blocks_import_and_native_acquisition(self):
        code, observed, calls = self.run_probe(invalid_receipt=True)
        self.assertEqual(code, 1)
        self.assertEqual(calls, 0)
        self.assertEqual(observed["reason"], "build_provenance_refused")
        self.assertNotIn("sdk_permission_observation", observed)
        self.assertNotIn("operations", observed)

    def test_signature_refusal_blocks_import_and_native_acquisition(self):
        code, observed, calls = self.run_probe(invalid_signature=True)
        self.assertEqual(code, 1)
        self.assertEqual(calls, 0)
        self.assertEqual(observed["reason"], "signature_refused")
        self.assertNotIn("sdk_permission_observation", observed)
        self.assertNotIn("operations", observed)

    def test_helper_change_during_query_refuses_metadata_publication(self):
        code, observed, calls = self.run_probe(change_helper=True)
        self.assertEqual(code, 1)
        self.assertEqual(calls, 1)
        self.assertEqual(observed["reason"], "identity_refused")
        self.assertNotIn("sdk_permission_observation", observed)
        self.assertFalse(observed["native_query_observed"])

    def test_source_change_during_query_refuses_metadata_publication(self):
        code, observed, calls = self.run_probe(change_source=True)
        self.assertEqual(code, 1)
        self.assertEqual(calls, 1)
        self.assertEqual(observed["reason"], "source_changed")
        self.assertNotIn("sdk_permission_observation", observed)
        self.assertFalse(observed["native_query_observed"])


if __name__ == "__main__":
    unittest.main()
