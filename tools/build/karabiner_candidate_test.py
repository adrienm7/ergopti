# tools/build/karabiner_candidate_test.py
"""Reject incomplete fork packages before their installer can be assembled."""

from pathlib import Path
import plistlib
import shutil
import subprocess
from tempfile import TemporaryDirectory
import unittest

from karabiner_candidate import BUILD_STEP, LAUNCHD_RESOURCES, PRODUCTS, SIGN_STEP, inspect_products, packaging_script
from karabiner_test_fixture import make_products, signature_verifier


class CandidateTests(unittest.TestCase):
    def test_complete_set_contains_every_cooperating_application_and_cli(self):
        with TemporaryDirectory() as directory:
            root = make_products(directory)
            calls = []
            receipt = inspect_products(root, signature_verifier(calls))
            expected = {"AppIconSwitcher", "EventViewer", "MultitouchExtension", "ServiceManager-Non-Privileged-Agents",
                        "ServiceManager-Privileged-Daemons", "SettingsWindow", "Updater", "cli", "ConsoleUserServer", "CoreService"}
            self.assertEqual({row["product"].split("/")[2] for row in receipt}, expected)
            self.assertEqual(len(calls), 30)
            self.assertEqual(len({row["sha256"] for row in receipt}), 10)
            self.assertTrue(all(row["architectures"] == ["arm64", "x86_64"] for row in receipt))

    def test_missing_core_service_cannot_be_packaged_as_a_complete_fork(self):
        with TemporaryDirectory() as directory:
            root = make_products(directory)
            (root / "src/apps/CoreService/build/Release/Karabiner-Core-Service.app/Contents/MacOS/native-peer").unlink()
            with self.assertRaisesRegex(ValueError, "Missing or redirected product executable"):
                inspect_products(root, signature_verifier([]))

    def test_bad_signature_and_missing_architecture_refuse_the_candidate(self):
        with TemporaryDirectory() as directory:
            root = make_products(directory)
            with self.assertRaises(subprocess.CalledProcessError):
                inspect_products(root, signature_verifier([], "Karabiner-Console-User-Server.app"))
            with self.assertRaisesRegex(ValueError, "both supported architectures"):
                inspect_products(root, lambda command: "arm64" if command[0].endswith("lipo") else signature_verifier([])(command))

    def test_valid_official_client_cannot_mix_with_adhoc_fork_peers(self):
        with TemporaryDirectory() as directory:
            root = make_products(directory)
            def mixed(command):
                if "--display" in command and "Karabiner-Console-User-Server.app" in command[-1]:
                    return "TeamIdentifier=official-team\n"
                return signature_verifier([])(command)
            with self.assertRaisesRegex(ValueError, "different signing teams"):
                inspect_products(root, mixed)

    def test_a_signed_binary_without_its_launchd_resources_is_not_ready(self):
        with TemporaryDirectory() as directory:
            root = make_products(directory, resources=False)
            with self.assertRaisesRegex(ValueError, "launchd"):
                inspect_products(root, signature_verifier([]))

    def test_each_missing_or_changed_launchd_copy_refuses_the_candidate(self):
        for index, (_, component, folder) in enumerate(LAUNCHD_RESOURCES):
            with self.subTest(component=component, index=index), TemporaryDirectory() as directory:
                root = make_products(directory)
                copied = root / "src" / component / "build/Release" / dict(PRODUCTS)[component] / "Contents/Library" / folder / (str(index) + ".plist")
                copied.write_bytes(b"changed launchd configuration")
                with self.assertRaisesRegex(ValueError, "changed launchd"):
                    inspect_products(root, signature_verifier([]))
                copied.unlink()
                with self.assertRaisesRegex(ValueError, "Missing or changed launchd"):
                    inspect_products(root, signature_verifier([]))

    def test_product_metadata_cannot_redirect_the_executable(self):
        with TemporaryDirectory() as directory:
            root = make_products(directory)
            info = root / "src/apps/CoreService/build/Release/Karabiner-Core-Service.app/Contents/Info.plist"
            info.write_bytes(plistlib.dumps({"CFBundleExecutable": "../../foreign"}))
            with self.assertRaisesRegex(ValueError, "Invalid product executable name"):
                inspect_products(root, signature_verifier([]))

    def test_assembly_reuses_upstream_without_rebuilding_or_losing_identity(self):
        source = "#!/bin/bash\n" + BUILD_STEP + "\n# copy complete package\n" + SIGN_STEP + "\npkgbuild owned\n"
        result = packaging_script(source, Path("candidate identity.json"))
        self.assertNotIn(BUILD_STEP, result)
        self.assertEqual(result.count(SIGN_STEP), 1)
        self.assertLess(result.index("cp 'candidate identity.json'"), result.index(SIGN_STEP))
        self.assertIn("ergopti-candidate.json", result)
        self.assertIn("pkgbuild owned", result)
        for invalid in (source.replace(BUILD_STEP, ""), source + SIGN_STEP):
            with self.subTest(source=invalid), self.assertRaisesRegex(ValueError, "script changed"):
                packaging_script(invalid, Path("identity.json"))

    def test_assembly_executes_identity_copy_before_the_upstream_signing_step(self):
        with TemporaryDirectory(prefix="ergopti package ") as directory:
            root = Path(directory)
            target = "pkgroot/Library/Application Support/org.pqrs/Karabiner-Elements/ergopti-candidate.json"
            (root / target).parent.mkdir(parents=True)
            (root / "scripts").mkdir()
            (root / "scripts/codesign.sh").write_text('test -f "' + target + '"\n', encoding="utf-8")
            identity = root / "candidate identity '$value.json"
            identity.write_bytes(b"exact candidate identity")
            source = "set -eu\nruby() { exit 98; }\n" + BUILD_STEP + "\n" + SIGN_STEP + "\n"
            script = packaging_script(source, identity.as_posix())
            result = subprocess.run([shutil.which("bash") or "/bin/bash", "-c", script], cwd=root,
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / target).read_bytes(), identity.read_bytes())


if __name__ == "__main__":
    unittest.main()
