# tools/diagnostics/hs274_services_test.py
"""Portable verdict regressions for the native HS-274 isolation observation."""

import subprocess
import unittest
from unittest.mock import patch

import hs274_services as services


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


if __name__ == "__main__":
    unittest.main()
