# tools/diagnostics/hs274_services_test.py
"""Portable verdict regressions for the native HS-274 isolation observation."""

import subprocess
import os
from pathlib import Path
import stat
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import hs274_services as services
import hs274_registration as registration


class RuntimeInventoryTests(unittest.TestCase):
    """A successful remapping step must not hide foreign or surviving peers."""

    runtime = {"core": "/development/Karabiner-Core-Service",
               "console": "/development/Karabiner-Console-User-Server"}
    cohort = "10 /development/Karabiner-Core-Service\n11 /development/Karabiner-Core-Service\n12 /development/Karabiner-Console-User-Server\n"

    def test_complete_cohort_is_recorded(self):
        report = {}
        with patch.object(services, "require_success", return_value=self.cohort):
            services.check_runtime_processes(self.runtime, report, "ready", True)
        self.assertEqual([row["pid"] for row in report["runtime_process_inventory"]["ready"]], [10, 11, 12])

    def test_foreign_and_duplicate_and_missing_peers_fail(self):
        for inventory in (self.cohort + "13 /official/Karabiner-Console-User-Server\n",
                          self.cohort + "14 /development/Karabiner-Core-Service\n",
                          "10 /development/Karabiner-Core-Service\n", ""):
            with self.subTest(inventory=inventory), patch.object(services, "require_success", return_value=inventory):
                with self.assertRaises(RuntimeError):
                    services.check_runtime_processes(self.runtime, {}, "ready", True)

    def test_cleanup_rejects_surviving_owned_peers(self):
        with patch.object(services, "require_success", return_value=self.cohort):
            with self.assertRaisesRegex(RuntimeError, "outlived"):
                services.check_runtime_processes(self.runtime, {}, "cleanup", False)

    def test_empty_cleanup_is_recorded(self):
        report = {}
        with patch.object(services, "require_success", return_value="42 /usr/bin/other\n"):
            services.check_runtime_processes(self.runtime, report, "cleanup", False)
        self.assertEqual(report["runtime_process_inventory"]["cleanup"], [])

    def test_inventory_query_failure_is_not_absence(self):
        with patch.object(services, "command", return_value=subprocess.CompletedProcess([], 1, "", "denied")):
            with self.assertRaisesRegex(RuntimeError, "denied"):
                services.check_runtime_processes(self.runtime, {}, "cleanup", False)

    def test_service_fence_requires_the_exact_disabled_label(self):
        for output, accepted in (('"owned" => disabled', True), ('"owned" => enabled', False),
                                 ('"other" => disabled', False), ('"owned-extra" => disabled', False),
                                 ('"owned" => disabled-extra', False)):
            report = {}
            with self.subTest(output=output), patch.object(services, "service_targets", return_value=("gui/501/owned",)), \
                    patch.object(services, "require_success", return_value=output):
                if accepted:
                    services.verify_disabled(report)
                    self.assertEqual(report["service_fence_checks"], [{"gui/501/owned": True}])
                    self.assertEqual(report["service_fence_output"], [{"gui/501/owned": output}])
                else:
                    with self.assertRaisesRegex(RuntimeError, "not retained"):
                        services.verify_disabled(report)


class RegistrationScopeTests(unittest.TestCase):
    """Exercise restoration without changing any native service or real file."""

    def test_restores_both_modes_after_success_and_failures(self):
        paths = (Path("/owned/daemon"), Path("/owned/agent"))
        for failure in (None, "body", "second-helper"):
            with self.subTest(failure=failure):
                modes = {str(paths[0]): 0o755, str(paths[1]): 0o751}
                originals = modes.copy()
                report = {}
                failed = False

                def snapshot(path):
                    return SimpleNamespace(st_mode=stat.S_IFREG | modes[str(path)], st_dev=1, st_ino=paths.index(path) + 1)

                def chmod(arguments):
                    nonlocal failed
                    mode, path = int(arguments[3], 8), arguments[4]
                    if failure == "second-helper" and path == str(paths[1]) and mode == 0o640 and not failed:
                        failed = True
                        raise RuntimeError("injected chmod failure")
                    modes[path] = mode
                    return ""

                def native_refusal(arguments):
                    if arguments[:4] == ["sudo", "-n", "/usr/bin/env", "LC_ALL=C"]:
                        return subprocess.CompletedProcess(arguments, 126, "", "env: helper: Permission denied")
                    return subprocess.CompletedProcess(arguments, 1, "", "sudo: helper: command not found")

                with patch.object(registration.sys, "platform", "darwin"), \
                        patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "HS274_DEVELOPMENT_ROOT": "/development"}), \
                        patch.object(registration, "helper_paths", return_value=tuple((p, "status") for p in paths)), \
                        patch.object(Path, "lstat", snapshot), patch.object(Path, "resolve", lambda p: p), \
                        patch.object(registration, "require_success", side_effect=chmod), \
                        patch.object(registration, "command", side_effect=native_refusal):
                    try:
                        with registration.suspended_registration(report):
                            self.assertEqual(modes, {str(paths[0]): 0o644, str(paths[1]): 0o640})
                            if failure == "body":
                                raise RuntimeError("injected body failure")
                    except RuntimeError as error:
                        self.assertIsNotNone(failure)
                        self.assertIn("injected", str(error))
                    else:
                        self.assertIsNone(failure)
                self.assertEqual(modes, originals)
                self.assertEqual([r["restored"] for r in report["registration_helpers"]], [True, True])

    def test_replaced_helper_identity_is_rejected(self):
        record = {"path": "/owned/helper", "device": 1, "inode": 2}
        snapshot = SimpleNamespace(st_mode=stat.S_IFREG | 0o644, st_dev=1, st_ino=3)
        with patch.object(Path, "lstat", return_value=snapshot), patch.object(Path, "resolve", lambda p: p):
            with self.assertRaisesRegex(RuntimeError, "identity changed"):
                registration.inspect_owned(record)


if __name__ == "__main__":
    unittest.main()
