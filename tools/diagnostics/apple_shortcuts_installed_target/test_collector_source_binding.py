"""Portable loader/output controls, not native process or LaunchServices proofs."""

import hashlib
import importlib.util
import marshal
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

import collect_installed_target as subject

ORIGINAL = b'MARKER = "validated original bytes"\n'
FOREIGN = b'MARKER = "foreign code was executed"\n'
OWNER_ROOT = Path(__file__).parent.parent / "dependencies"
OWNER_ROLE = "tools/diagnostics/macos_owned_process.py"


class SourceBindingTests(unittest.TestCase):
    """Control the loader against actual files and independently fixed markers."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "component.py"
        self.source.write_bytes(ORIGINAL)
        self.expected = {"component.py": hashlib.sha256(ORIGINAL).hexdigest()}

    def load_component(self):
        # This trust input belongs solely to a component fixture, not a native owner.
        with patch.object(subject, "DEPENDENCIES", self.expected):
            return subject.load_original(self.root, "component.py", "fixture_component")

    def test_exact_retained_actual_owner_image(self):
        module = subject.load_original(OWNER_ROOT, OWNER_ROLE, "retained_original_owner")
        self.assertEqual(module.OwnedProcessError.__module__, "retained_original_owner")
        self.assertEqual(module.acquire_owned.__code__.co_filename, str(OWNER_ROOT / OWNER_ROLE))
        self.assertIsNone(module.__loader__)
        self.assertIsNone(module.__cached__)
        self.assertTrue(issubclass(module.OwnedProcessInterrupted, module.OwnedProcessError))

    def test_changed_timestamp_valid_pyc_is_never_executed(self):
        cache = Path(importlib.util.cache_from_source(str(self.source)))
        cache.parent.mkdir()
        info = self.source.stat()
        header = importlib.util.MAGIC_NUMBER + struct.pack(
            "<III", 0, int(info.st_mtime), len(ORIGINAL)
        )
        foreign_code = compile(FOREIGN, str(self.source), "exec")
        cache.write_bytes(header + marshal.dumps(foreign_code))
        module = self.load_component()
        self.assertEqual(module.MARKER, "validated original bytes")
        self.assertIsNone(module.__cached__)
        self.assertEqual(self.source.read_bytes(), ORIGINAL)

    def test_wrong_source_digest_refuses_before_any_execution(self):
        self.source.write_bytes(b'raise AssertionError("foreign execution")\n')
        with self.assertRaisesRegex(subject.MetadataRefused, "^source_refused$"):
            self.load_component()

    def test_named_source_replacement_during_read_refuses_before_execution(self):
        read = os.read
        changed = False

        def replacing(fd, count):
            nonlocal changed
            raw = read(fd, count)
            if raw == ORIGINAL and not changed:
                replacement = self.root / "replacement"
                replacement.write_bytes(FOREIGN)
                os.replace(replacement, self.source)
                changed = True
            return raw

        with patch.object(subject.os, "read", replacing):
            with self.assertRaisesRegex(subject.MetadataRefused, "^source_changed$"):
                self.load_component()
        self.assertTrue(changed)

    def test_change_after_validated_read_cannot_reopen_foreign_source(self):
        retained = subject.retained_source

        def after_read(path):
            raw = retained(path)
            self.source.write_bytes(FOREIGN)
            return raw

        with patch.object(subject, "retained_source", after_read):
            module = self.load_component()
        self.assertEqual(module.MARKER, "validated original bytes")
        self.assertEqual(self.source.read_bytes(), FOREIGN)

    def test_final_source_symlink_refused(self):
        alias = self.root / "alias.py"
        alias.symlink_to(self.source)
        with self.assertRaises(OSError):
            subject.retained_source(alias)

    def test_source_ancestor_symlink_refused(self):
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            subject.retained_source(alias / self.source.name)

    def test_all_source_descriptors_closed_after_read_refusal(self):
        opening, closing = os.open, os.close
        opened, closed = [], []
        self.source.write_bytes(b"x" * 65537)

        def tracked_open(*args, **kwargs):
            fd = opening(*args, **kwargs)
            opened.append(fd)
            return fd

        def tracked_close(fd):
            closed.append(fd)
            return closing(fd)

        with (
            patch.object(subject.os, "open", tracked_open),
            patch.object(subject.os, "close", tracked_close),
        ):
            with self.assertRaisesRegex(subject.MetadataRefused, "^source_refused$"):
                subject.retained_source(self.source)
        self.assertEqual(closed, list(reversed(opened)))


class OutputCustodyTests(unittest.TestCase):
    """Observe real private entries and exact primary errors, never native success."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name).resolve()
        self.path = self.parent / "receipt"

    def test_exclusive_directory_and_file_bytes(self):
        output = subject.OwnedOutput(self.path)
        try:
            output.write("dictionary.source", b"original dictionary bytes")
            self.assertEqual(
                (self.path / "dictionary.source").read_bytes(), b"original dictionary bytes"
            )
            with self.assertRaises(FileExistsError):
                output.write("dictionary.source", b"replacement")
            self.assertEqual(
                (self.path / "dictionary.source").read_bytes(), b"original dictionary bytes"
            )
        finally:
            output.close()

    def test_moved_output_refuses_without_writing_foreign_replacement(self):
        output = subject.OwnedOutput(self.path)
        old = self.parent / "old"
        self.path.rename(old)
        self.path.mkdir()
        try:
            with self.assertRaisesRegex(subject.MetadataRefused, "^output_replaced$"):
                output.write("observation.json", b"{}")
            self.assertEqual(list(self.path.iterdir()), [])
            self.assertEqual(list(old.iterdir()), [])
        finally:
            output.close()

    def test_symlink_receiving_parent_and_existing_destination_refused(self):
        alias = self.parent / "alias"
        alias.symlink_to(self.parent, target_is_directory=True)
        with self.assertRaises(OSError):
            subject.OwnedOutput(alias / "receipt")
        self.path.mkdir()
        with self.assertRaises(FileExistsError):
            subject.OwnedOutput(self.path)

    def test_original_cancellation_has_priority_over_receipt_io(self):
        original_owner = subject.load_original(OWNER_ROOT, OWNER_ROLE, "priority_original_owner")
        primary = original_owner.OwnedProcessInterrupted("actual owner exception type")
        output = subject.OwnedOutput(self.path)
        (self.path / "observation.json").write_bytes(b"occupied")
        with self.assertRaises(original_owner.OwnedProcessInterrupted) as refusal:
            subject.finish_observation(output, {"status": "refused"}, primary)
        self.assertIs(refusal.exception, primary)
        self.assertIsNone(output.fd)
        self.assertEqual(output.directory.descriptors, [])
        self.assertEqual((self.path / "observation.json").read_bytes(), b"occupied")

    def test_original_retirement_error_has_priority_over_lost_output_name(self):
        original_owner = subject.load_original(OWNER_ROOT, OWNER_ROLE, "priority_debt_owner")
        primary = original_owner.OwnedProcessError("exact retirement refusal object")
        output = subject.OwnedOutput(self.path)
        self.path.rename(self.parent / "old")
        with self.assertRaises(original_owner.OwnedProcessError) as refusal:
            subject.finish_observation(output, {"status": "refused"}, primary)
        self.assertIs(refusal.exception, primary)
        self.assertIsNone(output.fd)
        self.assertEqual(output.directory.descriptors, [])

    def test_receipt_refusal_without_pending_primary_is_not_success(self):
        output = subject.OwnedOutput(self.path)
        (self.path / "observation.json").write_bytes(b"occupied")
        with self.assertRaises(FileExistsError):
            subject.finish_observation(output, {"status": "metadata_observed"}, None)
        self.assertIsNone(output.fd)
        self.assertEqual(output.directory.descriptors, [])

    def test_completed_receipt_exact_bytes_and_closed_resources(self):
        output = subject.OwnedOutput(self.path)
        subject.finish_observation(output, {"status": "metadata_observed"}, None)
        self.assertEqual(
            (self.path / "observation.json").read_bytes(), b'{"status":"metadata_observed"}\n'
        )
        self.assertIsNone(output.fd)
        self.assertEqual(output.directory.descriptors, [])


if __name__ == "__main__":
    unittest.main()
