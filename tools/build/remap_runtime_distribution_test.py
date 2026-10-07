# tools/build/remap_runtime_distribution_test.py
"""Preimplementation ordinary archive controls; Darwin and compiler leaves are absent."""

import copy
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tarfile
import tempfile
import time
import unittest
from unittest import mock

HERE = Path(__file__).parent
PRODUCTS = (
    "Runtime/ErgoptiPlus-Remap-Core.app",
    "Runtime/ErgoptiPlus-Remap-Console.app",
    "Runtime/bin/ergoptiplus_remap_cli",
)


def subject():
    path = Path(os.environ.get("WP5_DISTRIBUTION_MODULE", HERE / "remap_runtime_distribution.py"))
    spec = importlib.util.spec_from_file_location("ordinary_distribution_subject", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class DistributionControls(unittest.TestCase):
    """Independent extraction and actual POSIX output ownership; no native trust."""

    def setUp(self):
        self.module = subject()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.owner = Path(self.temporary.name).resolve()
        self.owner.chmod(0o700)
        self.deadline = time.monotonic() + 10
        self.calls = 0
        self.hook = None
        self.directories = [("Runtime", 0o755), ("Runtime/bin", 0o755)]
        self.members = [(PRODUCTS[2], 0o755, b"MODELED CLI EXECUTABLE")]
        for product in PRODUCTS[:2]:
            for suffix in ("", "/Contents", "/Contents/MacOS", "/Contents/_CodeSignature"):
                self.directories.append((product + suffix, 0o755))
            self.members.extend(
                [
                    (
                        product + "/Contents/MacOS/" + Path(product).stem,
                        0o755,
                        b"MODELED EXECUTABLE",
                    ),
                    (product + "/Contents/Info.plist", 0o644, b"MODELED PLIST"),
                    (
                        product + "/Contents/_CodeSignature/CodeResources",
                        0o644,
                        b"MODELED RESOURCES",
                    ),
                ]
            )
        self.provenance = {
            "schema": 1,
            "scope": "captured_live_export_inputs",
            "test_only": True,
            "pins": {
                name: str(index) * 40 for index, name in enumerate(("upstream", "cpm", "vhd"), 1)
            },
            "identity": {"certificate_sha1": "A" * 40, "public_leaf_sha256": "b" * 64},
            "sources": {
                "owned_inputs": [{"path": "tools/build/owned.py", "bytes": 8, "sha256": "c" * 64}],
                "staged_inputs": [{"path": "src/share/owned.hpp", "bytes": 9, "sha256": "d" * 64}],
                "staged_links": [],
            },
            "native_observations": [
                {
                    "phase": phase,
                    "stdout_bytes": 8,
                    "stdout_sha256": "e" * 64,
                    "stderr_bytes": 0,
                    "stderr_sha256": hashlib.sha256(b"").hexdigest(),
                }
                for phase in ("xcode_version", "xcodegen_version", "sdk_path")
            ],
            "shipping_qualified": False,
            "installation_qualified": False,
            "authentication_qualified": False,
        }

    def current(self):
        self.calls += 1
        if self.hook is not None:
            return self.hook(self.calls)
        return True

    def export(self):
        return self.module.export_live(
            self.owner,
            tuple(self.directories),
            tuple(self.members),
            self.provenance,
            self.deadline,
            self.current,
        )

    def refusal(self, code):
        with self.assertRaises(self.module.DistributionRefusal) as caught:
            self.export()
        self.assertEqual(caught.exception.code, code)

    def observed(self, result):
        self.assertEqual(result.status, "prepared_test_only_distribution")
        self.assertTrue(result.test_only)
        self.assertFalse(result.shipping_qualified)
        self.assertFalse(result.installation_qualified)
        self.assertFalse(result.authentication_qualified)
        root = self.owner / ".test-only-runtime-distribution"
        self.assertEqual(result.root, root)
        archive = (root / "runtime.tar.gz").read_bytes()
        self.assertEqual(
            (root / "runtime.sha256").read_text(),
            hashlib.sha256(archive).hexdigest() + "  runtime.tar.gz\n",
        )
        self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
        for path in root.iterdir():
            self.assertTrue(path.is_file())
            self.assertFalse(path.is_symlink())
            self.assertEqual(path.stat().st_nlink, 1)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
            observed = tar.getmembers()
            self.assertEqual(
                [m.name for m in observed],
                sorted(
                    [p for p, _ in self.directories]
                    + [p for p, _, _ in self.members]
                    + ["PROVENANCE.json"]
                ),
            )
            for member in observed:
                self.assertEqual(
                    (member.uid, member.gid, member.uname, member.gname, member.mtime),
                    (0, 0, "", "", 0),
                )
                self.assertEqual(member.pax_headers, {})
                if member.name == "PROVENANCE.json":
                    self.assertEqual(member.mode, 0o644)
                    self.assertEqual(json.loads(tar.extractfile(member).read()), self.provenance)
                elif member.isdir():
                    self.assertEqual(member.mode, 0o755)
                else:
                    original = next(row for row in self.members if row[0] == member.name)
                    self.assertEqual(member.mode, original[1])
                    self.assertEqual(tar.extractfile(member).read(), original[2])
        self.assertEqual(json.loads((root / "provenance.json").read_bytes()), self.provenance)
        self.assertGreater(self.calls, 12)
        return archive

    def test_complete_fixed_payload_and_independent_extraction(self):
        self.observed(self.export())

    def test_enumeration_order_and_time_do_not_change_container_bytes(self):
        first = self.observed(self.export())
        other = Path(self.temporary.name) / "second"
        other.mkdir(mode=0o700)
        self.owner = other
        self.directories.reverse()
        self.members.reverse()
        with mock.patch.dict(os.environ, {"TZ": "Pacific/Honolulu"}):
            second = self.observed(self.export())
        self.assertEqual(first, second)
        self.assertEqual(first[4:8], b"\0\0\0\0")
        self.assertEqual(gzip.decompress(first), gzip.decompress(second))

    def test_fourth_product_refuses(self):
        self.members.append(("Runtime/Foreign.app/Contents/MacOS/Foreign", 0o755, b"foreign"))
        self.refusal("inventory")

    def test_static_library_and_provider_installer_refuse(self):
        for name in ("Runtime/libduktape.a", "Runtime/VirtualHIDDevice.pkg"):
            with self.subTest(name=name):
                self.members.append((name, 0o644, b"foreign"))
                self.refusal("inventory")
                self.members.pop()

    def test_applications_payload_refuses(self):
        self.members.append(("Applications/ErgoptiPlus.app", 0o644, b"foreign"))
        self.refusal("inventory")

    def test_missing_required_object_refuses(self):
        for index in range(len(self.members)):
            with self.subTest(index=index):
                removed = self.members.pop(index)
                self.refusal("inventory")
                self.members.insert(index, removed)

    def test_duplicate_file_or_directory_refuses(self):
        self.members.append(self.members[0])
        self.refusal("inventory")
        self.members.pop()
        self.directories.append(self.directories[0])
        self.refusal("inventory")

    def test_escape_absolute_and_noncanonical_member_names_refuse(self):
        for path in (
            "/Runtime/foreign",
            "Runtime/../foreign",
            "Runtime//foreign",
            "Runtime/./foreign",
            "Runtime\\foreign",
            "Runtime\nforeign",
        ):
            with self.subTest(path=path):
                self.members.append((path, 0o644, b"foreign"))
                self.refusal("inventory")
                self.members.pop()

    def test_unknown_member_kind_or_nonbytes_refuses(self):
        self.members[0] = (self.members[0][0], 0o755, "text is not held bytes")
        self.refusal("inventory")

    def test_executable_resource_mode_refuses(self):
        self.members.append((PRODUCTS[0] + "/Contents/foreign", 0o755, b"foreign"))
        self.refusal("inventory")

    def test_hidden_credentials_and_undeclared_code_refuse(self):
        for name in (
            "private-key.pem",
            "identity.p12",
            "fixture.keychain-db",
            "build.log",
            "foreign.dylib",
            "foreign.so",
        ):
            with self.subTest(name=name):
                self.members.append((PRODUCTS[0] + "/Contents/" + name, 0o644, b"foreign"))
                self.refusal("inventory")
                self.members.pop()

    def test_undeclared_macho_content_refuses(self):
        self.members.append(
            (PRODUCTS[0] + "/Contents/Resource", 0o644, bytes.fromhex("cffaedfe") + b"foreign")
        )
        self.refusal("inventory")

    def test_source_provenance_requires_closed_nonempty_categories(self):
        self.provenance["sources"]["owned_inputs"] = []
        self.refusal("provenance")

    def test_unknown_pin_or_digest_refuses(self):
        self.provenance["pins"]["upstream"] = "unknown"
        self.refusal("provenance")

    def test_duplicate_and_private_source_paths_refuse(self):
        rows = self.provenance["sources"]["owned_inputs"]
        rows.append(copy.deepcopy(rows[0]))
        self.refusal("provenance")
        rows.pop()
        rows[0]["path"] = "/private/keychain"
        self.refusal("provenance")

    def test_production_boolean_cannot_promote_mechanical_container(self):
        for field in (
            "test_only",
            "shipping_qualified",
            "installation_qualified",
            "authentication_qualified",
        ):
            with self.subTest(field=field):
                prior = self.provenance[field]
                self.provenance[field] = not prior
                self.refusal("provenance")
                self.provenance[field] = prior

    def test_guard_unknown_and_late_refusal_never_return_outcome(self):
        self.hook = lambda _: None
        self.refusal("source_current")
        self.assertFalse((self.owner / ".test-only-runtime-distribution").exists())
        self.hook = lambda n: n < 12
        self.refusal("source_current")

    def test_nested_caught_export_cannot_publish_outer_outcome(self):
        entered = False

        def hook(_):
            nonlocal entered
            if not entered:
                entered = True
                with self.assertRaises(self.module.DistributionRefusal) as caught:
                    self.export()
                self.assertEqual(caught.exception.code, "reentered")
            return True

        self.hook = hook
        self.refusal("reentered")

    def test_expired_budget_refuses_before_allocating(self):
        self.deadline = time.monotonic() - 1
        self.refusal("deadline")
        self.assertFalse((self.owner / ".test-only-runtime-distribution").exists())

    def test_existing_output_is_preserved(self):
        root = self.owner / ".test-only-runtime-distribution"
        root.mkdir(mode=0o700)
        foreign = root / "foreign"
        foreign.write_bytes(b"preserve")
        self.refusal("collision")
        self.assertEqual(foreign.read_bytes(), b"preserve")

    def test_linked_owner_refuses_without_touching_target(self):
        target = self.owner
        link = target / "linked"
        link.symlink_to(target, target_is_directory=True)
        self.owner = link
        self.refusal("owner")
        self.assertFalse((target / ".test-only-runtime-distribution").exists())

    def test_same_byte_source_incarnation_replacement_is_not_guard_ack(self):
        self.hook = lambda _: False
        self.refusal("source_current")

    def test_owner_incarnation_replacement_refuses(self):
        original = self.owner
        old_stamp = original.stat()
        parent = original / "parent"
        parent.mkdir(mode=0o700)
        self.owner = parent / "owner"
        self.owner.mkdir(mode=0o700)

        def hook(n):
            if n == 5:
                self.owner.rename(parent / "original")
                self.owner.mkdir(mode=0o700)
            return True

        self.hook = hook
        self.refusal("owner")
        self.assertEqual(original.stat().st_ino, old_stamp.st_ino)

    def test_late_close_error_has_no_positive_outcome(self):
        real_close = self.module.os.close
        refused = False

        def close(fd):
            nonlocal refused
            real_close(fd)
            if not refused:
                refused = True
                raise OSError("MODELED close refusal after actual close")

        with mock.patch.object(self.module.os, "close", side_effect=close):
            self.refusal("io")
        self.assertTrue(refused)

    def test_final_directory_close_cannot_hide_output_root_replacement(self):
        real_close = self.module.os.close
        changed = False

        def close(fd):
            nonlocal changed
            is_directory = stat.S_ISDIR(os.fstat(fd).st_mode)
            real_close(fd)
            if is_directory and not changed:
                changed = True
                root = self.owner / ".test-only-runtime-distribution"
                root.rename(self.owner / "original-closed-root")
                root.mkdir(mode=0o700)

        with mock.patch.object(self.module.os, "close", side_effect=close):
            self.refusal("owner")
        self.assertTrue(changed)

    def test_unsupported_ustar_basename_refuses_before_output_allocation(self):
        self.members.append((PRODUCTS[0] + "/Contents/" + "a" * 180, 0o644, b"resource"))
        self.refusal("inventory")
        self.assertFalse((self.owner / ".test-only-runtime-distribution").exists())


if __name__ == "__main__":
    unittest.main()
