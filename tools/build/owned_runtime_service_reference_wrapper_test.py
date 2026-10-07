"""Actual ordinary-generator CLI controls; no native principal or service proof."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

_ROOT = Path(__file__).resolve().parents[2]
_WRAPPER = _ROOT / "tools/build/generate-owned-runtime-service-reference.cjs"
if len(sys.argv) > 1 and sys.argv[1] == "--wrapper":
    del sys.argv[1]
    _WRAPPER = Path(sys.argv.pop(1)).resolve(strict=True)
    _ROOT = _WRAPPER.parents[2]
_DATA = "static/ergopti_plus/_shared/data"
_REFERENCE = "owned_runtime_service_reference.generated.json"
_POLICY = "owned_runtime_service_policy.json"


class WrapperControls(unittest.TestCase):
    def setUp(self):
        self.assertTrue(_WRAPPER.is_file(), "The actual wrapper subject is required")
        self.temporary = tempfile.TemporaryDirectory(prefix="owned-reference-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve(strict=True) / "private repo"
        self.files = {}
        for relative in (
            "tools/build/generate-owned-runtime-service-reference.cjs",
            "tools/build/generate_owned_runtime_service_reference.py",
            "tools/build/remap_runtime_patch.py",
            f"{_DATA}/{_POLICY}",
            f"{_DATA}/{_REFERENCE}",
        ):
            origin = _WRAPPER if relative.endswith(".cjs") else _ROOT / relative
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(origin.read_bytes())
            self.files[relative] = origin.read_bytes()
        self.wrapper = self.root / "tools/build/generate-owned-runtime-service-reference.cjs"
        self.reference = self.root / _DATA / _REFERENCE
        self.expected = self.reference.read_bytes()

    def run_wrapper(self, arguments, *, python=None):
        environment = dict(os.environ)
        environment["PYTHON"] = python or sys.executable
        return subprocess.run(
            ["node", str(self.wrapper), *arguments],
            cwd=self.temporary.name,
            env=environment,
            capture_output=True,
            timeout=15,
            check=False,
        )

    def assert_whole(self, *, reference=True):
        for relative, before in self.files.items():
            if reference or not relative.endswith(_REFERENCE):
                self.assertEqual((self.root / relative).read_bytes(), before)

    def test_default_current_check_from_foreign_cwd_is_read_only(self):
        receipt = self.run_wrapper(["--check"])
        self.assertEqual(receipt.returncode, 0, receipt.stderr)
        self.assertEqual(receipt.stdout, b"")
        self.assertEqual(receipt.stderr, b"")
        self.assert_whole()

    def test_dirty_reference_check_refuses_without_rewriting(self):
        dirty = self.expected + b" \n"
        self.reference.write_bytes(dirty)
        receipt = self.run_wrapper(["--check"])
        self.assertEqual(receipt.returncode, 1)
        self.assertEqual(receipt.stdout, b"")
        self.assertEqual(receipt.stderr, b"Owned runtime service reference refused\n")
        self.assertEqual(self.reference.read_bytes(), dirty)
        self.assert_whole(reference=False)

    def test_ordinary_generation_restores_exact_original_artifact_only(self):
        self.reference.write_bytes(b"stale\n")
        receipt = self.run_wrapper([])
        self.assertEqual(receipt.returncode, 0, receipt.stderr)
        self.assertEqual(receipt.stdout, b"")
        self.assertEqual(receipt.stderr, b"")
        self.assertEqual(self.reference.read_bytes(), self.expected)
        self.assert_whole()

    def test_literal_output_argument_routes_dirty_check_and_generation(self):
        alternate = Path(self.temporary.name) / "literal space reference.json"
        dirty = self.expected + b" \n"
        alternate.write_bytes(dirty)
        arguments = ["--output", str(alternate)]
        refused = self.run_wrapper(arguments + ["--check"])
        self.assertEqual(refused.returncode, 1)
        self.assertEqual(refused.stderr, b"Owned runtime service reference refused\n")
        self.assertEqual(alternate.read_bytes(), dirty)
        generated = self.run_wrapper(arguments)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        self.assertEqual(alternate.read_bytes(), self.expected)
        self.assert_whole()

    def test_missing_selected_interpreter_refuses_without_fallback_or_rewrite(self):
        receipt = self.run_wrapper(
            ["--check"], python=str(Path(self.temporary.name) / "missing-python")
        )
        self.assertEqual(receipt.returncode, 1)
        self.assertEqual(receipt.stdout, b"")
        self.assertEqual(receipt.stderr, b"Owned runtime service reference generator unavailable\n")
        self.assert_whole()


if __name__ == "__main__":
    unittest.main()
