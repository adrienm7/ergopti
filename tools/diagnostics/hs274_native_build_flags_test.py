"""Actual Python command assembly policy; controlled products are not native proof."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("flags_subject", ROOT / "hs274_native_build.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class CalibrationFlagsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="flag-policy-", dir=ROOT)
        self.owner = Path(self.temporary.name)
        self.owner.chmod(0o700)
        self.calls = []
        self.source = self.owner / "controlled-source"
        self.source.mkdir()
        self.checked_phase_owner = []

    def tearDown(self):
        self.temporary.cleanup()

    def stage(self, source, destination):
        self.assertEqual(source, self.source)
        destination.mkdir()
        return []

    def acquisition(self, owner, deadline):
        self.assertEqual(owner, self.owner)
        return owner / "controlled-xcodegen", {
            "phase": "xcodegen_acquisition",
            "status": "passed",
            "elapsed_seconds": 0,
        }

    def phase(self, name, args, cwd, owner, deadline):
        self.calls.append((name, args, cwd, owner, deadline))
        self.checked_phase_owner.append(
            owner == self.owner and (cwd == owner or owner in cwd.parents)
        )
        tree = owner / "upstream"
        if name == "acquisition":
            tree.mkdir()
            headers = tree / "vendor/vendor/include/nlohmann"
            headers.mkdir(parents=True)
            for index in range(46):
                (headers / f"controlled{index}.hpp").write_text(
                    "// controlled input, not native source\n"
                )
        elif name.startswith("identity_"):
            pins = {"upstream": native.UPSTREAM, "cpm": native.CPM, "vhd": native.VIRTUAL_HID}
            (owner / (name + ".stdout")).write_text(pins[name.removeprefix("identity_")] + "\n")
        elif name.endswith("_build"):
            products = {
                "duktape_build": "vendor/duktape-src/build/Release/libduktape.a",
                "core_build": "src/apps/CoreService/build/Release/Karabiner-Core-Service.app/Contents/MacOS/Karabiner-Core-Service",
                "cli_build": "src/bin/cli/build/Release/karabiner_cli",
            }
            target = tree / products[name]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"controlled portable policy bytes; not native compiler evidence")
        return {"phase": name, "status": "passed", "exit_status": 0, "elapsed_seconds": 0}

    def collect(self):
        # Only external SDK, process and acquisition ports are controlled. The
        # actual compile_native function constructs every source/build command.
        with (
            patch.object(native.sys, "platform", "darwin"),
            patch.object(native.shutil, "which", side_effect=lambda name: "/controlled/" + name),
            patch.object(native, "stage_diagnostics", side_effect=self.stage),
            patch.object(native, "acquire_xcodegen", side_effect=self.acquisition),
            patch.object(native, "run_phase", side_effect=self.phase),
        ):
            return native.compile_native(self.source, self.owner, 300)

    def test_every_actual_unsigned_build_command_disables_debug_metadata(self):
        self.collect()
        builds = [args for name, args, _, _, _ in self.calls if name.endswith("_build")]
        self.assertEqual(len(builds), 3)
        for argv in builds:
            with self.subTest(tool=argv[0]):
                self.assertIn("GCC_GENERATE_DEBUGGING_SYMBOLS=NO", argv)

    def test_original_targets_release_architecture_and_owner_contracts_are_preserved(self):
        self.collect()
        builds = [
            (name, args, cwd) for name, args, cwd, _, _ in self.calls if name.endswith("_build")
        ]
        self.assertEqual(
            [name for name, _, _ in builds], ["duktape_build", "core_build", "cli_build"]
        )
        for _, argv, cwd in builds:
            self.assertEqual(
                argv[:4], ["/controlled/xcodebuild", "-configuration", "Release", "-alltargets"]
            )
            self.assertIn("SYMROOT=" + str(cwd / "build"), argv)
            self.assertIn("CODE_SIGNING_ALLOWED=NO", argv)
            self.assertIn("CODE_SIGNING_REQUIRED=NO", argv)
            self.assertFalse(
                any(
                    value.startswith(
                        (
                            "ARCHS=",
                            "ONLY_ACTIVE_ARCH=",
                            "GCC_OPTIMIZATION_LEVEL=",
                            "SWIFT_OPTIMIZATION_LEVEL=",
                        )
                    )
                    for value in argv
                )
            )
        self.assertTrue(all(self.checked_phase_owner))
        self.assertEqual(len({deadline for _, _, _, _, deadline in self.calls}), 1)
        instrumentation = [args for name, args, _, _, _ in self.calls if name == "instrumentation"]
        self.assertEqual(len(instrumentation), 1)
        self.assertEqual(instrumentation[0][-1], "--stream")

    def test_original_success_receipt_does_not_add_capture_install_or_overlay(self):
        receipt = self.collect()
        self.assertEqual(receipt["budget_seconds"], 300)
        self.assertEqual(receipt["qualification"], "unsigned-pinned-source-compilation-only")
        self.assertIsNone(receipt["candidate"])
        self.assertIs(receipt["native_capture_executed"], False)
        self.assertIs(receipt["installation_executed"], False)
        self.assertEqual(
            [product["target"] for product in receipt["products"]], ["duktape", "core", "cli"]
        )
        self.assertEqual(
            receipt["pins"],
            {"upstream": native.UPSTREAM, "cpm": native.CPM, "vhd": native.VIRTUAL_HID},
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
