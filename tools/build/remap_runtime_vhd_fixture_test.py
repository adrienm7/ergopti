# tools/build/remap_runtime_vhd_fixture_test.py
"""Independent real fixture tampering controls; no native identity or capture proof."""

import gzip
import hashlib
import importlib.util
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch

BUILD = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "vhd_fixture_subject", BUILD / "remap_runtime_vhd_fixture.py"
)
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)


class OfflineFixtureControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.census = subject.manifest()
        cls.raw = gzip.decompress(subject.ARCHIVE.read_bytes())
        with tarfile.open(fileobj=subject.io.BytesIO(cls.raw), mode="r:") as archive:
            cls.members = list(archive)
            cls.end = archive.offset

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="offline-fixture-control-")
        self.owner = Path(self.temporary.name).resolve(strict=True)

    def tearDown(self):
        self.temporary.cleanup()

    def refused(self, code, operation):
        with self.assertRaises(subject.FixtureRefusal) as caught:
            operation()
        self.assertEqual(caught.exception.code, code)

    def header(self, index=0, **changes):
        member = self.members[index]
        info = tarfile.TarInfo.frombuf(
            self.raw[member.offset : member.offset + 512],
            encoding="utf-8",
            errors="strict",
        )
        for name, value in changes.items():
            setattr(info, name, value)
        data = bytearray(self.raw)
        data[member.offset : member.offset + 512] = info.tobuf(format=tarfile.USTAR_FORMAT)
        return bytes(data)

    def test_actual_complete_archive_is_exact_genuine_input(self):
        entries = subject.sources()
        self.assertEqual(len(entries), 1019)
        self.assertEqual(sum(len(data) for _, data in entries), 10339208)
        self.assertEqual(
            hashlib.sha256(subject.ARCHIVE.read_bytes()).hexdigest(),
            "6389c53e3adb6cdfd13a80e0580758ac6cff4c985a26ff18dcec204be2aa5877",
        )
        self.assertEqual(self.census["upstream"], "9312593e1a3bf72b94c63c524ebabe2637442e8a")
        self.assertIn("LICENSE.md", dict(entries))
        self.assertIn("vendor/Karabiner-DriverKit-VirtualHIDDevice/LICENSE.md", dict(entries))

    def test_missing_manifest_refuses(self):
        self.refused("fixture_manifest", lambda: subject.manifest(self.owner / "absent"))

    def test_changed_manifest_refuses(self):
        path = self.owner / "manifest.json"
        path.write_bytes(subject.MANIFEST.read_bytes() + b"\n")
        self.refused("fixture_manifest", lambda: subject.manifest(path))

    def test_missing_archive_refuses(self):
        self.refused("fixture_archive", lambda: subject.sources(self.owner / "absent"))

    def test_changed_archive_refuses(self):
        path = self.owner / "archive.gz"
        data = bytearray(subject.ARCHIVE.read_bytes())
        data[-1] ^= 1
        path.write_bytes(data)
        self.refused("fixture_archive", lambda: subject.sources(path))

    def test_redirected_manifest_refuses(self):
        path = self.owner / "alias.json"
        path.symlink_to(subject.MANIFEST)
        self.refused("fixture_path", lambda: subject.manifest(path))

    def test_redirected_archive_refuses(self):
        path = self.owner / "alias.gz"
        path.symlink_to(subject.ARCHIVE)
        self.refused("fixture_path", lambda: subject.sources(path))

    def test_doubly_linked_archive_refuses(self):
        path = self.owner / "archive.gz"
        shutil.copyfile(subject.ARCHIVE, path)
        (self.owner / "alias.gz").hardlink_to(path)
        self.refused("fixture_path", lambda: subject.sources(path))

    def test_foreign_regular_name_refuses(self):
        data = self.header(name="foreign-independent.hpp")
        self.refused("fixture_inventory", lambda: subject.archive_entries(data, self.census))

    def test_duplicate_regular_name_refuses(self):
        data = self.header(index=1, name=self.members[0].name)
        self.refused("fixture_inventory", lambda: subject.archive_entries(data, self.census))

    def test_tar_link_refuses(self):
        data = self.header(type=tarfile.SYMTYPE, linkname="/independent/outside")
        self.refused("fixture_inventory", lambda: subject.archive_entries(data, self.census))

    def test_noncanonical_name_refuses(self):
        data = self.header(name="src/../LICENSE.md")
        self.refused("fixture_inventory", lambda: subject.archive_entries(data, self.census))

    def test_actual_changed_member_bytes_refuse(self):
        data = bytearray(self.raw)
        data[self.members[0].offset_data] ^= 1
        self.refused("fixture_bytes", lambda: subject.archive_entries(bytes(data), self.census))

    def test_wrong_member_mode_refuses(self):
        data = self.header(mode=0o755)
        self.refused("fixture_inventory", lambda: subject.archive_entries(data, self.census))

    def test_extra_member_refuses(self):
        extra = tarfile.TarInfo("independent-extra.hpp")
        extra.mode = 0o644
        data = bytearray(self.raw)
        data[self.end : self.end + 512] = extra.tobuf(format=tarfile.USTAR_FORMAT)
        self.refused(
            "fixture_inventory",
            lambda: subject.archive_entries(bytes(data), self.census),
        )

    def test_short_member_refuses(self):
        data = self.header(size=self.members[0].size - 1)
        self.refused("fixture_inventory", lambda: subject.archive_entries(data, self.census))

    def test_trailing_nonzero_tar_refuses(self):
        data = bytearray(self.raw)
        data[-1] = 1
        self.refused(
            "fixture_inventory",
            lambda: subject.archive_entries(bytes(data), self.census),
        )

    def test_wrong_group_refuses_before_preparing_inputs(self):
        with patch.object(subject, "sources") as sources:
            self.refused("fixture_group", lambda: subject.run_group("unknown", self.owner))
            sources.assert_not_called()

    def test_unsafe_output_owner_refuses(self):
        alias = self.owner / "alias"
        alias.symlink_to(self.owner, target_is_directory=True)
        self.refused("fixture_path", lambda: subject.publish_sources(alias, ()))

    def test_preexisting_output_leaf_refuses_without_overwrite(self):
        leaf = self.owner / "retained"
        leaf.write_bytes(b"independently retained\n")
        self.refused("fixture_path", lambda: subject.publish_sources(self.owner, ()))
        self.assertEqual(leaf.read_bytes(), b"independently retained\n")

    def test_actual_source_publication_keeps_the_complete_byte_inventory(self):
        entries = subject.sources()
        subject.publish_sources(self.owner, entries)
        files = sorted(str(p.relative_to(self.owner)) for p in self.owner.rglob("*") if p.is_file())
        self.assertEqual(files, [row["path"] for row in self.census["files"]])
        self.assertEqual(len(files), 1019)
        for row in self.census["files"]:
            data = (self.owner / row["path"]).read_bytes()
            self.assertEqual(len(data), row["bytes"])
            self.assertEqual(hashlib.sha256(data).hexdigest(), row["sha256"])
        self.assertEqual(
            (
                self.owner / "src/apps/CoreService/include/core_service/daemon/device_grabber.hpp"
            ).read_bytes(),
            dict(entries)["src/apps/CoreService/include/core_service/daemon/device_grabber.hpp"],
        )


if __name__ == "__main__":
    unittest.main()
