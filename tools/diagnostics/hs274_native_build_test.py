# tools/diagnostics/hs274_native_build_test.py
"""Independent controller contract, authored before receiving implementation."""

import hashlib
import importlib.util
import json
import os
import subprocess
from pathlib import Path
import sys
import tempfile
import time
import unittest


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
        args = [
            sys.executable,
            "-c",
            "import time; time.sleep(0.5); print('independent-late')",
        ]
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
            set(terminals[0]),
            {"schema", "phase", "status", "exit_status", "elapsed_seconds"},
        )
        self.assertEqual(terminals[0]["status"], "refused")
        self.assertEqual(terminals[0]["exit_status"], 0)
        self.assertGreaterEqual(terminals[0]["elapsed_seconds"], 0.25)
        evidence = b"".join(p.read_bytes() for p in self.root.rglob("*") if p.is_file())
        self.assertIn(b"independent-late", evidence)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ControllerContract)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    successful = result.testsRun == 29 and result.wasSuccessful() and not result.skipped
    if successful:
        print("PASS independent native build controller tests=29 failures=0 errors=0 skipped=0")
    raise SystemExit(0 if successful else 1)
