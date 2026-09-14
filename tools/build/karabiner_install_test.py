# tools/build/karabiner_install_test.py
"""The selected fork must replace actual installed bytes and preserve user data."""

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from karabiner_candidate import PRODUCTS, inspect_products
from karabiner_candidate_install import MARKER, configuration_snapshot, reference, verify_configuration, verify_download, verify_installed
from karabiner_test_fixture import make_products, signature_verifier


def installed_fixture(directory):
    root = Path(directory).resolve()
    build = make_products(root / "build")
    base = root / "installed/Library/Application Support/org.pqrs/Karabiner-Elements"
    applications = root / "installed/Applications"
    identity = copy.deepcopy(reference()["identity"])
    identity["products"] = inspect_products(build, signature_verifier([]))
    for component, name in PRODUCTS:
        source = build / "src" / component / "build/Release" / name
        if name in ("Karabiner-Elements.app", "Karabiner-EventViewer.app"):
            destination = applications / name
        elif name == "karabiner_cli":
            destination = base / "bin" / name
        else:
            destination = base / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, destination)
        else:
            shutil.copyfile(source, destination)
    marker = {key: value for key, value in identity.items() if key != "package"}
    (base / MARKER).write_text(json.dumps(marker), encoding="utf-8")
    return base, applications, identity


class InstalledCandidateTests(unittest.TestCase):
    def test_native_reference_selects_a_complete_successful_package(self):
        receipt = reference()
        self.assertEqual(receipt["run_id"], 34891285619)
        self.assertEqual(len(receipt["identity"]["products"]), 10)
        self.assertEqual(receipt["package_bytes"], 42431095)

    def test_complete_installed_peer_set_passes_the_shared_signature_policy(self):
        with TemporaryDirectory() as directory:
            base, applications, identity = installed_fixture(directory)
            actual = verify_installed(base, applications, identity, signature_verifier([]))
            self.assertEqual(len(actual), 10)
            self.assertEqual({row["sha256"] for row in actual}, {row["sha256"] for row in identity["products"]})
            self.assertTrue(any(row["product"] == str(applications / "Karabiner-Elements.app") for row in actual))

    def test_valid_marker_does_not_hide_an_official_cli_left_installed(self):
        with TemporaryDirectory() as directory:
            base, applications, identity = installed_fixture(directory)
            (base / "bin/karabiner_cli").write_bytes(b"official CLI remained installed")
            with self.assertRaisesRegex(ValueError, "bin/cli: sha256"):
                verify_installed(base, applications, identity, signature_verifier([]))

    def test_changed_marker_refuses_otherwise_matching_products(self):
        with TemporaryDirectory() as directory:
            base, applications, identity = installed_fixture(directory)
            marker = json.loads((base / MARKER).read_text(encoding="utf-8"))
            marker["coverage"] = "unverified"
            (base / MARKER).write_text(json.dumps(marker), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "marker differs"):
                verify_installed(base, applications, identity, signature_verifier([]))

    def test_image_bytes_are_verified_before_installation(self):
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            receipt = copy.deepcopy(reference())
            data = b"controlled candidate image"
            receipt["package_bytes"] = len(data)
            receipt["identity"]["package"]["sha256"] = hashlib.sha256(data).hexdigest()
            image = root / receipt["identity"]["package"]["file_name"]
            image.write_bytes(data)
            (root / "identity.json").write_text(json.dumps(receipt["identity"]), encoding="utf-8")
            self.assertEqual(verify_download(root, receipt), image)
            image.write_bytes(b"wrong candidate image")
            with self.assertRaisesRegex(ValueError, "image does not match"):
                verify_download(root, receipt)

    def test_linked_profile_content_is_part_of_the_preservation_check(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            configuration = root / "config"
            configuration.mkdir()
            target = root / "profile-in-checkout.json"
            target.write_text('{"profiles":[{"name":"personal"}]}', encoding="utf-8")
            try:
                (configuration / "karabiner.json").symlink_to(target)
            except OSError:
                if sys.platform == "win32":
                    self.skipTest("Windows host does not permit symbolic-link creation")
                raise
            before = configuration_snapshot(configuration)
            target.write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "karabiner.json"):
                verify_configuration(before, configuration_snapshot(configuration))

    def test_unreadable_configuration_subtree_cannot_be_silently_omitted(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "karabiner.json").write_text("{}", encoding="utf-8")
            protected = root / "assets"
            protected.mkdir()
            original = os.scandir
            def denied(path):
                if Path(path) == protected:
                    raise PermissionError("fixture configuration is unreadable")
                return original(path)
            with patch("os.scandir", side_effect=denied):
                with self.assertRaisesRegex(PermissionError, "unreadable"):
                    configuration_snapshot(root)

    def test_existing_profile_and_rules_survive_while_new_backups_are_allowed(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "karabiner.json").write_text('{"profiles":[{"name":"personal"}]}', encoding="utf-8")
            rules = root / "assets/rules.json"
            rules.parent.mkdir()
            rules.write_text('{"personal_rule":true}', encoding="utf-8")
            before = configuration_snapshot(root)
            (root / "new-backup.json").write_text("{}", encoding="utf-8")
            verify_configuration(before, configuration_snapshot(root))
            rules.write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "assets/rules.json"):
                verify_configuration(before, configuration_snapshot(root))
            rules.unlink()
            with self.assertRaisesRegex(ValueError, "assets/rules.json"):
                verify_configuration(before, configuration_snapshot(root))
            with self.assertRaisesRegex(ValueError, "baseline is empty"):
                verify_configuration({}, configuration_snapshot(root))


class InstallerMountTests(unittest.TestCase):
    def test_native_mount_is_released_after_success_and_installer_failure(self):
        for installer_status, detach_status, expected in ((0, 0, 0), (42, 0, 42), (0, 1, 1)):
            with self.subTest(installer=installer_status, detach=detach_status), TemporaryDirectory() as directory:
                root = Path(directory)
                image = root / "candidate image.dmg"
                image.write_bytes(b"fixture image")
                trace = root / "calls.log"
                environment = os.environ.copy()
                environment.update({"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                                    "RUNNER_TEMP": root.as_posix(), "INSTALL_STATUS": str(installer_status),
                                    "DETACH_STATUS": str(detach_status), "TASK_TRACE": trace.as_posix()})
                script = r"""
uname() { printf 'Darwin\n'; }
hdiutil() {
    if [[ "$1" == 'detach' ]]; then
        printf 'detach\n' >> "$TASK_TRACE"
        if [[ "$DETACH_STATUS" != '0' ]]; then return "$DETACH_STATUS"; fi
        rm "$2/Karabiner-Elements.pkg"
    else
        while [[ "$1" != '-mountpoint' ]]; do shift; done
        printf 'owned package' > "$2/Karabiner-Elements.pkg"
    fi
}
sudo() {
    [[ "$1" == '-n' && "$2" == '/usr/sbin/installer' ]] || return 99
    printf 'installer\n' >> "$TASK_TRACE"
    return "$INSTALL_STATUS"
}
export -f uname hdiutil sudo
bash "$1" "$2"
"""
                helper = Path(__file__).with_name("karabiner_install_image.sh").resolve()
                result = subprocess.run([shutil.which("bash") or "/bin/bash", "-c", script, "fixture",
                                         helper.as_posix(), image.as_posix()], env=environment,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(trace.read_text(encoding="utf-8").splitlines(), ["installer", "detach"])
                if detach_status == 0:
                    self.assertEqual(list(root.glob("hs274-install.*")), [])


if __name__ == "__main__":
    unittest.main()
