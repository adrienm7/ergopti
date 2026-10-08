# tools/diagnostics/hs274_native_build_test.py
"""Independent controller contract, authored before receiving implementation."""

import hashlib
import io
import zipfile
import stat
import socket
import ssl
import struct
import warnings
import importlib.util
import inspect
import urllib.error
import urllib.parse
import urllib.request
import json
import os
import subprocess
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock


def digest(data):
    return hashlib.sha256(data).hexdigest()


MODULE_PATH = Path(__file__).resolve().with_name("hs274_native_build.py")
spec = importlib.util.spec_from_file_location("native_build_subject", MODULE_PATH)
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)


class ControllerContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ergopti-build-independent-")
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def refused(self, code, operation, *args):
        with self.assertRaises(subject.NativeBuildError) as failure:
            operation(*args)
        self.assertEqual(failure.exception.code, code)
        return failure.exception

    def seal(self, rows=None, patch=None, filename="candidate.json"):
        old = b"// old independent source\n"
        new = b"// new independent source\n"
        if patch is None:
            patch = b"--- a/hs274-existing.hpp\n+++ b/hs274-existing.hpp\n@@ -1 +1 @@\n-// old independent source\n+// new independent source\n"
        patch_path = self.root / "candidate.patch"
        patch_path.write_bytes(patch)
        data = {
            "schema": 1,
            "purpose": "inactive-native-compilation-only",
            "patch_file": patch_path.name,
            "patch_sha256": digest(patch),
            "files": rows
            if rows is not None
            else [
                {
                    "path": "hs274-existing.hpp",
                    "preimage_sha256": digest(old),
                    "candidate_sha256": digest(new),
                }
            ],
        }
        path = self.root / filename
        path.write_text(json.dumps(data) + "\n")
        return path, data

    def destination(self):
        target = self.root / "diagnostics"
        target.mkdir(mode=0o700)
        (target / "hs274-existing.hpp").write_bytes(b"// old independent source\n")
        return target

    def test_budget_accepts_both_closed_endpoints(self):
        self.assertEqual(subject.validate_budget(1), 1)
        self.assertEqual(subject.validate_budget(300), 300)

    def test_budget_rejects_boolean_float_and_out_of_range(self):
        for value in [False, True, 0, -1, 301, 1.0, "30", None, float("nan")]:
            with self.subTest(value=value):
                self.refused("invalid_budget", subject.validate_budget, value)

    def test_owner_accepts_exact_private_directory(self):
        self.assertEqual(subject.validate_owner_root(self.root), self.root)

    def test_owner_refuses_relative_missing_and_regular_file(self):
        regular = self.root / "ordinary"
        regular.write_text("owned\n")
        for path in [Path("relative-owner"), self.root / "missing", regular]:
            with self.subTest(path=path):
                self.refused("owner_path", subject.validate_owner_root, path)

    def test_owner_refuses_nonprivate_permissions(self):
        self.root.chmod(0o750)
        self.refused("owner_mode", subject.validate_owner_root, self.root)

    def test_owner_refuses_symlink_and_symlink_parent(self):
        link = self.root / "alias"
        real = self.root / "real"
        real.mkdir(mode=0o700)
        child = real / "child"
        child.mkdir(mode=0o700)
        link.symlink_to(real, target_is_directory=True)
        for path in [link, link / "child"]:
            with self.subTest(path=path):
                self.refused("owner_path", subject.validate_owner_root, path)

    def test_seal_accepts_independently_declared_inputs(self):
        path, data = self.seal()
        self.assertEqual(subject.load_candidate_seal(path), data)

    def test_seal_refuses_duplicate_json_keys_before_collapse(self):
        path, _ = self.seal()
        path.write_text('{"schema":1,"schema":1}\n')
        self.refused("duplicate_key", subject.load_candidate_seal, path)

    def test_seal_refuses_schema_boolean_unknown_fields_and_empty_files(self):
        path, data = self.seal()
        for change in [{"schema": True}, {"extra": True}, {"files": []}]:
            with self.subTest(change=change):
                changed = {**data, **change}
                path.write_text(json.dumps(changed))
                self.refused("invalid_seal", subject.load_candidate_seal, path)

    def test_seal_refuses_digest_coercion(self):
        path, data = self.seal()
        for invalid in ["A" * 64, "1" * 63, 123, None]:
            with self.subTest(invalid=invalid):
                path.write_text(json.dumps({**data, "patch_sha256": invalid}))
                self.refused("invalid_digest", subject.load_candidate_seal, path)

    def test_seal_refuses_candidate_paths_outside_diagnostics_contract(self):
        path, data = self.seal()
        for invalid in [
            "../hs274-existing.hpp",
            "/hs274-existing.hpp",
            "nested/hs274-existing.hpp",
            "hs274_native_build.py",
            "unrelated.hpp",
        ]:
            with self.subTest(invalid=invalid):
                row = {**data["files"][0], "path": invalid}
                path.write_text(json.dumps({**data, "files": [row]}))
                self.refused("candidate_path", subject.load_candidate_seal, path)

    def test_seal_refuses_duplicate_candidate_paths(self):
        path, data = self.seal()
        path.write_text(json.dumps({**data, "files": data["files"] * 2}))
        self.refused("duplicate_candidate_path", subject.load_candidate_seal, path)

    def test_seal_refuses_symlink_input(self):
        path, _ = self.seal()
        alias = self.root / "alias.json"
        alias.symlink_to(path)
        self.refused("unsafe_path", subject.load_candidate_seal, alias)

    def test_seal_refuses_unbounded_json(self):
        path, _ = self.seal()
        path.write_bytes(b" " * (2 * 1024 * 1024))
        self.refused("invalid_seal", subject.load_candidate_seal, path)

    def test_patch_accepts_exact_preimages_and_postimages(self):
        target = self.destination()
        seal, _ = self.seal()
        subject.apply_candidate_patch(target, seal)
        self.assertEqual(
            (target / "hs274-existing.hpp").read_bytes(), b"// new independent source\n"
        )
        self.assertEqual(set(p.name for p in target.iterdir()), {"hs274-existing.hpp"})

    def test_patch_hash_refusal_preserves_existing_source(self):
        target = self.destination()
        seal, _ = self.seal()
        (self.root / "candidate.patch").write_bytes(b"changed\n")
        self.refused("patch_hash", subject.apply_candidate_patch, target, seal)
        self.assertEqual(
            (target / "hs274-existing.hpp").read_bytes(), b"// old independent source\n"
        )

    def test_patch_preimage_refusal_preserves_changed_source(self):
        target = self.destination()
        (target / "hs274-existing.hpp").write_bytes(b"// external new source\n")
        seal, _ = self.seal()
        self.refused("preimage_hash", subject.apply_candidate_patch, target, seal)
        self.assertEqual((target / "hs274-existing.hpp").read_bytes(), b"// external new source\n")

    def test_patch_postimage_refusal_retains_failed_preparation(self):
        target = self.destination()
        seal, data = self.seal()
        data["files"][0]["candidate_sha256"] = "0" * 64
        seal.write_text(json.dumps(data))
        self.refused("postimage_hash", subject.apply_candidate_patch, target, seal)
        self.assertTrue(target.exists())
        self.assertEqual(
            (target / "hs274-existing.hpp").read_bytes(), b"// new independent source\n"
        )

    def test_patch_scope_refusal_precedes_any_mutation(self):
        target = self.destination()
        unsealed = b"--- a/hs274-unsealed.hpp\n+++ b/hs274-unsealed.hpp\n@@ -1 +1 @@\n-old\n+new\n"
        (target / "hs274-unsealed.hpp").write_bytes(b"old\n")
        seal, _ = self.seal(patch=unsealed)
        self.refused("patch_scope", subject.apply_candidate_patch, target, seal)
        self.assertEqual((target / "hs274-unsealed.hpp").read_bytes(), b"old\n")
        self.assertEqual(
            (target / "hs274-existing.hpp").read_bytes(), b"// old independent source\n"
        )

    def test_new_candidate_cannot_overwrite_existing_file(self):
        target = self.destination()
        seal, data = self.seal()
        data["files"][0]["preimage_sha256"] = None
        seal.write_text(json.dumps(data))
        self.refused("preimage_hash", subject.apply_candidate_patch, target, seal)
        self.assertEqual(
            (target / "hs274-existing.hpp").read_bytes(), b"// old independent source\n"
        )

    def test_patch_target_symlink_refusal_preserves_external_file(self):
        target = self.destination()
        file = target / "hs274-existing.hpp"
        file.unlink()
        outside = self.root / "external.hpp"
        outside.write_bytes(b"// old independent source\n")
        file.symlink_to(outside)
        seal, _ = self.seal()
        self.refused("unsafe_path", subject.apply_candidate_patch, target, seal)
        self.assertEqual(outside.read_bytes(), b"// old independent source\n")

    def test_stage_refuses_preexisting_destination(self):
        source = self.root / "source"
        source.mkdir(mode=0o700)
        (source / "hs274-input.hpp").write_bytes(b"// independent input\n")
        destination = self.root / "stage"
        destination.mkdir(mode=0o700)
        marker = destination / "keep"
        marker.write_bytes(b"foreign\n")
        self.refused("unsafe_path", subject.stage_diagnostics, source, destination)
        self.assertEqual(marker.read_bytes(), b"foreign\n")

    def test_stage_refuses_symlink_diagnostic_input(self):
        source = self.root / "source"
        source.mkdir(mode=0o700)
        real = self.root / "external.hpp"
        real.write_bytes(b"external\n")
        (source / "hs274-input.hpp").symlink_to(real)
        self.refused("unsafe_path", subject.stage_diagnostics, source, self.root / "stage")
        self.assertEqual(real.read_bytes(), b"external\n")

    def test_pins_accept_exact_three_authoritative_revisions(self):
        pins = {
            "upstream": "9312593e1a3bf72b94c63c524ebabe2637442e8a",
            "cpm": "6a8b2d64b993746d489432b45455e33b7fb8e09f",
            "vhd": "bdfcb459b2eaca8ccda680a73b0dc898f330f4bb",
        }
        self.assertEqual(subject.verify_pins(pins), pins)

    def test_pins_reject_missing_or_changed_revision(self):
        pins = {
            "upstream": "9312593e1a3bf72b94c63c524ebabe2637442e8a",
            "cpm": "6a8b2d64b993746d489432b45455e33b7fb8e09f",
            "vhd": "bdfcb459b2eaca8ccda680a73b0dc898f330f4bb",
        }
        for key in pins:
            with self.subTest(key=key):
                changed = {**pins, key: "0" * 40}
                self.refused("invalid_seal", subject.verify_pins, changed)
                missing = dict(pins)
                del missing[key]
                self.refused("invalid_seal", subject.verify_pins, missing)

    def test_expired_phase_never_launches_child(self):
        marker = self.root / "forbidden-launch"
        args = [
            sys.executable,
            "-c",
            "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('launched')",
            str(marker),
        ]
        self.refused(
            "phase_deadline",
            subject.run_phase,
            "expired",
            args,
            self.root,
            self.root,
            time.monotonic() - 1,
        )
        self.assertFalse(marker.exists())

    def test_real_failed_phase_retains_exclusive_evidence(self):
        args = [
            sys.executable,
            "-c",
            "import sys; print('independent-output'); print('independent-error', file=sys.stderr); sys.exit(7)",
        ]
        self.refused(
            "phase_failed",
            subject.run_phase,
            "failure",
            args,
            self.root,
            self.root,
            time.monotonic() + 5,
        )
        evidence = b"".join(p.read_bytes() for p in self.root.rglob("*") if p.is_file())
        self.assertIn(b"independent-output", evidence)
        self.assertIn(b"independent-error", evidence)

    def test_fifo_seal_refuses_without_opening_a_blocking_reader(self):
        fifo = self.root / "candidate-fifo"
        os.mkfifo(fifo, 0o600)
        code = "import importlib.util,sys; from pathlib import Path; s=importlib.util.spec_from_file_location('subject',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
        code += "\ntry: m.load_candidate_seal(Path(sys.argv[2]))\nexcept m.NativeBuildError as e: print(e.code); sys.exit(0 if e.code == 'unsafe_path' else 3)\nelse: sys.exit(4)"
        try:
            result = subprocess.run(
                [sys.executable, "-c", code, str(MODULE_PATH), str(fifo)],
                capture_output=True,
                text=True,
                timeout=2,
            )
        except subprocess.TimeoutExpired:
            self.fail("FIFO admission blocked instead of refusing an ordinary-file violation")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "unsafe_path")
        self.assertTrue(fifo.exists())

    def test_late_success_keeps_refused_terminal_and_actual_exit_status(self):
        args = [sys.executable, "-c", "import time; time.sleep(0.5); print('independent-late')"]
        self.refused(
            "phase_deadline",
            subject.run_phase,
            "late",
            args,
            self.root,
            self.root,
            time.monotonic() + 0.25,
        )
        terminals = []
        for path in self.root.rglob("*"):
            if not path.is_file():
                continue
            try:
                row = json.loads(path.read_text())
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if (
                isinstance(row, dict)
                and row.get("schema") == 1
                and row.get("phase") == "late"
                and type(row.get("exit_status")) is int
            ):
                terminals.append(row)
        pending = json.loads((self.root / "late.begin.json").read_text())
        self.assertEqual(pending, {"schema": 1, "phase": "late", "status": "pending"})
        self.assertEqual(len(terminals), 1)
        self.assertEqual(
            set(terminals[0]), {"schema", "phase", "status", "exit_status", "elapsed_seconds"}
        )
        self.assertEqual(terminals[0]["status"], "refused")
        self.assertEqual(terminals[0]["exit_status"], 0)
        self.assertGreaterEqual(terminals[0]["elapsed_seconds"], 0.25)
        evidence = b"".join(p.read_bytes() for p in self.root.rglob("*") if p.is_file())
        self.assertIn(b"independent-late", evidence)

    def _tool_metadata(self):
        return {
            "id": 478866069,
            "name": "xcodegen.zip",
            "size": 4278764,
            "digest": "sha256:4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
            "browser_download_url": "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip",
        }

    def _tool_zip(self, members=None, compression=zipfile.ZIP_DEFLATED):
        if members is None:
            members = [
                ("xcodegen/bin/xcodegen", b"UNIQUE_NATIVE_TOOL"),
                ("xcodegen/share/xcodegen/SettingPresets/base.yml", b"independent: true\n"),
            ]
        output = io.BytesIO()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(output, "w", compression=compression) as archive:
                for name, data in members:
                    if isinstance(name, zipfile.ZipInfo):
                        info = name
                    else:
                        info = zipfile.ZipInfo(name)
                        info.create_system = 3
                        info.external_attr = (stat.S_IFREG | 0o600) << 16
                    info.compress_type = compression
                    archive.writestr(info, data)
        return output.getvalue()

    def test_tool_metadata_exact_copy(self):
        metadata = self._tool_metadata()
        metadata["unrelated_official_field"] = {"nested": "not admitted"}
        result = subject.verify_xcodegen_metadata(metadata)
        self.assertEqual(result, self._tool_metadata())
        self.assertIsNot(result, metadata)
        metadata["id"] = 7
        self.assertEqual(result["id"], 478866069)

    def test_tool_metadata_wrong_values_and_scalar_types(self):
        changes = [
            ("id", 7),
            ("id", True),
            ("id", 478866069.0),
            ("name", "xcodegen-other.zip"),
            ("name", b"xcodegen.zip"),
            ("size", 4278763),
            ("size", True),
            ("size", 4278764.0),
            ("digest", "sha256:" + "0" * 64),
            ("digest", None),
            (
                "browser_download_url",
                "http://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip",
            ),
            ("browser_download_url", "https://example.invalid/xcodegen.zip"),
        ]
        for key, value in changes:
            with self.subTest(key=key, value=value):
                data = self._tool_metadata()
                data[key] = value
                self.refused("xcodegen_metadata", subject.verify_xcodegen_metadata, data)

    def test_tool_metadata_missing_and_nonobject(self):
        for key in self._tool_metadata():
            with self.subTest(missing=key):
                data = self._tool_metadata()
                del data[key]
                self.refused("xcodegen_metadata", subject.verify_xcodegen_metadata, data)
        for value in [None, [], "metadata", 7, True]:
            with self.subTest(value=value):
                self.refused("xcodegen_metadata", subject.verify_xcodegen_metadata, value)

    def test_tool_archive_refuses_wrong_length_first(self):
        for data in [b"", b"ordinary independent data", b"x" * 4278765]:
            with self.subTest(length=len(data)):
                self.refused("xcodegen_size", subject.verify_xcodegen_archive, data)

    def test_tool_archive_refuses_correct_size_wrong_digest(self):
        self.refused("xcodegen_digest", subject.verify_xcodegen_archive, b"\0" * 4278764)

    def test_tool_zip_healthy_keeps_binary_and_presets_owned(self):
        destination = self.root / "tool"
        binary = subject.extract_xcodegen_zip(self._tool_zip(), destination)
        self.assertEqual(binary, destination / "xcodegen/bin/xcodegen")
        self.assertEqual(binary.read_bytes(), b"UNIQUE_NATIVE_TOOL")
        self.assertEqual(stat.S_IMODE(binary.stat().st_mode), 0o700)
        preset = destination / "xcodegen/share/xcodegen/SettingPresets/base.yml"
        self.assertEqual(preset.read_bytes(), b"independent: true\n")
        self.assertEqual(stat.S_IMODE(preset.stat().st_mode), 0o600)
        for directory in [destination, binary.parent, preset.parent]:
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)

    def test_tool_zip_malformed_has_no_partial_destination(self):
        destination = self.root / "tool"
        self.refused("xcodegen_archive", subject.extract_xcodegen_zip, b"not a zip", destination)
        self.assertFalse(destination.exists())

    def test_tool_zip_missing_and_empty_binary(self):
        for members in [[("xcodegen/share/base.yml", b"x")], [("xcodegen/bin/xcodegen", b"")]]:
            with self.subTest(members=members):
                destination = self.root / "tool"
                self.refused(
                    "xcodegen_binary",
                    subject.extract_xcodegen_zip,
                    self._tool_zip(members),
                    destination,
                )
                self.assertFalse(destination.exists())

    def test_tool_zip_unsafe_paths_refuse_before_any_write(self):
        paths = [
            "../escape",
            "xcodegen/../../escape",
            "xcodegen/a/../b",
            "/xcodegen/file",
            "C:/xcodegen/file",
            "xcodegen\\bin\\file",
            "xcodegen//share/file",
            "xcodegen/./share/file",
            "outside/file",
            "xcodegen/share/bïnary",
        ]
        for path in paths:
            with self.subTest(path=path):
                destination = self.root / "tool"
                data = self._tool_zip([("xcodegen/bin/xcodegen", b"tool"), (path, b"bad")])
                self.refused("xcodegen_member", subject.extract_xcodegen_zip, data, destination)
                self.assertFalse(destination.exists())
                self.assertFalse((self.root.parent / "escape").exists())

    def test_tool_zip_duplicate_name_refuses_atomically(self):
        destination = self.root / "tool"
        data = self._tool_zip(
            [("xcodegen/bin/xcodegen", b"first"), ("xcodegen/bin/xcodegen", b"second")]
        )
        self.refused("xcodegen_member", subject.extract_xcodegen_zip, data, destination)
        self.assertFalse(destination.exists())

    def test_tool_zip_symlink_and_special_entries_refuse_atomically(self):
        for kind in [stat.S_IFLNK, stat.S_IFCHR, stat.S_IFBLK, stat.S_IFIFO, stat.S_IFSOCK]:
            with self.subTest(kind=kind):
                info = zipfile.ZipInfo("xcodegen/share/foreign")
                info.create_system = 3
                info.external_attr = (kind | 0o700) << 16
                destination = self.root / "tool"
                data = self._tool_zip([("xcodegen/bin/xcodegen", b"tool"), (info, b"../escape")])
                self.refused("xcodegen_member", subject.extract_xcodegen_zip, data, destination)
                self.assertFalse(destination.exists())

    def test_tool_zip_file_parent_collision_refuses(self):
        destination = self.root / "tool"
        data = self._tool_zip(
            [("xcodegen/bin/xcodegen", b"tool"), ("xcodegen/bin", b"file parent")]
        )
        self.refused("xcodegen_member", subject.extract_xcodegen_zip, data, destination)
        self.assertFalse(destination.exists())

    def test_tool_zip_member_count_limit_refuses_before_write(self):
        destination = self.root / "tool"
        members = [("xcodegen/bin/xcodegen", b"tool")] + [
            ("xcodegen/share/f" + str(i), b"x") for i in range(128)
        ]
        self.refused(
            "xcodegen_limit", subject.extract_xcodegen_zip, self._tool_zip(members), destination
        )
        self.assertFalse(destination.exists())

    def test_tool_zip_individual_expansion_limit_refuses_before_write(self):
        destination = self.root / "tool"
        members = [
            ("xcodegen/bin/xcodegen", b"tool"),
            ("xcodegen/share/large", b"x" * (16 * 1024 * 1024 + 1)),
        ]
        self.refused(
            "xcodegen_limit", subject.extract_xcodegen_zip, self._tool_zip(members), destination
        )
        self.assertFalse(destination.exists())

    def test_tool_zip_total_expansion_limit_refuses_before_write(self):
        destination = self.root / "tool"
        members = [("xcodegen/bin/xcodegen", b"tool")] + [
            ("xcodegen/share/f" + str(i), b"x" * (12 * 1024 * 1024)) for i in range(3)
        ]
        self.refused(
            "xcodegen_limit", subject.extract_xcodegen_zip, self._tool_zip(members), destination
        )
        self.assertFalse(destination.exists())

    def test_tool_zip_crc_failure_refuses_before_destination_mutation(self):
        destination = self.root / "tool"
        data = bytearray(self._tool_zip(compression=zipfile.ZIP_STORED))
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            info = archive.getinfo("xcodegen/bin/xcodegen")
            offset = info.header_offset + 30 + len(info.filename.encode()) + len(info.extra)
        data[offset] ^= 1
        self.refused("xcodegen_archive", subject.extract_xcodegen_zip, bytes(data), destination)
        self.assertFalse(destination.exists())

    def test_tool_zip_encrypted_entry_refuses_before_write(self):
        destination = self.root / "tool"
        data = bytearray(self._tool_zip(compression=zipfile.ZIP_STORED))
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            local = archive.getinfo("xcodegen/bin/xcodegen").header_offset
        struct.pack_into("<H", data, local + 6, 1)
        central = data.find(b"PK\x01\x02")
        self.assertGreaterEqual(central, 0)
        struct.pack_into("<H", data, central + 8, 1)
        self.refused("xcodegen_member", subject.extract_xcodegen_zip, bytes(data), destination)
        self.assertFalse(destination.exists())

    def test_tool_zip_existing_destinations_remain_untouched(self):
        data = self._tool_zip()
        for kind in ["file", "directory", "symlink"]:
            with self.subTest(kind=kind):
                destination = self.root / kind
                if kind == "file":
                    destination.write_bytes(b"independent sentinel")
                elif kind == "directory":
                    destination.mkdir()
                else:
                    destination.symlink_to(self.root / "absent foreign")
                self.refused("unsafe_path", subject.extract_xcodegen_zip, data, destination)
                if kind == "file":
                    self.assertEqual(destination.read_bytes(), b"independent sentinel")
                elif kind == "directory":
                    self.assertEqual(list(destination.iterdir()), [])
                else:
                    self.assertTrue(destination.is_symlink())

    def test_tool_zip_nul_original_name_does_not_become_truncated_alias(self):
        destination = self.root / "tool"
        name = b"xcodegen/share/nul-placeholder"
        data = self._tool_zip([("xcodegen/bin/xcodegen", b"tool"), (name.decode(), b"bad")])
        self.assertEqual(data.count(name), 2)
        corrupted = data.replace(name, name.replace(b"-", b"\0", 1))
        self.refused("xcodegen_member", subject.extract_xcodegen_zip, corrupted, destination)
        self.assertFalse(destination.exists())

    def _timed_acquisition(self, kind):
        # Identity/download seams isolate time ordering; these synthetic bytes
        # provide no authentic executable, transport or Darwin qualification.
        owner = self.root / ("temporal-" + kind)
        owner.mkdir(mode=0o700)
        archive = self._tool_zip()
        clock = [0.0]
        extraction_calls = []
        original_json = subject.write_json
        original_file = subject.write_exclusive
        original_extract = subject.extract_xcodegen_zip

        def download(url, maximum, deadline, metadata=False):
            data = json.dumps(self._tool_metadata()).encode() if metadata else archive
            return data, {"status": 200, "TLS": "isolated-test-input", "bytes": len(data)}

        def evidence(path, value):
            original_json(path, value)
            if kind == "late-identity" and path.name == "xcodegen-identity.json":
                clock[0] = 2.0

        def persistence(path, value):
            original_file(path, value)
            if kind == "late-archive" and path.name == "xcodegen-official.zip":
                clock[0] = 2.0

        def extraction(data, destination):
            extraction_calls.append(destination)
            return original_extract(data, destination)

        with (
            mock.patch.object(subject.time, "monotonic", side_effect=lambda: clock[0]),
            mock.patch.object(subject, "_download_tool_input", side_effect=download),
            mock.patch.object(
                subject,
                "verify_xcodegen_archive",
                return_value={"bytes": len(archive), "sha256": hashlib.sha256(archive).hexdigest()},
            ) as identity_gate,
            mock.patch.object(
                subject, "XCODEGEN_BINARY_SHA256", hashlib.sha256(b"UNIQUE_NATIVE_TOOL").hexdigest()
            ),
            mock.patch.object(subject, "write_json", side_effect=evidence),
            mock.patch.object(subject, "write_exclusive", side_effect=persistence),
            mock.patch.object(subject, "extract_xcodegen_zip", side_effect=extraction),
        ):
            try:
                binary, record = subject.acquire_xcodegen(owner, 1.0)
                outcome = {"returned": True, "binary": binary, "record": record}
            except subject.NativeBuildError as error:
                outcome = {"returned": False, "code": error.code}
            identity_gate.assert_called_once_with(archive)
        return owner, outcome, extraction_calls

    def test_tool_acquisition_healthy_temporal_control_retains_owned_inputs(self):
        owner, outcome, calls = self._timed_acquisition("healthy")
        self.assertTrue(outcome["returned"])
        self.assertEqual(outcome["record"]["status"], "passed")
        self.assertEqual(outcome["record"]["elapsed_seconds"], 0.0)
        self.assertFalse(outcome["record"]["child_process_executed"])
        self.assertEqual(outcome["binary"].read_bytes(), b"UNIQUE_NATIVE_TOOL")
        self.assertEqual(len(calls), 1)
        identity = json.loads((owner / "xcodegen-identity.json").read_text())
        self.assertFalse(identity["installer_executed"])
        self.assertFalse(identity["global_installation_executed"])

    def test_tool_acquisition_rechecks_deadline_after_identity_evidence(self):
        owner, outcome, calls = self._timed_acquisition("late-identity")
        self.assertFalse(outcome["returned"])
        self.assertEqual(outcome["code"], "phase_deadline")
        self.assertEqual(len(calls), 1)
        self.assertTrue((owner / "xcodegen-identity.json").is_file())
        terminal = json.loads((owner / "xcodegen_acquisition.receipt.json").read_text())
        self.assertEqual(terminal["status"], "refused")
        self.assertEqual(terminal["code"], "phase_deadline")
        self.assertEqual(terminal["elapsed_seconds"], 2.0)

    def test_tool_acquisition_rechecks_deadline_after_archive_before_extraction(self):
        owner, outcome, calls = self._timed_acquisition("late-archive")
        self.assertFalse(outcome["returned"])
        self.assertEqual(outcome["code"], "phase_deadline")
        self.assertEqual(calls, [])
        self.assertTrue((owner / "xcodegen-official.zip").is_file())
        self.assertFalse((owner / "xcodegen-package").exists())
        terminal = json.loads((owner / "xcodegen_acquisition.receipt.json").read_text())
        self.assertEqual(terminal["status"], "refused")
        self.assertEqual(terminal["code"], "phase_deadline")
        self.assertEqual(terminal["elapsed_seconds"], 2.0)

    def test_tool_download_rechecks_deadline_after_TLS_before_any_request(self):
        clock = [0.0]
        requests = []
        context = ssl.create_default_context()

        def delayed_context():
            clock[0] = 2.0
            return context

        class Opener:
            def open(self, request, timeout):
                requests.append(timeout)
                # Actual offline socket validation reproduces the negative-timeout
                # error without a network request or an executable launch.
                with socket.socket() as descriptor:
                    descriptor.settimeout(timeout)
                raise RuntimeError("Expired request must not proceed")

        with (
            mock.patch.object(subject.time, "monotonic", side_effect=lambda: clock[0]),
            mock.patch.object(subject.ssl, "create_default_context", side_effect=delayed_context),
            mock.patch.object(subject.urllib.request, "build_opener", return_value=Opener()),
        ):
            self.refused(
                "phase_deadline",
                subject._download_tool_input,
                subject.XCODEGEN_METADATA_URL,
                65_536,
                1.0,
                True,
            )
        self.assertEqual(requests, [])

    def test_tool_acquisition_passed_duration_uses_the_qualified_terminal_sample(self):
        # Independent transport/identity seams leave real ordinary extraction and
        # evidence writes. This tests timestamp consistency, never tool trust.
        owner = self.root / "terminal-sample"
        owner.mkdir(mode=0o700)
        archive = self._tool_zip()
        samples = []

        def now():
            samples.append(len(samples) + 1)
            return 2.0 if len(samples) >= 6 else 0.0

        def download(url, maximum, deadline, metadata=False):
            data = json.dumps(self._tool_metadata()).encode() if metadata else archive
            return data, {"status": 200, "TLS": "isolated-test-input", "bytes": len(data)}

        with (
            mock.patch.object(subject.time, "monotonic", side_effect=now),
            mock.patch.object(subject, "_download_tool_input", side_effect=download),
            mock.patch.object(
                subject,
                "verify_xcodegen_archive",
                return_value={"bytes": len(archive), "sha256": digest(archive)},
            ) as identity_gate,
            mock.patch.object(subject, "XCODEGEN_BINARY_SHA256", digest(b"UNIQUE_NATIVE_TOOL")),
        ):
            binary, record = subject.acquire_xcodegen(owner, 1.0)
            identity_gate.assert_called_once_with(archive)
        self.assertEqual(binary.read_bytes(), b"UNIQUE_NATIVE_TOOL")
        self.assertEqual(record["status"], "passed")
        self.assertEqual(record["elapsed_seconds"], 0.0)
        self.assertLessEqual(record["elapsed_seconds"], 1.0)
        self.assertFalse(record["child_process_executed"])
        self.assertEqual(samples, [1, 2, 3, 4, 5])
        self.assertEqual(
            json.loads((owner / "xcodegen_acquisition.receipt.json").read_text()), record
        )


SOURCE = MODULE_PATH
API = "https://api.github.com/repos/yonaskolb/XcodeGen/releases/assets/478866069"
ARCHIVE = "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip"
PURPOSE = "ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN"
SENTINEL = "ghs_SYNTHETIC_METADATA_CONTROL_ONLY"
METADATA = json.dumps(
    {
        "id": 478866069,
        "name": "xcodegen.zip",
        "size": 4278764,
        "digest": "sha256:4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
        "browser_download_url": ARCHIVE,
    }
).encode()


class Reply:
    def __init__(self, url, body=b"{}", status=200):
        self.url, self.body, self.status = url, body, status
        self.headers = {"Content-Length": str(len(body))}

    def __enter__(self):
        return self

    def __exit__(self, *arguments):
        return False

    def geturl(self):
        return self.url

    def read(self, maximum):
        result, self.body = self.body[:maximum], self.body[maximum:]
        return result


class MetadataCredentialContracts(unittest.TestCase):
    def port(self):
        self.assertIn(
            "metadata_token",
            inspect.signature(subject._download_tool_input).parameters,
            "PREREQUISITE: new optional metadata API is not implemented",
        )
        return subject._download_tool_input

    def validator(self):
        value = getattr(subject, "_validated_tool_metadata_token", None)
        self.assertTrue(callable(value), "PREREQUISITE: new token validator is not implemented")
        return value

    def download(
        self,
        *,
        token=None,
        metadata=True,
        url=API,
        body=b"{}",
        error=None,
        status=200,
        final=None,
        deadline=20.0,
        clock=0.0,
        tls_expired=False,
    ):
        port = self.port()
        requests, handler_sets = [], []
        current = [clock]

        class Opener:
            def open(self, request, *, timeout):
                requests.append((request, timeout))
                if error is not None:
                    raise error
                return Reply(final if final is not None else request.full_url, body, status)

        def opener(*handlers):
            handler_sets.append(handlers)
            if tls_expired:
                current[0] = deadline + 1
            return Opener()

        with (
            mock.patch.object(subject.urllib.request, "build_opener", side_effect=opener),
            mock.patch.object(subject.time, "monotonic", side_effect=lambda: current[0]),
        ):
            try:
                result = port(url, 65536, deadline, metadata=metadata, metadata_token=token)
                return result, requests, handler_sets, None
            except subject.NativeBuildError as failure:
                return None, requests, handler_sets, failure

    def test_01_legacy_anonymous_download_remains_unchanged(self):
        requests, handlers = [], []

        class Opener:
            def open(self, request, *, timeout):
                requests.append((request, timeout))
                return Reply(request.full_url)

        def opener(*values):
            handlers.extend(values)
            return Opener()

        with (
            mock.patch.object(subject.urllib.request, "build_opener", side_effect=opener),
            mock.patch.object(subject.time, "monotonic", return_value=0.0),
        ):
            data, receipt = subject._download_tool_input(API, 65536, 20.0, metadata=True)
        self.assertEqual(data, b"{}")
        self.assertEqual(len(requests), 1)
        request, timeout = requests[0]
        self.assertIsNone(request.get_header("Authorization"))
        self.assertEqual(request.get_header("Accept"), "application/vnd.github+json")
        self.assertEqual(request.get_header("X-github-api-version"), "2022-11-28")
        self.assertEqual(timeout, 20.0)
        self.assertTrue(any(type(h) is subject._PinnedToolRedirect for h in handlers))
        self.assertTrue(
            any(
                isinstance(h, urllib.request.HTTPSHandler)
                and h._context.verify_mode == ssl.CERT_REQUIRED
                and h._context.check_hostname
                for h in handlers
            )
        )
        self.assertEqual(
            receipt,
            {"status": 200, "TLS": "default-verified", "final_host": "api.github.com", "bytes": 2},
        )

    def test_02_authenticated_exact_api_uses_one_bearer_request(self):
        result, requests, handlers, failure = self.download(token=SENTINEL)
        self.assertIsNone(failure)
        self.assertEqual(len(requests), 1)
        request, timeout = requests[0]
        self.assertEqual(request.full_url, API)
        self.assertTrue(
            request.get_header("Authorization") == "Bearer " + SENTINEL,
            "credential must be confined to the exact request",
        )
        self.assertEqual(timeout, 20.0)
        self.assertEqual(result[0], b"{}")
        self.assertTrue(
            any(
                isinstance(h, urllib.request.HTTPSHandler)
                and h._context.verify_mode == ssl.CERT_REQUIRED
                and h._context.check_hostname
                for h in handlers[0]
            )
        )

    def test_03_authenticated_wrong_routes_refuse_before_http(self):
        for url in (
            "http://api.github.com/repos/yonaskolb/XcodeGen/releases/assets/478866069",
            API + "?x=1",
            API + "#fragment",
            API + "/",
            API.replace("478866069", "1"),
            API.replace("api.github.com", "api.github.com.invalid"),
            API.replace("api.github.com", "api.github.com:444"),
            API.replace("api.github.com", "user@api.github.com"),
            ARCHIVE,
        ):
            with self.subTest(route=url):
                _, requests, _, failure = self.download(token=SENTINEL, url=url)
                self.assertIsNotNone(failure)
                self.assertEqual(requests, [])
                self.assertNotIn(SENTINEL, str(failure))

    def test_04_authenticated_same_and_cross_origin_redirects_refuse(self):
        _, requests, sets, failure = self.download(token=SENTINEL)
        self.assertIsNone(failure)
        handlers = [h for h in sets[0] if isinstance(h, urllib.request.HTTPRedirectHandler)]
        self.assertEqual(len(handlers), 1)
        for target in (
            API,
            "https://github.com/",
            "https://objects.githubusercontent.com/",
            "https://foreign.invalid/",
        ):
            with self.subTest(origin=urllib.parse.urlsplit(target).hostname):
                self.assertIsNone(
                    handlers[0].redirect_request(requests[0][0], None, 302, "redirect", {}, target)
                )

    def test_05_archive_is_anonymous_and_cannot_accept_a_metadata_credential(self):
        result, requests, _, failure = self.download(metadata=False, url=ARCHIVE)
        self.assertIsNone(failure)
        self.assertEqual(result[0], b"{}")
        self.assertIsNone(requests[0][0].get_header("Authorization"))
        _, requests, _, failure = self.download(metadata=False, url=ARCHIVE, token=SENTINEL)
        self.assertIsNotNone(failure)
        self.assertEqual(requests, [])

    def test_06_supplied_credentials_are_bounded_ascii_without_fallback(self):
        validate = self.validator()
        self.assertIsNone(validate(None))
        self.assertTrue(validate(SENTINEL) == SENTINEL)
        self.assertTrue(validate("A" * 4096) == "A" * 4096)
        for value in (
            "",
            "A" * 4097,
            "x\r\nInjected: value",
            "x\x00",
            "x\t",
            " x",
            "x ",
            "é",
            b"x",
            True,
            7,
            [],
        ):
            with self.subTest(kind=type(value).__name__):
                with self.assertRaises(subject.NativeBuildError):
                    validate(value)

    def test_07_bad_credentials_fail_before_http_without_reflection(self):
        for value in ("", SENTINEL + "\n", "A" * 4097):
            _, requests, _, failure = self.download(token=value)
            self.assertIsNotNone(failure)
            self.assertEqual(requests, [])
            self.assertNotIn(SENTINEL, str(failure))

    def test_08_http401_403_and_redirect_status_are_terminal_without_retry(self):
        for code in (301, 302, 307, 401, 403):
            error = urllib.error.HTTPError(API, code, SENTINEL, {"Authorization": SENTINEL}, None)
            _, requests, _, failure = self.download(token=SENTINEL, error=error)
            self.assertEqual(len(requests), 1)
            self.assertEqual(failure.code, "xcodegen_transport")
            self.assertEqual(
                failure.transport_diagnostic, {"kind": "http_status", "http_status": code}
            )
            self.assertNotIn(SENTINEL, str(failure))
            self.assertNotIn("Authorization", json.dumps(failure.transport_diagnostic))

    def test_09_authenticated_final_route_cannot_change(self):
        for final in (ARCHIVE, "https://api.github.com/other", API + "?changed=1"):
            _, requests, _, failure = self.download(token=SENTINEL, final=final)
            self.assertEqual(len(requests), 1)
            self.assertIsNotNone(failure)

    def test_10_authenticated_body_and_tls_deadlines_do_not_gain_budget(self):
        _, requests, _, failure = self.download(token=SENTINEL, deadline=-1)
        self.assertEqual(requests, [])
        self.assertEqual(failure.code, "phase_deadline")
        _, requests, _, failure = self.download(token=SENTINEL, tls_expired=True)
        self.assertEqual(requests, [])
        self.assertEqual(failure.code, "phase_deadline")
        _, requests, _, failure = self.download(token=SENTINEL, body=b"x" * 65537)
        self.assertEqual(len(requests), 1)
        self.assertEqual(failure.code, "xcodegen_size")

    def test_11_acquisition_sends_no_credential_on_the_archive_request(self):
        self.assertIn(
            "metadata_token",
            inspect.signature(subject.acquire_xcodegen).parameters,
            "PREREQUISITE: new acquisition API is not implemented",
        )
        requests = []

        class Opener:
            def open(self, request, *, timeout):
                requests.append(request)
                return Reply(request.full_url, METADATA if len(requests) == 1 else b"x")

        with (
            tempfile.TemporaryDirectory() as directory,
            mock.patch.object(subject.urllib.request, "build_opener", return_value=Opener()),
            mock.patch.object(subject.time, "monotonic", return_value=0.0),
        ):
            owner = Path(directory).resolve()
            owner.chmod(0o700)
            with self.assertRaises(subject.NativeBuildError) as caught:
                subject.acquire_xcodegen(owner, 20.0, metadata_token=SENTINEL)
            self.assertEqual(caught.exception.code, "xcodegen_size")
            self.assertEqual(len(requests), 2)
            self.assertTrue(requests[0].get_header("Authorization") == "Bearer " + SENTINEL)
            self.assertIsNone(requests[1].get_header("Authorization"))
            row = json.loads((owner / "xcodegen_acquisition.receipt.json").read_text())
            self.assertEqual(row["status"], "refused")
            self.assertEqual(row["acquisition_stage"], "archive")
            self.assertFalse((owner / "xcodegen-official.zip").exists())
            self.assertFalse((owner / "xcodegen-package").exists())

    def test_12_authenticated_wrong_metadata_and_duplicate_keys_still_refuse(self):
        self.assertIn(
            "metadata_token",
            inspect.signature(subject.acquire_xcodegen).parameters,
            "PREREQUISITE: new acquisition API is not implemented",
        )
        for body in (
            b"{}",
            b'{"id":478866069,"id":478866069}',
            METADATA.replace(b"4278764", b"4278763"),
        ):
            requests = []

            class Opener:
                def open(self, request, *, timeout):
                    requests.append(request)
                    return Reply(request.full_url, body)

            with (
                tempfile.TemporaryDirectory() as directory,
                mock.patch.object(subject.urllib.request, "build_opener", return_value=Opener()),
                mock.patch.object(subject.time, "monotonic", return_value=0.0),
            ):
                owner = Path(directory).resolve()
                owner.chmod(0o700)
                with self.assertRaises(subject.NativeBuildError) as caught:
                    subject.acquire_xcodegen(owner, 20.0, metadata_token=SENTINEL)
                self.assertEqual(caught.exception.code, "xcodegen_metadata")
                self.assertEqual(len(requests), 1)
                self.assertEqual(
                    json.loads((owner / "xcodegen_acquisition.receipt.json").read_text())[
                        "acquisition_stage"
                    ],
                    "metadata",
                )

    def test_13_worker_consumes_purpose_credential_before_actual_posix_child(self):
        self.assertTrue(
            callable(getattr(subject, "_take_tool_metadata_token", None)),
            "PREREQUISITE: new worker credential consumer is not implemented",
        )
        program = """import importlib.util, json, os, subprocess, sys
spec=importlib.util.spec_from_file_location("isolated_metadata_consumer",sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
value=m._take_tool_metadata_token()
child=subprocess.run([sys.executable,"-c","import os;print(int('ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN' in os.environ))"],capture_output=True,text=True)
print(json.dumps({"consumed":type(value) is str and len(value)>0,"parent_absent":'ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN' not in os.environ,"child_absent":child.returncode==0 and child.stdout=='0\\n' and child.stderr==''}))
"""
        result = subprocess.run(
            [sys.executable, "-c", program, str(SOURCE)],
            env={"PATH": os.defpath, PURPOSE: SENTINEL},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertEqual(
            json.loads(result.stdout),
            {"consumed": True, "parent_absent": True, "child_absent": True},
        )
        self.assertNotIn(SENTINEL, result.stdout + result.stderr)

    def test_14_ambient_tokens_do_not_supply_absent_purpose_credential(self):
        self.assertTrue(
            callable(getattr(subject, "_take_tool_metadata_token", None)),
            "PREREQUISITE: new worker credential consumer is not implemented",
        )
        program = """import importlib.util,json,sys
spec=importlib.util.spec_from_file_location("isolated_ambient_consumer",sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
print(json.dumps({"absent":m._take_tool_metadata_token() is None}))
"""
        result = subprocess.run(
            [sys.executable, "-c", program, str(SOURCE)],
            env={
                "PATH": os.defpath,
                "GH_TOKEN": SENTINEL,
                "GITHUB_TOKEN": SENTINEL,
                "ERGOPTI_NATIVE_HS_METADATA_TOKEN": SENTINEL,
            },
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertEqual(json.loads(result.stdout), {"absent": True})
        self.assertNotIn(SENTINEL, result.stdout + result.stderr)


class MetadataWorkerEntryContracts(unittest.TestCase):
    def test_standalone_main_removes_credential_before_actual_posix_child(self):
        program = """import importlib.util,json,os,subprocess,sys
spec=importlib.util.spec_from_file_location("entry_consumer",sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
observed={}
def compile_leaf(*args,**kwargs):
 child=subprocess.run([sys.executable,"-c","import os;print(int('ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN' in os.environ))"],capture_output=True,text=True)
 observed.update(held=type(kwargs.get('metadata_token')) is str and len(kwargs['metadata_token'])>0,parent_absent='ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN' not in os.environ,child_absent=child.returncode==0 and child.stdout=='0\\n' and child.stderr=='')
m.compile_native=compile_leaf
sys.argv=['owned-native-build','/not-acquired-source','/not-created-owner']
status=m.main()
print(json.dumps({'status':status,'observation':observed}))
"""
        result = subprocess.run(
            [sys.executable, "-c", program, str(SOURCE)],
            env={"PATH": os.defpath, PURPOSE: SENTINEL},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertEqual(
            json.loads(result.stdout),
            {
                "status": 0,
                "observation": {"held": True, "parent_absent": True, "child_absent": True},
            },
        )
        self.assertNotIn(SENTINEL, result.stdout + result.stderr)

    def test_standalone_main_refuses_and_consumes_malformed_credential_before_compile(self):
        program = """import importlib.util,json,os,sys
spec=importlib.util.spec_from_file_location("entry_refusal",sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
observed=[]
def compile_leaf(*args,**kwargs):observed.append('compile-entered')
m.compile_native=compile_leaf
sys.argv=['owned-native-build','/not-acquired-source','/not-created-owner']
status=m.main()
print(json.dumps({'status':status,'compile_absent':not observed,'parent_absent':'ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN' not in os.environ}))
"""
        result = subprocess.run(
            [sys.executable, "-c", program, str(SOURCE)],
            env={"PATH": os.defpath, PURPOSE: SENTINEL + "\n"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            result.stderr,
            "Native compilation qualification refused: xcodegen_metadata_token; "
            "Official tool metadata credential is malformed\n",
        )
        self.assertEqual(
            json.loads(result.stdout),
            {"status": 1, "compile_absent": True, "parent_absent": True},
        )
        self.assertNotIn(SENTINEL, result.stdout + result.stderr)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ControllerContract)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    successful = result.testsRun == 53 and result.wasSuccessful() and not result.skipped
    if successful:
        print("PASS independent native build controller tests=53 failures=0 errors=0 skipped=0")
    metadata_suite = unittest.defaultTestLoader.loadTestsFromTestCase(MetadataCredentialContracts)
    metadata_result = unittest.TextTestRunner(verbosity=2).run(metadata_suite)
    metadata_successful = (
        metadata_result.testsRun == 14
        and metadata_result.wasSuccessful()
        and not metadata_result.skipped
    )
    if not metadata_successful:
        raise SystemExit(1)
    entry_suite = unittest.defaultTestLoader.loadTestsFromTestCase(MetadataWorkerEntryContracts)
    entry_result = unittest.TextTestRunner(verbosity=2).run(entry_suite)
    entry_successful = (
        entry_result.testsRun == 2 and entry_result.wasSuccessful() and not entry_result.skipped
    )
    if not entry_successful:
        raise SystemExit(1)
    raise SystemExit(0 if successful else 1)
