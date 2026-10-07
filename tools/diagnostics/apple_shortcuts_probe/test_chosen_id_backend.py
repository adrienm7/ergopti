# tools/diagnostics/apple_shortcuts_probe/test_chosen_id_backend.py
"""Independent portable controls; native Shortcuts qualification is CI-only."""

import json
from pathlib import Path
import subprocess
import sys
import unittest

from chosen_id_backend import NativeShortcuts, Refused

ROOT = Path(__file__).resolve().parents[3]
ID1 = "11111111-1111-1111-1111-111111111111"
ID2 = "22222222-2222-2222-2222-222222222222"


class Model(NativeShortcuts):
    def __init__(self):
        super().__init__(ROOT, ownership=object(), native=object())
        self.token = "CLI1"
        self.rows = [
            {"id": ID1, "name": "日本 e\u0301\n'$(PRIVATE)", "accepts_input": False},
            {"id": ID2, "name": "日本 e\u0301\n'$(PRIVATE)", "accepts_input": True},
        ]
        self.calls = []
        self.reply_change = None
        self.output = b"safe-fixture\n"

    def identity(self, path="/usr/bin/shortcuts"):
        return self.token

    def capture(self, arguments, **_kwargs):
        self.calls.append(list(arguments))
        if arguments[0] == "/usr/bin/shortcuts":
            return b"shortcut-name-or-identifier" if arguments[-1] == "--help" else self.output
        operation, nonce = arguments[4:6]
        rows = (
            self.rows
            if operation == "discover"
            else [row for row in self.rows if row["id"] == arguments[6]]
        )
        reply = {
            "version": 1,
            "nonce": int(nonce),
            "operation": operation,
            "status": "observed",
            "rows": rows,
            "truncated": False,
        }
        if self.reply_change:
            self.reply_change(reply)
        return json.dumps(reply).encode()


class ChosenBackendTests(unittest.TestCase):
    def test_private_duplicate_names_lower_only_chosen_id(self):
        backend = Model()
        choices = backend.discover()["choices"]
        self.assertEqual(choices[0]["label"], choices[1]["label"])
        self.assertNotIn("id", choices[0])
        self.assertEqual(
            backend.resolve(choices[1]["key"]),
            {"version": 1, "executable": "/usr/bin/shortcuts", "arguments": ["run", ID2]},
        )
        self.assertEqual(backend.calls[-1][-3:], ["revalidate", "2", ID2])

    def test_rename_same_count_is_refused(self):
        backend = Model()
        key = backend.discover()["choices"][0]["key"]
        backend.rows[0] = dict(backend.rows[0], name="renamed")
        with self.assertRaisesRegex(Refused, "stale_discovery"):
            backend.resolve(key)

    def test_id_deletion_is_refused(self):
        backend = Model()
        key = backend.discover()["choices"][0]["key"]
        backend.rows[0] = dict(backend.rows[0], id="33333333-3333-3333-3333-333333333333")
        with self.assertRaisesRegex(Refused, "stale_discovery"):
            backend.resolve(key)

    def test_cli_replacement_prevents_revalidation_query(self):
        backend = Model()
        key = backend.discover()["choices"][0]["key"]
        before = len(backend.calls)
        backend.token = "CLI2"
        with self.assertRaisesRegex(Refused, "identity_refused"):
            backend.resolve(key)
        self.assertEqual(len(backend.calls), before)

    def test_argv_is_exact_and_output_is_independently_checked(self):
        backend = Model()
        key = backend.discover()["choices"][1]["key"]
        result = backend.invoke(key, lambda: True, b"safe-fixture\n")
        self.assertEqual(backend.calls[-1], ["/usr/bin/shortcuts", "run", ID2])
        self.assertTrue(result["fixture_output_verified"])
        self.assertFalse(result["automation_retired"])

    def test_bad_fixture_output_is_not_a_native_pass(self):
        backend = Model()
        key = backend.discover()["choices"][0]["key"]
        with self.assertRaisesRegex(Refused, "fixture_output_refused"):
            backend.invoke(key, lambda: True, b"independent-token")

    def test_consumer_admission_is_rechecked_after_query(self):
        backend = Model()
        key = backend.discover()["choices"][0]["key"]
        receipts = iter([True, False])
        with self.assertRaisesRegex(Refused, "admission_refused"):
            backend.invoke(key, lambda: next(receipts))
        self.assertEqual(backend.calls[-1][0], "/usr/bin/osascript")

    def test_invalidation_refuses_old_key(self):
        backend = Model()
        key = backend.discover()["choices"][0]["key"]
        self.assertEqual(
            backend.cancel(),
            {
                "local_retired": True,
                "automation_retired": False,
                "reason": "service_retirement_unqualified",
            },
        )
        with self.assertRaisesRegex(Refused, "stale_discovery"):
            backend.resolve(key)

    def test_cancel_retries_exact_retained_owner(self):
        backend = Model()

        class Debt:
            settled = False
            calls = 0

            def settle(self):
                self.calls += 1
                return self.settled

            def receipt(self):
                return {"closed": self.settled}

        debt = Debt()
        backend.pending.append(debt)
        self.assertFalse(backend.cancel()["local_retired"])
        with self.assertRaisesRegex(Refused, "cleanup_pending"):
            backend.discover()
        debt.settled = True
        self.assertTrue(backend.cancel()["local_retired"])
        self.assertEqual(debt.calls, 2)

    def test_nonce_tampering_and_duplicate_ids_refuse(self):
        for mutation in (
            lambda data: data.update(nonce=999),
            lambda data: data.update(rows=[data["rows"][0], data["rows"][0]]),
        ):
            backend = Model()
            backend.reply_change = mutation
            with self.assertRaisesRegex(Refused, "invalid_reply"):
                backend.discover()

    def test_permission_refusal_never_becomes_empty_success(self):
        backend = Model()

        def refuse(data):
            data.pop("rows")
            data.pop("truncated")
            data.update(status="refused", reason="automation_permission_refused")

        backend.reply_change = refuse
        with self.assertRaisesRegex(Refused, "automation_permission_refused"):
            backend.discover()

    def test_native_inventory_does_not_advertise_service_readiness(self):
        backend = Model()
        rows = backend.inventory()
        self.assertEqual(
            [row["id"] for row in rows],
            ["apple_shortcuts", "applescript_jxa", "automator", "launchservices"],
        )
        self.assertTrue(all(row["installed"] and not row["available"] for row in rows))


class PipeCaptureTests(unittest.TestCase):
    """Exercise actual bounded pipe IO with controlled ownership, not Darwin census."""

    def backend(self):
        class Group:
            def __init__(self, arguments, **kwargs):
                self.process = subprocess.Popen(arguments, **kwargs)

            def observe_exit(self):
                return self.process.poll()

            def settle(self):
                if self.process.poll() is None:
                    self.process.terminate()
                self.process.wait(timeout=2)
                return True

            def receipt(self):
                return {"closed": True, "controlled_ownership": True}

        class Ownership:
            @staticmethod
            def acquire_owned(arguments, _native, register, **kwargs):
                group = Group(arguments, **kwargs)
                register(group)
                return group

        return NativeShortcuts(ROOT, ownership=Ownership, native=object())

    def test_actual_pipe_bytes_are_preserved_and_owner_retired(self):
        backend = self.backend()
        data = backend.capture(
            [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'abc\\x00\\n')"]
        )
        self.assertEqual(data, b"abc\0\n")
        self.assertEqual(backend.pending, [])
        self.assertEqual(len(backend.receipts), 1)

    def test_actual_pipe_overflow_closes_exact_owner(self):
        backend = self.backend()
        with self.assertRaisesRegex(Refused, "reply_limit"):
            backend.capture(
                [sys.executable, "-c", "import sys; sys.stdout.write('a'*200000)"], limit=128
            )
        self.assertEqual(backend.pending, [])
        self.assertEqual(len(backend.receipts), 1)

    def test_actual_stderr_and_nonzero_exit_refuse(self):
        for source in ("import sys; sys.stderr.write('PRIVATE')", "raise SystemExit(37)"):
            backend = self.backend()
            with self.assertRaisesRegex(Refused, "execution_refused"):
                backend.capture([sys.executable, "-c", source])
            self.assertEqual(backend.pending, [])

    def test_actual_timeout_retires_owned_child(self):
        backend = self.backend()
        with self.assertRaisesRegex(Refused, "query_timeout"):
            backend.capture([sys.executable, "-c", "import time; time.sleep(30)"], timeout=0.05)
        self.assertEqual(backend.pending, [])


if __name__ == "__main__":
    unittest.main()
