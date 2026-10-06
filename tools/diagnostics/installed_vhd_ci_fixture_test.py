# tools/diagnostics/installed_vhd_ci_fixture_test.py
"""Portable receipt controls; native SDK and guardian endpoints are modeled here."""

import copy
import errno
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

import installed_vhd_ci_fixture as subject


def native_record():
    """Handwritten modeled facts, never a captured native ancestry receipt."""
    acl = {
        "acquisition_attempted": True,
        "acquired": True,
        "acquire_errno": 0,
        "valid_result": 0,
        "valid_errno": 0,
        "first_result": -1,
        "first_errno": errno.EINVAL,
        "entry_present": False,
        "free_result": 0,
        "free_errno": 0,
    }
    nodes = []
    for role, inode in (("root", 2), ("library", 3)):
        nodes.append(
            {
                "role": role,
                "opened": True,
                "identity": {"device": 1, "inode": inode, "mode": 0o40755, "uid": 0, "gid": 0},
                "current": True,
                "pin_error": None,
                "error_code": None,
                "acl": copy.deepcopy(acl),
                "close_result": 0,
                "close_errno": 0,
            }
        )
    return {"schema": 1, "pid": 200, "nodes": nodes}


def controller_record():
    return {
        "schema": 1,
        "kind": "read_only_acl_ancestry",
        "pid": 100,
        "native": native_record(),
        "source_hashes": {key: "a" * 64 for key in ("controller", "observer", "guardian")},
        "elapsed_seconds": 0.5,
    }


class PortableAncestryControls(unittest.TestCase):
    def admit(self, packet=None, terminal=None, **changes):
        packet = controller_record() if packet is None else packet
        terminal = terminal or {
            "schema": 1,
            "guardian_pid": 300,
            "worker_pid": 100,
            "group_id": 100,
            "closed": True,
            "exit_status": 0,
        }
        options = {
            "guardian_pid": 300,
            "guardian_status": 0,
            "worker_pid": 100,
            "completed": True,
            "expected_sources": {key: "a" * 64 for key in ("controller", "observer", "guardian")},
            "deadline": changes["deadline"] if "deadline" in changes else time.monotonic() + 25,
        }
        options.update(changes)
        return subject.admit(packet, terminal, **options)

    def test_positive_is_only_sampled_ancestry(self):
        self.assertEqual(self.admit(), "qualified")
        self.assertEqual(
            set(controller_record()),
            {
                "schema",
                "kind",
                "pid",
                "native",
                "source_hashes",
                "elapsed_seconds",
            },
        )

    def test_null_even_without_errno_is_unknown(self):
        for code in (0, errno.ENOENT):
            packet = controller_record()
            acl = packet["native"]["nodes"][0]["acl"]
            acl.update(acquired=False, acquire_errno=code)
            for name in (
                "valid_result",
                "valid_errno",
                "first_result",
                "first_errno",
                "entry_present",
                "free_result",
                "free_errno",
            ):
                acl[name] = None
            self.assertEqual(self.admit(packet), "unknown")

    def test_real_entry_is_nonempty_not_positive(self):
        packet = controller_record()
        packet["native"]["nodes"][0]["acl"].update(
            first_result=0, first_errno=0, entry_present=True
        )
        self.assertEqual(self.admit(packet), "unknown")

    def test_contradictory_or_invalid_iterator_is_unknown(self):
        for changes in (
            {"first_result": 0, "entry_present": False},
            {"first_errno": 0},
            {"valid_result": -1},
        ):
            packet = controller_record()
            packet["native"]["nodes"][0]["acl"].update(changes)
            self.assertEqual(self.admit(packet), "unknown")

    def test_each_cleanup_failure_denies(self):
        for role in (0, 1):
            for location, key in (("acl", "free_result"), (None, "close_result")):
                packet = controller_record()
                node = packet["native"]["nodes"][role]
                (node[location] if location else node)[key] = -1
                self.assertEqual(self.admit(packet), "denied")

    def test_named_identity_or_protection_drift_denies(self):
        for change in ("current", "uid", "mode"):
            packet = controller_record()
            node = packet["native"]["nodes"][1]
            if change == "current":
                node[change] = False
            else:
                node["identity"][change] = 1000 if change == "uid" else 0o40777
            self.assertEqual(self.admit(packet), "denied")

    def test_missing_real_completion_and_terminal_credit_refuse(self):
        for change in (
            {"completed": False},
            {"completed": 1},
            {"guardian_status": 124},
            {"guardian_status": True},
            {"worker_pid": True},
            {"guardian_pid": 301},
        ):
            with self.assertRaises(ValueError):
                self.admit(**change)

    def test_terminal_closed_types_and_inventory_refuse(self):
        for key, value in (
            ("closed", 1),
            ("closed", False),
            ("schema", True),
            ("worker_pid", 101),
            ("group_id", 101),
            ("extra", False),
        ):
            terminal = {
                "schema": 1,
                "guardian_pid": 300,
                "worker_pid": 100,
                "group_id": 100,
                "closed": True,
                "exit_status": 0,
            }
            terminal[key] = value
            with self.assertRaises(ValueError):
                self.admit(terminal=terminal)

    def test_untyped_or_unbounded_native_values_refuse(self):
        for key, value in (("mode", True), ("inode", 1.0), ("uid", -1)):
            packet = controller_record()
            packet["native"]["nodes"][0]["identity"][key] = value
            with self.assertRaises(ValueError):
                self.admit(packet)
        for value in (True, float("nan"), float("inf"), -1, 26):
            packet = controller_record()
            packet["elapsed_seconds"] = value
            with self.assertRaises(ValueError):
                self.admit(packet)

    def test_source_identity_cannot_be_self_authored(self):
        packet = controller_record()
        packet["source_hashes"]["observer"] = "b" * 64
        with self.assertRaises(ValueError):
            self.admit(packet)

    def test_whole_deadline_before_and_after_qualification(self):
        for samples in ([126], [100, 126]):
            with mock.patch.object(subject.time, "monotonic", side_effect=samples):
                with self.assertRaises(ValueError):
                    self.admit(deadline=125)

    def test_actual_json_duplicate_and_nonfinite_fields_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt"
            for data in ('{"a":1,"\\u0061":2}', '{"a":{"x":1,"x":2}}', '{"a":NaN}', '{"a":1e999}'):
                path.write_text(data)
                with self.assertRaises(ValueError):
                    subject.read_record(path)
            path.write_text(json.dumps(controller_record()))
            self.assertEqual(subject.read_record(path), controller_record())

    def test_actual_alias_fifo_hardlink_and_size_inputs_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / "original"
            original.write_text("{}")
            alias = root / "alias"
            alias.symlink_to(original)
            fifo = root / "fifo"
            os.mkfifo(fifo)
            link = root / "hardlink"
            os.link(original, link)
            for path in (alias, fifo, link):
                with self.assertRaises(ValueError):
                    subject.read_record(path)
            link.unlink()
            parent = root / "parent"
            parent.symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                subject.read_record(parent / "original")
            for data in ("", " " * 16385):
                original.write_text(data)
                with self.assertRaises(ValueError):
                    subject.read_record(original)

    def test_unsupported_host_acquires_nothing(self):
        with (
            mock.patch.object(subject.sys, "platform", "linux"),
            mock.patch.object(subject, "command") as command,
        ):
            with self.assertRaises(ValueError):
                subject.observe(Path("/unacquired"))
            command.assert_not_called()

    def test_native_record_is_not_a_self_issued_retirement(self):
        packet = controller_record()
        packet["closed"] = True
        with self.assertRaises(ValueError):
            self.admit(packet)

    def test_oversized_integer_elapsed_and_deadline_refuse(self):
        packet = controller_record()
        packet["elapsed_seconds"] = 10**500
        with self.assertRaises(ValueError):
            self.admit(packet)
        with self.assertRaises(ValueError):
            self.admit(deadline=10**500)

    def test_positive_requires_complete_actual_call_outcomes(self):
        for key in ("acquire_errno", "valid_errno", "free_errno"):
            packet = controller_record()
            packet["native"]["nodes"][0]["acl"][key] = None
            self.assertNotEqual(self.admit(packet), "qualified")
        packet = controller_record()
        packet["native"]["nodes"][0]["close_errno"] = None
        self.assertNotEqual(self.admit(packet), "qualified")

    def test_foreign_text_values_cannot_run_equality(self):
        for port in ("source", "kind", "role"):
            calls = []

            class Foreign:
                def __eq__(self, other):
                    calls.append(other)
                    return True

            packet = controller_record()
            if port == "source":
                packet["source_hashes"]["observer"] = Foreign()
            elif port == "kind":
                packet["kind"] = Foreign()
            else:
                packet["native"]["nodes"][0]["role"] = Foreign()
            refused = False
            try:
                self.admit(packet)
            except ValueError:
                refused = True
            self.assertEqual(calls, [])
            self.assertTrue(refused)


class ModeledWorkerFlowControls(unittest.TestCase):
    """Real private files; OS/compiler/native-process endpoints explicitly modeled."""

    def exercise(self, root, *, persistence=None, native_mutation=None):
        calls = []
        sources = {}
        source_root = root / "inputs"
        source_root.mkdir()
        for key, original in subject.SOURCES.items():
            copied = source_root / original.name
            copied.write_bytes(original.read_bytes())
            sources[key] = copied

        def command(arguments, _deadline):
            calls.append(list(arguments))
            if len(calls) == 1:
                (root / "acl-ancestry").write_bytes(b"MODELED EXECUTABLE: NEVER NATIVE")
                return 201, b"", b""
            if native_mutation:
                native_mutation(root)
            return 200, (json.dumps(native_record()) + "\n").encode(), b""

        with (
            mock.patch.object(subject.sys, "platform", "darwin"),
            mock.patch.object(subject, "SOURCES", sources),
            mock.patch.object(subject, "command", side_effect=command),
        ):
            if persistence is None:
                packet = subject.observe(root)
            else:
                with mock.patch.object(subject, "persist", side_effect=persistence):
                    packet = subject.observe(root)
        return calls, packet

    def test_modeled_endpoints_produce_real_ordinary_diagnostic_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            calls, packet = self.exercise(root)
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[0][:3], ["/usr/bin/xcrun", "clang", "-std=c17"])
            self.assertIn("-D_DARWIN_C_SOURCE", calls[0])
            self.assertEqual(calls[1], [str(root / "acl-ancestry")])
            self.assertEqual(subject.read_record(root / "acl-ancestry.json"), packet)
            self.assertEqual(packet["kind"], "read_only_acl_ancestry")
            self.assertNotIn("closed", packet)

    def test_actual_persistence_crossing_deadline_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            clock = [100.0]
            original = subject.persist

            def delayed(path, packet):
                original(path, packet)
                clock[0] = 126.0

            with mock.patch.object(subject.time, "monotonic", side_effect=lambda: clock[0]):
                with self.assertRaisesRegex(ValueError, "deadline"):
                    self.exercise(root, persistence=delayed)
            self.assertTrue((root / "acl-ancestry.json").is_file())

    def test_actual_source_mutation_during_persistence_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            original = subject.persist

            def changed(path, packet):
                original(path, packet)
                with (root / "inputs/installed-vhd-acl-ancestry.c").open("ab") as stream:
                    stream.write(b"\n/* independently changed private source */\n")

            with self.assertRaisesRegex(ValueError, "changed"):
                self.exercise(root, persistence=changed)

    def test_actual_compiled_input_mutation_during_persistence_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            original = subject.persist

            def changed(path, packet):
                original(path, packet)
                (root / "acl-ancestry").write_bytes(b"CHANGED MODELED EXECUTABLE")

            with self.assertRaisesRegex(ValueError, "changed"):
                self.exercise(root, persistence=changed)


if __name__ == "__main__":
    unittest.main()
