# tools/diagnostics/program_actions/test_signed_query_probe.py
"""Independent protocol, provenance and real pipe controls; Darwin ABI remains CI-only."""

import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest

from run_signed_query_probe import QueryProtocol, Refused, SignedQuery, verify_build_receipt

ID = "11111111-1111-1111-1111-111111111111"


def observed(**updates):
    packet = {
        "version": 1,
        "nonce": 7,
        "operation": "discover",
        "status": "observed",
        "rows": [{"id": ID, "name": "日本 e\u0301\n<private>", "accepts_input": False}],
        "truncated": False,
    }
    packet.update(updates)
    return packet


def data(packet):
    return b"Q1 DATA " + base64.b64encode(json.dumps(packet, ensure_ascii=False).encode()) + b"\n"


def finished(packet):
    protocol = QueryProtocol()
    protocol.feed(b"Q1 HELD\n")
    protocol.feed(data(packet))
    protocol.feed(b"Q1 RETIRED 0\n")
    return protocol


class ProtocolControls(unittest.TestCase):
    def test_literal_unicode_and_fragmented_protocol(self):
        protocol = QueryProtocol()
        raw = b"Q1 HELD\n" + data(observed()) + b"Q1 RETIRED 0\n"
        for byte in raw:
            protocol.feed(bytes([byte]))
        packet = protocol.decode("discover", 7)
        self.assertEqual(
            packet["rows"][0]["name"].encode(),
            bytes([0xE6, 0x97, 0xA5, 0xE6, 0x9C, 0xAC, 0x20, 0x65, 0xCC, 0x81, 0x0A])
            + b"<private>",
        )

    def test_payload_without_inner_retirement_refused(self):
        protocol = QueryProtocol()
        protocol.feed(b"Q1 HELD\n" + data(observed()))
        with self.assertRaisesRegex(Refused, "query_refused"):
            protocol.decode("discover", 7)

    def test_permission_refusal_never_qualifies_empty_catalogue(self):
        packet = {
            "version": 1,
            "nonce": 7,
            "operation": "discover",
            "status": "refused",
            "reason": "automation_permission_refused",
        }
        with self.assertRaisesRegex(Refused, "automation_permission_refused"):
            finished(packet).decode("discover", 7)

    def test_envelope_and_rows_are_closed(self):
        packets = [
            observed(nonce=True),
            observed(extra="private"),
            observed(rows=65 * observed()["rows"]),
        ]
        row = dict(observed()["rows"][0], name="embedded\0name")
        packets.extend([observed(rows=[row]), observed(rows=2 * observed()["rows"])])
        for packet in packets:
            with self.subTest(packet=packets.index(packet)), self.assertRaises(Refused):
                finished(packet).decode("discover", 7)

    def test_chosen_id_is_exact_and_metadata_bounded(self):
        protocol = finished(observed(operation="revalidate"))
        self.assertEqual(protocol.decode("revalidate", 7, ID)["rows"][0]["id"], ID)
        with self.assertRaisesRegex(Refused, "stale_discovery"):
            protocol.decode("revalidate", 7, "22222222-2222-2222-2222-222222222222")
        with self.assertRaises(Refused):
            finished(observed(rows=[dict(observed()["rows"][0], name="a" * 4097)])).decode(
                "discover", 7
            )

    def test_duplicate_markers_and_data_refused(self):
        for raw in (
            b"Q1 HELD\nQ1 HELD\n",
            b"Q1 HELD\nQ1 REFUSED 5\n",
            b"Q1 HELD\nQ1 RETIRED 00\n",
            b"Q1 HELD\n" + 2 * data(observed()),
        ):
            with self.assertRaises(Refused):
                QueryProtocol().feed(raw)

    def test_budget_enforced_before_append(self):
        protocol = QueryProtocol()
        with self.assertRaisesRegex(Refused, "reply_limit"):
            protocol.feed(b"x" * 90001)
        self.assertEqual(protocol.bytes, 0)
        self.assertEqual(protocol.buffer, b"")

    def test_native_refused_receipt_has_no_observed_catalogue(self):
        protocol = QueryProtocol()
        protocol.feed(b"Q1 REFUSED 2\n")
        with self.assertRaises(Refused):
            protocol.decode("discover", 7)

    def test_build_provenance_binds_source_product_and_actual_ci_run(self):
        hashes = {"Source.swift": "1" * 64}
        packet = {
            "schema": 1,
            "contract": "signed-native-query-build",
            "source_sha": "a" * 40,
            "source_hashes": hashes,
            "helper_sha256": "b" * 64,
            "ci_run_id": "123",
            "ci_run_attempt": "2",
        }
        self.assertEqual(
            verify_build_receipt(
                json.dumps(packet).encode(), "a" * 40, hashes, "b" * 64, "123", "2"
            ),
            packet,
        )
        for field, bad in (
            ("source_sha", "f" * 40),
            ("helper_sha256", "c" * 64),
            ("ci_run_id", "999"),
            ("source_hashes", {}),
        ):
            with (
                self.subTest(field=field),
                self.assertRaisesRegex(Refused, "build_provenance_refused"),
            ):
                verify_build_receipt(
                    json.dumps(dict(packet, **{field: bad})).encode(),
                    "a" * 40,
                    hashes,
                    "b" * 64,
                    "123",
                    "2",
                )
        with self.assertRaises(Refused):
            verify_build_receipt(json.dumps(packet).encode(), "a" * 40, hashes, "b" * 64, None, "2")


class ControlledGroup:
    """Real portable direct-child WNOWAIT; inherited-group census is a controlled port."""

    def __init__(self, process, _native):
        self.process = process
        self.reaped = False
        self.settles = 0

    def observe_exit(self):
        self.assert_unreaped()
        value = os.waitid(os.P_PID, self.process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        return value if value and value.si_pid else None

    def assert_unreaped(self):
        if self.process.returncode is not None:
            raise AssertionError("test owner was reaped early")

    def closed_before_reap(self):
        return self.observe_exit() is not None

    def settle(self, timeout=0):
        assert timeout == 0 and self.observe_exit() is not None
        self.settles += 1
        self.process.wait(timeout=1)
        self.reaped = True
        return True

    def receipt(self):
        return {"closed": self.reaped, "signals": [], "controlled_census": True}


class PipeControls(unittest.TestCase):
    def run_helper(self, mode, cancel_held=False):
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / "fixed-query-owner"
            helper.write_text(
                "#!"
                + sys.executable
                + "\n"
                + """
import base64, json, sys
print('Q1 HELD', flush=True)
command = sys.stdin.readline()
if command == 'ACTIVATE\\n':
    if MODE == 'missing':
        sys.exit(0)
    packet = {'version':1,'nonce':7,'operation':'discover','status':'observed',
        'rows':[{'id':'11111111-1111-1111-1111-111111111111','name':'fixed real pipe','accepts_input':False}], 'truncated':False}
    print('Q1 DATA ' + base64.b64encode(json.dumps(packet).encode()).decode(), flush=True)
    print('Q1 RETIRED 0', flush=True)
else:
    print('Q1 RETIRED 15', flush=True)
""".replace("MODE", repr(mode))
            )
            helper.chmod(0o700)
            owner = SignedQuery(
                helper, types.SimpleNamespace(OwnedProcessGroup=ControlledGroup), object()
            )
            try:
                result = owner.query("discover", 7, cancel_held=cancel_held)
                self.assertIsNone(owner.group)
                self.assertEqual(owner.receipts[0]["outer_owner"]["signals"], [])
                return result, owner
            finally:
                # Only the fixed test helper, which cannot spawn descendants,
                # may be explicitly reaped after testing unknown inner custody.
                if owner.group is not None:
                    owner.cancel()
                    owner.group.process.wait(timeout=2)

    def test_real_pipe_capture_waits_for_both_receipts(self):
        packet, owner = self.run_helper("normal")
        self.assertEqual(packet["rows"][0]["name"], "fixed real pipe")
        self.assertTrue(owner.receipts[0]["inner_retired"])

    def test_actual_eof_cancellation_never_signals_supervisor(self):
        packet, owner = self.run_helper("normal", cancel_held=True)
        self.assertIsNone(packet)
        self.assertTrue(owner.receipts[0]["cancel_requested"])
        self.assertEqual(owner.receipts[0]["payload_bytes"], 0)

    def test_leader_exit_without_inner_receipt_retains_unknown_custody(self):
        with self.assertRaisesRegex(Refused, "inner_custody_unknown"):
            self.run_helper("missing")


if __name__ == "__main__":
    unittest.main()
