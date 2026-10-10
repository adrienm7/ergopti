"""Independent real-file metadata controls; no native or permission simulation."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import tempfile
import time
import unittest
from unittest.mock import patch

import installed_target_reader as subject

DICTIONARY = b'<?xml version="1.0"?><dictionary><suite name="fixture" code="TEST"/></dictionary>\n'


class InstalledTargetReaderTests(unittest.TestCase):
    """Exercise actual owned files against fixed independent byte expectations."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.bundle = Path(self.temporary.name).resolve() / "Owned.app"
        self.resources = self.bundle / "Contents" / "Resources"
        self.resources.mkdir(parents=True)
        self.info = self.bundle / "Contents" / "Info.plist"
        self.dictionary = self.resources / "Owned.sdef"
        self.dictionary.write_bytes(DICTIONARY)
        self.write_info()

    def write_info(self, **values):
        info = {
            "CFBundleIdentifier": "com.apple.shortcuts.events",
            "OSAScriptingDefinition": "Owned.sdef",
        }
        info.update(values)
        self.info.write_bytes(plistlib.dumps(info))

    def read(self):
        return subject.read_bundle(str(self.bundle), time.monotonic() + 20.0)

    def refuse(self, reason):
        with self.assertRaisesRegex(subject.MetadataRefused, "^" + reason + "$"):
            self.read()

    def test_exact_xml_source_bytes_and_metadata_only(self):
        before_info = self.info.read_bytes()
        before_dictionary = self.dictionary.read_bytes()
        receipt, info_raw, dictionary_raw = self.read()
        self.assertEqual(info_raw, before_info)
        self.assertEqual(dictionary_raw, DICTIONARY)
        self.assertEqual(receipt["info_sha256"], hashlib.sha256(before_info).hexdigest())
        self.assertEqual(receipt["dictionary_sha256"], hashlib.sha256(DICTIONARY).hexdigest())
        self.assertEqual(receipt["dictionary_bytes"], len(DICTIONARY))
        self.assertEqual(receipt["declaration_keys"], ["OSAScriptingDefinition"])
        for name in (
            "running_target_observed",
            "catalogue_observed",
            "permission_observed",
            "invocation_qualified",
        ):
            self.assertIs(receipt[name], False)
        self.assertEqual(self.info.read_bytes(), before_info)
        self.assertEqual(self.dictionary.read_bytes(), before_dictionary)

    def test_binary_plist_explicit_ns_declaration(self):
        raw = plistlib.dumps(
            {
                "CFBundleIdentifier": "com.apple.shortcuts.events",
                "NSScriptingDefinition": "Owned.sdef",
            },
            fmt=plistlib.FMT_BINARY,
        )
        self.info.write_bytes(raw)
        receipt, observed, dictionary = self.read()
        self.assertEqual(observed, raw)
        self.assertEqual(dictionary, DICTIONARY)
        self.assertEqual(receipt["declaration_keys"], ["NSScriptingDefinition"])

    def test_both_explicit_identical_declarations(self):
        self.write_info(NSScriptingDefinition="Owned.sdef")
        self.assertEqual(
            self.read()[0]["declaration_keys"], ["OSAScriptingDefinition", "NSScriptingDefinition"]
        )

    def test_wrong_identifier(self):
        self.write_info(CFBundleIdentifier="com.apple.shortcuts")
        self.refuse("bundle_identifier")

    def test_no_declared_dictionary_even_when_file_exists(self):
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.apple.shortcuts.events"}))
        self.refuse("dictionary_undeclared")

    def test_conflicting_declared_dictionaries(self):
        self.write_info(NSScriptingDefinition="Different.sdef")
        self.refuse("dictionary_conflict")

    def test_missing_exact_declared_dictionary(self):
        self.dictionary.unlink()
        (self.resources / "Other.sdef").write_bytes(DICTIONARY)
        self.refuse("metadata_io")

    def test_no_extension_guess(self):
        self.write_info(OSAScriptingDefinition="Owned")
        self.refuse("metadata_io")

    def test_traversal_absolute_and_nonstring_declarations(self):
        for value in ("../Owned.sdef", "/Owned.sdef", "nested/Owned.sdef", "", 1, False):
            with self.subTest(value=value):
                self.write_info(OSAScriptingDefinition=value)
                self.refuse("dictionary_declaration")

    def test_dictionary_symlink_refused(self):
        self.dictionary.unlink()
        target = self.resources / "Foreign.sdef"
        target.write_bytes(DICTIONARY)
        self.dictionary.symlink_to(target)
        self.refuse("metadata_io")

    def test_bundle_ancestor_symlink_refused(self):
        alias = Path(self.temporary.name) / "Alias.app"
        alias.symlink_to(self.bundle, target_is_directory=True)
        with self.assertRaisesRegex(subject.MetadataRefused, "^metadata_io$"):
            subject.read_bundle(str(alias), time.monotonic() + 20.0)

    def test_fifo_and_empty_dictionary_refused(self):
        self.dictionary.unlink()
        os.mkfifo(self.dictionary)
        self.refuse("dictionary_type")
        self.dictionary.unlink()
        self.dictionary.write_bytes(b"")
        self.refuse("dictionary_bound")

    def test_oversized_source_files_refused(self):
        self.dictionary.write_bytes(b"x" * 65537)
        self.refuse("dictionary_bound")
        self.dictionary.write_bytes(DICTIONARY)
        self.info.write_bytes(b"x" * 65537)
        self.refuse("info_bound")

    def test_malformed_and_duplicate_plist_refused(self):
        self.info.write_bytes(b"not a plist")
        self.refuse("info_shape")
        self.info.write_bytes(b"""<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>wrong</string>
<key>CFBundleIdentifier</key><string>com.apple.shortcuts.events</string>
<key>OSAScriptingDefinition</key><string>Owned.sdef</string></dict></plist>""")
        self.refuse("info_shape")

    def test_dictionary_named_entry_replacement_refused(self):
        original = os.read
        changed = False

        def replacing(fd, count):
            nonlocal changed
            raw = original(fd, count)
            if raw == DICTIONARY and not changed:
                replacement = self.resources / "replacement"
                replacement.write_bytes(DICTIONARY)
                os.replace(replacement, self.dictionary)
                changed = True
            return raw

        with patch.object(subject.os, "read", replacing):
            with self.assertRaises(subject.MetadataRefused) as refusal:
                self.read()
        self.assertTrue(changed)
        self.assertIn(str(refusal.exception), ("source_changed", "source_replaced"))

    def test_retained_descriptors_all_closed_on_refusal(self):
        self.write_info(CFBundleIdentifier="wrong")
        original_open, original_close = os.open, os.close
        opened, closed = [], []

        def opening(*args, **kwargs):
            fd = original_open(*args, **kwargs)
            opened.append(fd)
            return fd

        def closing(fd):
            closed.append(fd)
            return original_close(fd)

        with patch.object(subject.os, "open", opening), patch.object(subject.os, "close", closing):
            self.refuse("bundle_identifier")
        self.assertGreater(len(opened), 2)
        self.assertEqual(closed, list(reversed(opened)))

    def test_original_deadline_not_refreshed(self):
        with self.assertRaisesRegex(subject.MetadataRefused, "^deadline$"):
            subject.read_bundle(str(self.bundle), time.monotonic() - 1.0)

    def test_resolution_exact_target_and_single_native_route(self):
        raw = json.dumps(
            {
                "version": 1,
                "status": "resolved",
                "target": "com.apple.shortcuts.events",
                "urls": [str(self.bundle)],
            }
        ).encode()
        self.assertEqual(subject.resolution_path(raw), str(self.bundle))

    def test_resolution_foreign_duplicate_ambiguous_and_traversal_refused(self):
        packet = {
            "version": 1,
            "status": "resolved",
            "target": "com.apple.shortcuts.events",
            "urls": [str(self.bundle)],
        }
        bad = [
            dict(packet, target="com.apple.shortcuts"),
            dict(packet, urls=[]),
            dict(packet, urls=[str(self.bundle), str(self.bundle)]),
            dict(packet, urls=["/Applications/../Owned.app"]),
            dict(packet, version=True),
        ]
        for value in bad:
            with self.subTest(value=value), self.assertRaises(subject.MetadataRefused):
                subject.resolution_path(json.dumps(value).encode())
        with self.assertRaisesRegex(subject.MetadataRefused, "^resolution_duplicate$"):
            subject.resolution_path(b'{"version":1,"version":1}')


if __name__ == "__main__":
    unittest.main()
