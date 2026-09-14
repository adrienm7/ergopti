# tools/build/karabiner_policy_test.py
"""Reject post-install mutations of the already signed fork applications."""

from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from karabiner_candidate_repack import POSTINSTALL, archive_inventory, repair_expanded
from karabiner_package_policy import ICON_CALL, immutable_installer, postinstall_policy

FIXTURE = Path(__file__).with_name("fixtures") / "karabiner-postinstall.txt"


class PackagePolicyTests(unittest.TestCase):
    def test_installer_preserves_every_operation_except_post_signing_icon_mutation(self):
        original = FIXTURE.read_bytes()
        modified = postinstall_policy(original)
        self.assertNotIn(ICON_CALL.encode(), modified)
        self.assertEqual(original.count(ICON_CALL.encode()), 1)
        self.assertEqual(original.replace(ICON_CALL.encode(), b""),
                         modified.replace(b"# Keep the signed bundle resources immutable.", b""))

    def test_changed_or_prepatched_upstream_installer_is_rejected(self):
        original = FIXTURE.read_bytes()
        for source in (original + b"exit 1\n", postinstall_policy(original), b"exit 0\n"):
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, "pinned postinstall"):
                postinstall_policy(source)

    def test_repackage_changes_only_postinstall_and_preserves_both_native_payloads(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            postinstall = root / POSTINSTALL
            postinstall.parent.mkdir(parents=True)
            postinstall.write_bytes(FIXTURE.read_bytes())
            for component in ("Installer.pkg", "Karabiner-DriverKit-VirtualHIDDevice.pkg"):
                payload = root / component / "Payload"
                payload.parent.mkdir(exist_ok=True)
                payload.write_bytes((component + " native bytes").encode())
            before = archive_inventory(root)
            after = repair_expanded(root)
            self.assertEqual(set(before), set(after))
            self.assertEqual([name for name in before if before[name] != after[name]], [POSTINSTALL])
            self.assertNotIn(ICON_CALL.encode(), postinstall.read_bytes())
            self.assertEqual(after, archive_inventory(root))
            postinstall.write_bytes(b"unexpected installer")
            with self.assertRaisesRegex(ValueError, "pinned postinstall"):
                repair_expanded(root)

    def test_fresh_assembly_restores_upstream_source_even_on_failure(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "postinstall"
            original = FIXTURE.read_bytes()
            path.write_bytes(original)
            with self.assertRaisesRegex(RuntimeError, "assembly failed"):
                with immutable_installer(path):
                    self.assertNotIn(ICON_CALL.encode(), path.read_bytes())
                    raise RuntimeError("assembly failed")
            self.assertEqual(path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
