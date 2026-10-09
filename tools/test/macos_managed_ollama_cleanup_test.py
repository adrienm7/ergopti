# tools/test/macos_managed_ollama_cleanup_test.py
"""Real private-file and literal authenticated GET receiving; Darwin is separate."""

import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "cleanup_receiving",
    ROOT / "static/ergopti_plus/macos/modules/llm/managed_ollama_cleanup.py",
)
CLEANUP = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = CLEANUP
spec.loader.exec_module(CLEANUP)
AUTH = CLEANUP.AUTH
ORIGINAL = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
FRESH = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
BOOT = "12345678-abcd-4321-abcd-123456789abc"
OPERATION = "e" * 32


def sha(data):
    return hashlib.sha256(data).hexdigest()


def ref(path, *, sealed=False):
    value = path.lstat()
    result = {
        "path": str(path),
        "device": str(value.st_dev),
        "inode": str(value.st_ino),
    }
    if sealed:
        result["sha256"] = sha(path.read_bytes())
    return result


class Response:
    def __init__(self, ports, payload, headers):
        self.ports, self.payload, self.headers = ports, payload, headers
        self.status = 200
        self.eof = self.closed = False

    def __enter__(self):
        if self.ports.action:
            self.ports.action()
        return self

    def __exit__(self, *unused):
        self.closed = True
        if self.ports.context_refusal:
            raise CLEANUP.AUTH.AuthorityRefusal()

    def read(self):
        if not self.eof:
            self.eof = True
            return self.payload
        return b""

    @property
    def listener(self):
        if not self.eof or self.ports.no_terminal:
            raise CLEANUP.PORTS.ENGINE.NativeHTTPError("protocol")
        return dict(self.ports.observed)


class Ports:
    listener = staticmethod(CLEANUP.PORTS.listener)

    def __init__(self, owner):
        self.owner = owner
        self.calls = []
        self.state = "retired"
        self.helper_count = self.background_count = 0
        self.action = None
        self.context_refusal = self.no_terminal = self.bad_mac = self.stale_lease = False
        self.observed = dict(owner.listener)

    def open_request(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        (
            executable,
            device,
            inode,
            port,
            listener,
            method,
            path,
            headers,
            body,
            timeout,
            idle,
        ) = args
        assert (executable, device, inode, port, listener) == (
            self.owner.executable,
            self.owner.session["device"],
            self.owner.session["inode"],
            11434,
            self.owner.listener,
        )
        assert method == "GET" and path == "/api/ergopti-native-http-admission" and body == ""
        assert 0 < timeout <= 1 and idle == 1
        values = dict(headers)
        challenge = values["X-Ergopti-Native-Challenge"]
        assert values["X-Ergopti-Native-Operation"] == OPERATION
        data = {
            "version": 1,
            "capability": "ERGOPTI_OLLAMA_NATIVE_HTTP_V1",
            "pid": 123,
            "source_commit": "b" * 40,
            "binary_sha256": "c" * 64,
            "asset_sha256": "d" * 64,
            "device": self.owner.session["device"],
            "inode": self.owner.session["inode"],
            "lease_id": sha(("z" if self.stale_lease else "a").encode() * 64),
            "port": "11434",
            "operation_id": OPERATION,
            "operation_state": self.state,
            "native_helpers": self.helper_count,
            "background_downloads": self.background_count,
        }
        payload = json.dumps(data, separators=(",", ":")).encode()
        mac = hmac.new(
            b"a" * 64,
            b"ERGOPTI_NATIVE_RESPONSE_V1\n" + challenge.encode() + b"\n" + payload,
            hashlib.sha256,
        ).hexdigest()
        if self.bad_mac:
            mac = "0" * 64
        self.response = Response(self, payload, [("X-Ergopti-Native-Proof", mac)])
        return self.response


class CleanupReceiving(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.anchor = self.root / "anchor"
        self.anchor.touch(mode=0o600)
        self.anchor.chmod(0o600)
        self.binary = self.root / "literal-source-fixture"
        self.binary.write_bytes(b"Independent binary fixture, never native admission evidence\n")
        binary = self.binary.stat()

        class Owner:
            admitted, submitted = True, False
            operation = OPERATION
            executable = str(self.binary)
            contract_sha256 = sha(b"independent contract bytes")
            catalogue_sha256 = sha(b"independent catalogue bytes")
            session = {
                "version": 1,
                "token": "a" * 64,
                "source_commit": "b" * 40,
                "binary_sha256": "c" * 64,
                "asset_sha256": "d" * 64,
                "device": str(binary.st_dev),
                "inode": str(binary.st_ino),
                "port": "11434",
            }
            listener = {
                "pid": 123,
                "uid": os.geteuid(),
                "start_seconds": "42",
                "start_microseconds": "17",
                "device": str(binary.st_dev),
                "inode": str(binary.st_ino),
            }

        self.owner = Owner()
        self.files = AUTH.OperationFiles(ref(self.anchor), ORIGINAL)
        self.addCleanup(self.files.close)
        self.files.bind(
            self.owner,
            {"retirement_ms": 1000, "idle_ms": 1000, "maximum_bytes": 4096},
            CLEANUP.POLICY.private_session,
            CLEANUP.PORTS.listener,
        )
        self.files.seal_window(time.monotonic() + 1, lambda _: BOOT)
        self.value = {
            "version": 1,
            "nonce": FRESH,
            "original_nonce": ORIGINAL,
            "original_worker_status": 78,
            "operation": OPERATION,
            "anchor": ref(self.anchor, sealed=True),
            "receipt_path": str(self.root / "cleanup-receipt"),
        }
        self.ports = Ports(self.owner)
        self.provenance_calls = []

    def run_cleanup(self, **kwargs):
        return CLEANUP.receive(
            self.value,
            mode=kwargs.pop("mode", "explicit-cleanup"),
            timeout=kwargs.pop("timeout", 1),
            ports=self.ports,
            verify=kwargs.pop(
                "verify",
                lambda authority, deadline: self.provenance_calls.append((authority, deadline)),
            ),
            boot=kwargs.pop("boot", lambda _: BOOT),
            **kwargs,
        )

    def test_literal_original_authority_fields_and_private_modes(self):
        value = json.loads((self.files.directory / "authority.json").read_bytes())
        self.assertEqual(
            value,
            {
                "version": 1,
                "nonce": ORIGINAL,
                "operation": OPERATION,
                "executable": str(self.binary),
                "session": self.owner.session,
                "lease_id": sha(b"a" * 64),
                "listener": self.owner.listener,
                "source_alias": None,
                "contract_sha256": sha(b"independent contract bytes"),
                "catalogue_sha256": sha(b"independent catalogue bytes"),
                "policy": {
                    "retirement_ms": 1000,
                    "idle_ms": 1000,
                    "maximum_bytes": 4096,
                },
            },
        )
        self.assertEqual(self.files.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.files.directory / "authority.json").stat().st_mode & 0o777, 0o600)
        with self.assertRaises(AUTH.AuthorityRefusal):
            self.files.authority.publish(value)
        with self.assertRaises(AUTH.AuthorityRefusal):
            self.files.seal_window(time.monotonic() + 1, lambda _: BOOT)

    def test_fresh_ack_exact_tuple_get_and_independent_cleanup_proof(self):
        original_anchor = self.anchor.read_bytes()
        expected_authority = sha((self.files.directory / "authority.json").read_bytes())
        expected_window = sha((self.files.directory / "window.json").read_bytes())
        proof = self.run_cleanup()
        self.assertEqual(
            proof,
            {
                "version": 1,
                "nonce": FRESH,
                "original_nonce": ORIGINAL,
                "original_worker_status": 78,
                "operation": OPERATION,
                "authority_sha256": expected_authority,
                "window_sha256": expected_window,
                "state": "retired",
                "worker_status": 0,
                "request_reaped": True,
                "daemon_operation_retired": True,
                "source_admitted": True,
                "listener_bound": True,
            },
        )
        self.assertEqual(len(self.ports.calls), 1)
        self.assertTrue(self.ports.response.closed)
        self.assertEqual(self.anchor.read_bytes(), original_anchor)
        # ACK is handed to the actual task owner before any phase consumes
        # immutable authority; its portable Lua owner tests prove final closure.
        self.assertTrue(self.files.directory.exists())
        self.assertEqual(
            sha((self.files.directory / "authority.json").read_bytes()),
            expected_authority,
        )
        self.assertEqual(sha((self.files.directory / "window.json").read_bytes()), expected_window)

    def test_active_keeps_files_and_later_explicit_ack_uses_fresh_challenge(self):
        self.ports.state = "active"
        before = {
            name: (self.files.directory / name).read_bytes()
            for name in ("authority.json", "window.json")
        }
        pending = self.run_cleanup()
        self.assertEqual((pending["state"], pending["worker_status"]), ("pending", 78))
        for name, data in before.items():
            self.assertEqual((self.files.directory / name).read_bytes(), data)
        self.ports.state = "retired"
        self.value["nonce"] = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        self.assertEqual(self.run_cleanup()["state"], "retired")
        first, second = (
            dict(call[0][7])["X-Ergopti-Native-Challenge"] for call in self.ports.calls
        )
        self.assertNotEqual(first, second)

    def test_unknown_operation_retains_debt(self):
        self.ports.state = "unknown"
        proof = self.run_cleanup()
        self.assertEqual((proof["state"], proof["worker_status"]), ("pending", 78))
        self.assertFalse(proof["daemon_operation_retired"])
        self.assertTrue(self.files.directory.exists())

    def test_original_expiry_starts_no_query_or_provenance(self):
        clock = json.loads((self.files.directory / "window.json").read_bytes())
        result = self.run_cleanup(
            mode="original-window",
            now_ns=lambda: int(clock["deadline_monotonic_ns"]) + 1,
        )
        self.assertEqual(result["state"], "pending")
        self.assertEqual(self.ports.calls, [])
        self.assertEqual(self.provenance_calls, [])

    def test_explicit_input_consumes_its_original_worker_budget(self):
        result = self.run_cleanup(started_ns=time.monotonic_ns() - 2_000_000_000)
        self.assertEqual(result["state"], "pending")
        self.assertEqual(self.ports.calls, [])

    def test_monotonic_rollback_and_new_boot_refuse(self):
        start = int(
            json.loads((self.files.directory / "window.json").read_bytes())["started_monotonic_ns"]
        )
        self.assertEqual(self.run_cleanup(now_ns=lambda: start - 1)["state"], "pending")
        self.assertEqual(
            self.run_cleanup(boot=lambda _: "00000000-0000-0000-0000-000000000000")["state"],
            "pending",
        )
        self.assertEqual(self.ports.calls, [])

    def test_explicit_policy_mismatch_cannot_purchase_more_time(self):
        self.assertEqual(self.run_cleanup(timeout=2)["state"], "pending")
        self.assertEqual(self.ports.calls, [])

    def test_wrong_hmac_and_changed_lease_hold_debt(self):
        for field in ("bad_mac", "stale_lease"):
            setattr(self.ports, field, True)
            result = self.run_cleanup()
            self.assertEqual(result["state"], "pending")
            self.assertFalse(result["daemon_operation_retired"])
            setattr(self.ports, field, False)
        self.assertTrue(self.files.directory.exists())

    def test_changed_sdk_start_tuple_refuses_authenticated_body(self):
        self.ports.observed["start_seconds"] = "43"
        self.assertEqual(self.run_cleanup()["state"], "pending")
        self.assertTrue(self.ports.response.closed)

    def test_ack_with_native_or_background_work_is_not_retired(self):
        for field in ("helper_count", "background_count"):
            setattr(self.ports, field, 1)
            self.assertEqual(self.run_cleanup()["state"], "pending")
            setattr(self.ports, field, 0)
        self.assertTrue(self.files.directory.exists())

    def test_missing_terminal_or_failed_context_retains_original_debt(self):
        for field in ("no_terminal", "context_refusal"):
            setattr(self.ports, field, True)
            result = self.run_cleanup()
            self.assertEqual(result["state"], "pending")
            self.assertFalse(result["daemon_operation_retired"])
            setattr(self.ports, field, False)

    def test_source_change_refuses_before_get(self):
        def refused(*unused):
            raise AUTH.AuthorityRefusal()

        self.assertEqual(self.run_cleanup(verify=refused)["state"], "pending")
        self.assertEqual(self.ports.calls, [])

    def test_anchor_replacement_is_not_adopted(self):
        data = self.anchor.read_bytes()
        self.anchor.unlink()
        self.anchor.write_bytes(data)
        self.anchor.chmod(0o600)
        self.assertEqual(self.run_cleanup()["state"], "pending")
        self.assertEqual(self.ports.calls, [])

    def test_authority_bytes_or_public_permissions_refuse_before_get(self):
        path = self.files.directory / "authority.json"
        path.chmod(0o644)
        self.assertEqual(self.run_cleanup()["state"], "pending")
        path.chmod(0o600)
        path.write_bytes(b'{"version":1,"version":1}')
        self.assertEqual(self.run_cleanup()["state"], "pending")
        self.assertEqual(self.ports.calls, [])

    def test_private_directory_extra_file_is_not_adopted(self):
        extra = self.files.directory / "foreign"
        extra.write_bytes(b"preserve this independent file")
        self.assertEqual(self.run_cleanup()["state"], "pending")
        self.assertEqual(extra.read_bytes(), b"preserve this independent file")
        self.assertEqual(self.ports.calls, [])

    def test_mutation_during_get_refuses_after_actual_context_closure(self):
        path = self.files.directory / "authority.json"

        def replace():
            path.unlink()
            path.write_bytes(b"foreign replacement")
            path.chmod(0o600)

        self.ports.action = replace
        result = self.run_cleanup()
        self.assertEqual(result["state"], "pending")
        self.assertTrue(self.ports.response.closed)
        self.assertEqual(path.read_bytes(), b"foreign replacement")

    def test_reserved_anchor_descriptor_is_physically_closed(self):
        fd = self.files.anchor.descriptor
        self.files.close()
        with self.assertRaises(OSError):
            os.fstat(fd)

    def test_incomplete_anchor_does_not_infer_retirement_from_ui_proof(self):
        self.anchor.write_bytes(b"")
        self.assertEqual(self.run_cleanup()["state"], "pending")
        self.assertEqual(self.ports.calls, [])

    def test_existing_private_directory_is_never_replaced(self):
        other = self.root / "other-anchor"
        other.touch(mode=0o600)
        directory = Path(str(other) + ".operation")
        directory.mkdir(mode=0o700)
        (directory / "preserve").write_bytes(b"foreign")
        with self.assertRaises(FileExistsError):
            AUTH.OperationFiles(ref(other), ORIGINAL)
        self.assertEqual((directory / "preserve").read_bytes(), b"foreign")

    def test_reserved_anchor_symlink_hardlink_and_public_modes_refuse(self):
        for kind in ("symlink", "hardlink", "public"):
            path = self.root / kind
            if kind == "symlink":
                path.symlink_to(self.anchor)
            elif kind == "hardlink":
                os.link(self.anchor, path)
            else:
                path.touch(mode=0o644)
                path.chmod(0o644)
            with self.assertRaises((AUTH.AuthorityRefusal, OSError)):
                AUTH.PinnedFile(ref(path, sealed=True))
            path.unlink()

    def test_private_directory_symlink_refuses_preserving_original(self):
        directory = self.files.directory
        other = self.root / "retained"
        directory.rename(other)
        directory.symlink_to(other, target_is_directory=True)
        self.assertEqual(self.run_cleanup()["state"], "pending")
        self.assertEqual(self.ports.calls, [])
        self.assertTrue((other / "authority.json").exists())

    def test_private_directory_public_mode_refuses_before_get(self):
        self.files.directory.chmod(0o755)
        self.assertEqual(self.run_cleanup()["state"], "pending")
        self.assertEqual(self.ports.calls, [])

    def test_same_original_nonce_and_non78_input_cannot_start_a_query(self):
        for field, value in (("nonce", ORIGINAL), ("original_worker_status", 0)):
            previous = self.value[field]
            self.value[field] = value
            with self.assertRaises(AUTH.AuthorityRefusal):
                self.run_cleanup()
            self.value[field] = previous
        self.assertEqual(self.ports.calls, [])

    def test_producer_refuses_bad_policy_or_alias_before_sealing(self):
        for index, (policy, alias) in enumerate(
            (
                ({"retirement_ms": True, "idle_ms": 1000, "maximum_bytes": 4096}, None),
                (
                    {"retirement_ms": 1000, "idle_ms": 1000, "maximum_bytes": 65537},
                    None,
                ),
                (
                    {"retirement_ms": 1000, "idle_ms": 1000, "maximum_bytes": 4096},
                    {"version": 1},
                ),
            )
        ):
            anchor = self.root / ("producer-" + str(index))
            anchor.touch(mode=0o600)
            files = AUTH.OperationFiles(ref(anchor), ORIGINAL)
            self.addCleanup(files.close)
            self.owner.source_alias = alias
            with self.assertRaises(AUTH.AuthorityRefusal):
                files.bind(
                    self.owner,
                    policy,
                    CLEANUP.POLICY.private_session,
                    CLEANUP.PORTS.listener,
                )
            self.assertEqual((files.directory / "authority.json").read_bytes(), b"")
            self.assertEqual(anchor.read_bytes(), b"")

    def test_alias_exact_original_proof_is_persisted_and_forwarded(self):
        other = self.root / "aliased-anchor"
        other.touch(mode=0o600)
        files = AUTH.OperationFiles(ref(other), ORIGINAL)
        self.addCleanup(files.close)
        alias = {
            "version": 1,
            "nonce": "f" * 32,
            "directory_device": "1",
            "directory_inode": "21",
            "ancestor_device": "1",
            "ancestor_inode": "22",
            "lease_device": "1",
            "lease_inode": "23",
            "binary_sha256": "c" * 64,
        }
        self.owner.source_alias = dict(alias)
        files.bind(
            self.owner,
            {"retirement_ms": 1000, "idle_ms": 1000, "maximum_bytes": 4096},
            CLEANUP.POLICY.private_session,
            CLEANUP.PORTS.listener,
        )
        self.owner.source_alias["nonce"] = "0" * 32
        files.seal_window(time.monotonic() + 1, lambda _: BOOT)
        self.value["anchor"] = ref(other, sealed=True)
        self.assertEqual(self.run_cleanup()["state"], "retired")
        self.assertEqual(self.ports.calls[0][1], {"source_alias": alias})

    def test_worker_never_consumes_handoff_before_owner_receives_closed_ack(self):
        before = {
            name: (self.files.directory / name).read_bytes()
            for name in ("authority.json", "window.json")
        }
        with patch.object(
            AUTH.os,
            "unlink",
            side_effect=AssertionError("worker must leave phased closure to its original owner"),
        ):
            result = self.run_cleanup()
        self.assertEqual((result["state"], result["worker_status"]), ("retired", 0))
        self.assertTrue(result["daemon_operation_retired"])
        self.assertTrue(self.ports.response.closed)
        for name, data in before.items():
            self.assertEqual((self.files.directory / name).read_bytes(), data)

    def test_sealed_authority_cannot_be_consumed_by_original_worker(self):
        before = {
            name: (self.files.directory / name).read_bytes()
            for name in ("authority.json", "window.json")
        }
        with self.assertRaises(AUTH.AuthorityRefusal):
            self.files.remove()
        for name, data in before.items():
            self.assertEqual((self.files.directory / name).read_bytes(), data)

    def test_pre_handoff_private_files_physically_close_without_network(self):
        anchor = self.root / "unpublished-anchor"
        anchor.touch(mode=0o600)
        files = AUTH.OperationFiles(ref(anchor), ORIGINAL)
        self.addCleanup(files.close)
        files.remove()
        self.assertFalse(files.directory.exists())
        self.assertEqual(anchor.read_bytes(), b"")
        self.assertEqual(self.ports.calls, [])

    def verify_original_runtime(self, alias):
        authority = json.loads((self.files.directory / "authority.json").read_bytes())
        authority["source_alias"] = alias
        asset = {
            "source_commit": "b" * 40,
            "binary_sha256": "c" * 64,
            "sha256": "d" * 64,
            "capability": "ERGOPTI_OLLAMA_NATIVE_HTTP_V1",
            "native_http_capability": 1,
        }
        calls = []

        def receiving_port(*args, **kwargs):
            calls.append((args, kwargs))
            return self.binary

        with (
            patch.object(
                CLEANUP.RUNTIME,
                "inputs",
                return_value=(
                    b"independent contract bytes",
                    b"independent catalogue bytes",
                    "macos-arm64",
                    {},
                    asset,
                ),
            ),
            patch.object(CLEANUP.RUNTIME, "native_verify", receiving_port),
        ):
            CLEANUP.verify_runtime(authority, time.monotonic() + 1)
        return calls

    def test_runtime_verifier_generic_source_path_is_unchanged(self):
        calls = self.verify_original_runtime(None)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1], {})

    def test_runtime_alias_verifier_receives_only_same_original_source_proof(self):
        alias = {
            "version": 1,
            "nonce": "f" * 32,
            "directory_device": "1",
            "directory_inode": "21",
            "ancestor_device": "1",
            "ancestor_inode": "22",
            "lease_device": "1",
            "lease_inode": "23",
            "binary_sha256": "c" * 64,
        }
        calls = self.verify_original_runtime(alias)
        self.assertEqual(len(calls), 1)
        self.assertEqual(
            calls[0][1],
            {
                "source_alias": alias,
                "source_identity": {
                    "device": self.owner.session["device"],
                    "inode": self.owner.session["inode"],
                },
            },
        )

    def test_duplicate_json_and_nonfinite_values_are_not_authority(self):
        for data in (
            b'{"version":1,"version":1}',
            b'{"version":NaN}',
            b'{"version":Infinity}',
        ):
            with self.assertRaises(AUTH.AuthorityRefusal):
                AUTH.document(data)


class OriginalCallerHandoff(unittest.TestCase):
    def setUp(self):
        specification = importlib.util.spec_from_file_location(
            "cleanup_original_caller",
            ROOT / "static/ergopti_plus/macos/modules/llm/managed_ollama_pull.py",
        )
        self.caller = importlib.util.module_from_spec(specification)
        sys.modules[specification.name] = self.caller
        specification.loader.exec_module(self.caller)
        self.events = []
        events = self.events

        class Owner:
            admitted = True
            submitted = request_finished = retired = False
            session = {
                "source_commit": "b" * 40,
                "binary_sha256": "c" * 64,
                "asset_sha256": "d" * 64,
            }
            operation = OPERATION
            listener = {"pid": 123}

            @property
            def pending(self):
                return self.submitted and not self.retired

            def pull(self, model, emit, timeout):
                events.append("post")
                self.submitted = self.request_finished = True
                return True

            def retirement(self, timeout):
                events.append("get")
                self.retired = True
                return True

        self.owner = Owner()
        self.proofs = []

        class Receipt:
            def publish(inner, value):
                events.append("receipt")
                self.proofs.append(value)

        self.receipt = Receipt()

    def execute(self, **hooks):
        return self.caller.execute(
            {"nonce": ORIGINAL, "model": "fixture/model"},
            owner_factory=lambda *unused: self.owner,
            idle_timeout=1,
            maximum_bytes=4096,
            deadline=time.monotonic() + 1,
            retirement_timeout=1,
            cancellation=self.caller.Cancellation(),
            emit=lambda _: None,
            private_receipt=self.receipt,
            **hooks,
        )

    def test_original_authority_is_bound_before_post_clock_once_before_get(self):
        def bound(owner):
            self.assertFalse(owner.submitted)
            self.events.append("bind")

        def clock(deadline):
            self.assertTrue(self.owner.request_finished)
            self.assertGreater(deadline, time.monotonic())
            self.events.append("clock")

        def completed(proof):
            self.assertEqual(self.proofs, [])
            self.assertEqual(proof["state"], "retired")
            self.events.append("completion")

        self.assertEqual(
            self.execute(before_submit=bound, on_retirement_clock=clock, on_completion=completed),
            0,
        )
        self.assertEqual(self.events, ["bind", "post", "clock", "get", "completion", "receipt"])

    def test_prepost_authority_refusal_never_submits_or_buys_window(self):
        def refuse(owner):
            raise AUTH.AuthorityRefusal()

        self.assertEqual(
            self.execute(
                before_submit=refuse,
                on_retirement_clock=lambda _: self.fail("no operation window before POST"),
            ),
            78,
        )
        self.assertEqual(self.events, ["receipt"])
        self.assertFalse(self.owner.submitted)
        self.assertEqual(self.proofs[0]["operation"], "")

    def test_clock_seal_failure_cannot_publish_authenticated_retirement(self):
        def refuse(deadline):
            raise AUTH.AuthorityRefusal()

        self.assertEqual(self.execute(on_retirement_clock=refuse), 78)
        self.assertEqual(self.events, ["post", "receipt"])
        self.assertEqual(self.proofs[0]["state"], "pending")
        self.assertFalse(self.proofs[0]["daemon_operation_retired"])

    def test_completion_closure_refusal_does_not_publish_a_release_receipt(self):
        def refuse(proof):
            raise AUTH.AuthorityRefusal()

        with self.assertRaises(AUTH.AuthorityRefusal):
            self.execute(on_completion=refuse)
        self.assertEqual(self.events, ["post", "get"])
        self.assertEqual(self.proofs, [])


if __name__ == "__main__":
    unittest.main()
