# tools/build/remap_runtime_publish_test.py
"""Pin the owned runtime packager: reproducible bytes, closed tree, exact pin."""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "remap_runtime_publish", Path(__file__).with_name("remap_runtime_publish.py")
)
SUBJECT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SUBJECT
SPEC.loader.exec_module(SUBJECT)

MANIFEST = Path(__file__).resolve().parents[2] / SUBJECT.MANIFEST_RELATIVE


def make_tree(root, *, extra=None):
    """Writes a fake signed tree with the three products."""
    root = Path(root)
    for relative in SUBJECT.REQUIRED_MEMBERS:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"\xcf\xfa\xed\xfe" + relative.encode())
        path.chmod(0o755)
    plist = root / "Runtime/ErgoptiPlus-Remap-Core.app/Contents/Info.plist"
    plist.write_bytes(b"<plist/>")
    plist.chmod(0o644)
    for path in sorted(root.rglob("*")):
        if path.is_dir():
            path.chmod(0o755)
    (root / "Runtime").chmod(0o755)
    if extra:
        extra(root)
    return root


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.base = Path(self.scratch.name)

    def tearDown(self):
        self.scratch.cleanup()

    def test_same_tree_gives_same_bytes(self):
        first = make_tree(self.base / "a")
        second = make_tree(self.base / "b")
        os.utime(second / SUBJECT.REQUIRED_MEMBERS[0], (1, 1))
        self.assertEqual(SUBJECT.archive_bytes(first), SUBJECT.archive_bytes(second))

    def test_changed_product_changes_digest(self):
        first = make_tree(self.base / "a")
        second = make_tree(self.base / "b")
        (second / SUBJECT.REQUIRED_MEMBERS[2]).write_bytes(b"other")
        self.assertNotEqual(
            hashlib.sha256(SUBJECT.archive_bytes(first)).digest(),
            hashlib.sha256(SUBJECT.archive_bytes(second)).digest(),
        )

    def test_members_are_normalized(self):
        data = SUBJECT.archive_bytes(make_tree(self.base / "a"))
        self.assertEqual(data[4:8], b"\x00\x00\x00\x00", "gzip header carries no time")
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            members = archive.getmembers()
        self.assertEqual([m.name for m in members], sorted(m.name for m in members))
        for member in members:
            self.assertEqual((member.uid, member.gid, member.mtime, member.uname), (0, 0, 0, ""))

    def test_link_is_refused(self):
        def link(root):
            os.symlink("bin", root / "Runtime/alias")

        tree = make_tree(self.base / "a", extra=link)
        with self.assertRaisesRegex(SUBJECT.PublishRefusal, "alias"):
            SUBJECT.archive_bytes(tree)

    def test_missing_product_is_refused(self):
        tree = make_tree(self.base / "a")
        (tree / SUBJECT.REQUIRED_MEMBERS[1]).unlink()
        with self.assertRaisesRegex(SUBJECT.PublishRefusal, "missing signed product"):
            SUBJECT.archive_bytes(tree)

    def test_writable_mode_is_refused(self):
        tree = make_tree(self.base / "a")
        (tree / SUBJECT.REQUIRED_MEMBERS[2]).chmod(0o775)
        with self.assertRaisesRegex(SUBJECT.PublishRefusal, "mode"):
            SUBJECT.archive_bytes(tree)

    def test_package_writes_a_pin_the_archive_satisfies(self):
        pin = SUBJECT.package(make_tree(self.base / "a"), self.base / "out")
        data = (self.base / "out" / pin["file_name"]).read_bytes()
        self.assertEqual(pin["size"], len(data))
        self.assertEqual(pin["sha256"], hashlib.sha256(data).hexdigest())
        self.assertTrue(pin["source_url"].endswith("/" + pin["file_name"]))
        self.assertTrue(
            pin["source_url"].startswith("https://github.com/adrienm7/ergopti/releases/download/")
        )
        self.assertEqual(json.loads((self.base / "out/runtime-pin.json").read_text()), pin)
        tampered = dict(pin, sha256="0" * 64)
        with self.assertRaisesRegex(SUBJECT.PublishRefusal, "digest"):
            SUBJECT.verify_archive(data, tampered)

    def test_apply_pin_changes_only_the_runtime_fields(self):
        copy = self.base / "manifest.json"
        copy.write_text(MANIFEST.read_text(encoding="utf-8"), encoding="utf-8")
        before = json.loads(copy.read_text())
        pin = SUBJECT.package(make_tree(self.base / "a"), self.base / "out")
        after = SUBJECT.apply_pin(copy, pin)
        for key in SUBJECT.PIN_KEYS:
            self.assertEqual(after["runtime"][key], pin[key])
        for group in ("virtual_hid_device", "capture"):
            self.assertEqual(after[group], before[group])
        self.assertEqual(
            after["runtime"]["upstream_revision"], before["runtime"]["upstream_revision"]
        )
        with self.assertRaisesRegex(SUBJECT.PublishRefusal, "exactly"):
            SUBJECT.apply_pin(copy, dict(pin, extra=1))

    def test_version_has_the_shape_the_driver_accepts(self):
        self.assertRegex(SUBJECT.RUNTIME_VERSION, r"^\d+\.\d+\.\d+[\w.\-+]*$")
        self.assertRegex(SUBJECT.file_name(), r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


if __name__ == "__main__":
    unittest.main()
