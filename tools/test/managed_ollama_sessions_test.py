# tools/test/managed_ollama_sessions_test.py
"""Real private files plus independently injected listener authentication."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "tested_sessions", ROOT / "static/ergopti_plus/_shared/python/managed_ollama_sessions.py"
)
SESSIONS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SESSIONS)

SESSION = {
    "version": 1,
    "token": "a" * 64,
    "source_commit": "b" * 40,
    "binary_sha256": "c" * 64,
    "asset_sha256": "d" * 64,
    "device": "1",
    "inode": "2",
    "port": "11434",
}
EXPECTED = {
    key: SESSION[key]
    for key in ("source_commit", "binary_sha256", "asset_sha256", "device", "inode")
}


class PrivateSessionReceiving(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        os.chmod(self.root, 0o700)
        self.calls = []

    def write(self, name="daemon-owned.json", value=SESSION):
        path = self.root / name
        path.write_text(json.dumps(value))
        path.chmod(0o600)
        return path

    def authenticate(self, session, remaining):
        self.calls.append(session)
        self.assertGreater(remaining, 0)
        self.assertLessEqual(remaining, 2)
        return "authenticated-live-listener"

    def test_slow_private_file_read_consumes_original_admission_clock(self):
        self.write()
        clock = [100.0]
        actual = SESSIONS.read_session
        budgets = []

        def delayed(*arguments):
            session = actual(*arguments)
            clock[0] += 1.5
            return session

        def authenticate(session, remaining):
            budgets.append(remaining)
            return "same-clock"

        with (
            patch.object(SESSIONS.time, "monotonic", side_effect=lambda: clock[0]),
            patch.object(SESSIONS, "read_session", side_effect=delayed),
        ):
            self.assertEqual(
                SESSIONS.select(self.root, 11434, EXPECTED, authenticate, 2), "same-clock"
            )
        self.assertEqual(budgets, [0.5])

    def test_expired_private_file_read_refuses_before_listener_contact(self):
        self.write()
        clock = [100.0]
        actual = SESSIONS.read_session

        def delayed(*arguments):
            session = actual(*arguments)
            clock[0] += 3
            return session

        with (
            patch.object(SESSIONS.time, "monotonic", side_effect=lambda: clock[0]),
            patch.object(SESSIONS, "read_session", side_effect=delayed),
        ):
            with self.assertRaises(SESSIONS.POLICY.RuntimeRefusal) as failure:
                SESSIONS.select(self.root, 11434, EXPECTED, self.authenticate, 2)
        self.assertEqual(str(failure.exception), "deadline")
        self.assertEqual(self.calls, [])

    def test_real_private_lease_reaches_only_listener_authentication(self):
        self.write()
        result = SESSIONS.select(self.root, 11434, EXPECTED, self.authenticate, 2)
        self.assertEqual(result, "authenticated-live-listener")
        self.assertEqual(self.calls, [SESSION])

    def test_wrong_port_and_source_never_disclose_secret_to_listener(self):
        self.write("daemon-a.json", SESSION | {"port": "11435"})
        self.write("daemon-b.json", SESSION | {"source_commit": "e" * 40})
        with self.assertRaises(SESSIONS.POLICY.RuntimeRefusal):
            SESSIONS.select(self.root, 11434, EXPECTED, self.authenticate, 2)
        self.assertEqual(self.calls, [])

    def test_real_symlink_hardlink_world_readable_and_nonregular_are_refused(self):
        target = self.write("daemon-source.json")
        for name in (
            "daemon-link.json",
            "daemon-hard.json",
            "daemon-public.json",
            "daemon-dir.json",
        ):
            path = self.root / name
            if "link" in name:
                path.symlink_to(target)
            elif "hard" in name:
                path.hardlink_to(target)
            elif "public" in name:
                self.write(name).chmod(0o644)
            else:
                path.mkdir()
            with self.assertRaises((OSError, SESSIONS.POLICY.RuntimeRefusal)):
                SESSIONS.read_session(self.root, name)
        with self.assertRaises(SESSIONS.POLICY.RuntimeRefusal):
            SESSIONS.read_session(self.root, "daemon-source.json")
        self.assertEqual(self.calls, [])

    def test_duplicate_json_boolean_identity_and_noncanonical_number_are_refused(self):
        path = self.write()
        for data in (
            b'{"version":1,"version":1}',
            json.dumps(SESSION | {"inode": "02"}).encode(),
            json.dumps(SESSION | {"version": True}).encode(),
            b"{}" * 3000,
        ):
            path.write_bytes(data)
            with self.assertRaises(SESSIONS.POLICY.RuntimeRefusal):
                SESSIONS.read_session(self.root, path.name)

    def test_stale_lease_remains_untouched_and_second_live_lease_is_authenticated(self):
        old = self.write("daemon-a.json", SESSION | {"token": "e" * 64})
        self.write("daemon-b.json")

        def authenticate(session, remaining):
            if session["token"] != SESSION["token"]:
                raise SESSIONS.POLICY.RuntimeRefusal("session")
            return self.authenticate(session, remaining)

        self.assertEqual(
            SESSIONS.select(self.root, 11434, EXPECTED, authenticate, 2),
            "authenticated-live-listener",
        )
        self.assertEqual(json.loads(old.read_bytes())["token"], "e" * 64)

    def test_real_directory_symlink_permissions_and_scan_limit_refuse_before_authentication(self):
        self.write()
        link = self.root / "directory-link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            SESSIONS.directory_descriptor(link)
        link.unlink()
        self.root.chmod(0o755)
        with self.assertRaises(SESSIONS.POLICY.RuntimeRefusal):
            SESSIONS.directory_descriptor(self.root)
        self.root.chmod(0o700)
        for number in range(64):
            self.write(f"daemon-extra-{number}.json")
        with self.assertRaises(SESSIONS.POLICY.RuntimeRefusal):
            SESSIONS.select(self.root, 11434, EXPECTED, self.authenticate, 2)
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
