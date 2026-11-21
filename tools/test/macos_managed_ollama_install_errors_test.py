# tools/test/macos_managed_ollama_install_errors_test.py
"""The macOS managed Ollama install's free-space rule and failure evidence.

OLL-04, OLL-05 and OLL-14 of
docs/audits/platform-parity/2026-11-20-managed-ollama/report.md: the installer
refuses a volume without room for the archive, its unpacked runtime and the
margin before its download, and names
every failure with the closed words the driver classifies through
_shared/ai/data/ollama_install_errors.json. Nothing is downloaded or installed:
the transfer and the volume are fakes.
"""

import errno
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHARED = ROOT / "static/ergopti_plus/_shared"
RUNTIME = ROOT / "static/ergopti_plus/macos/ai/engine/ollama/managed_ollama_runtime.py"


def load_runtime():
    specification = importlib.util.spec_from_file_location("install_errors_runtime", RUNTIME)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def classify(evidence):
    """The shared rule, as _shared/ai/engine/ollama/install_errors.lua applies it."""
    data = json.loads((SHARED / "ai/data/ollama_install_errors.json").read_text(encoding="utf-8"))
    lowered = evidence.lower()
    for needle, name in data["classes"]:
        if needle in lowered:
            return name
    return "unknown"


class InstallErrorTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load_runtime()
        self.corpus = json.loads(
            (SHARED / "tests/corpus/llm/ollama_install_error_vectors.json").read_text(
                encoding="utf-8"
            )
        )

    def test_free_space_rule_replays_the_shared_vectors(self):
        for case in self.corpus["free_space"]:
            with self.subTest(case["id"]):
                self.assertIs(
                    self.runtime.fits(
                        case["asset_bytes"],
                        case["unpacked_bytes"],
                        case["margin_bytes"],
                        case["free_bytes"],
                    ),
                    case["fits"],
                )
        with self.assertRaises(self.runtime.POLICY.RuntimeRefusal):
            self.runtime.fits(None, 0, 0, 1)
        with self.assertRaises(self.runtime.POLICY.RuntimeRefusal):
            self.runtime.fits(1, None, 0, 1)

    def test_margin_is_the_registry_value(self):
        text = (SHARED / "core/timing/data/constants.toml").read_text(encoding="utf-8")
        self.assertIn(
            "ollama_install_free_space_margin_bytes = %d" % self.runtime.free_space_margin(), text
        )

    def test_evidence_of_each_failure_is_a_shared_vector(self):
        runtime = self.runtime
        refusal, failure = runtime.POLICY.RuntimeRefusal, runtime.BOOTSTRAP.BootstrapFailure

        def during_download(error):
            error.ergopti_install_phase = "download"
            return error

        produced = {
            "macos_disk_full_precheck": refusal("install_disk_full"),
            "macos_disk_full_write": during_download(
                OSError(errno.ENOSPC, "No space left on device")
            ),
            "macos_permission": OSError(errno.EACCES, "Permission denied"),
            "macos_cancelled": during_download(refusal("cancelled")),
            "macos_checksum_download": during_download(failure("integrity")),
            "macos_checksum_local": refusal("checksum"),
            "macos_network_connect": during_download(failure("connect")),
            "macos_network_http": during_download(failure("http")),
            "macos_network_deadline": during_download(failure("deadline")),
            "macos_unknown_signature": refusal("signature"),
        }
        cases = {case["id"]: case for case in self.corpus["cases"] if case["os"] == "macos"}
        self.assertEqual(set(produced), set(cases), "every macOS vector is produced here")
        for name, error in produced.items():
            with self.subTest(name):
                evidence = runtime.install_failure_evidence(error)
                self.assertEqual(evidence, cases[name]["evidence"])
                self.assertEqual(classify(evidence), cases[name]["class"])

    def test_evidence_never_carries_free_text(self):
        evidence = self.runtime.install_failure_evidence(ValueError("/Users/someone/secret path"))
        self.assertEqual(evidence, "phase=install reason=unavailable")

    def _install(self, free, download):
        runtime = self.runtime
        owned = tempfile.TemporaryDirectory()
        self.addCleanup(owned.cleanup)
        target = Path(owned.name) / "Ergopti" / "ollama-native-http"
        asset = {
            "url": "https://example.invalid/ollama.tgz",
            "filename": "ollama.tgz",
            "sha256": "a" * 64,
            "bytes": 174459907,
            "unpacked_bytes": 523379721,
        }
        runtime.inputs = lambda: (b"{}", b"{}", "macos-arm64", {}, asset)
        runtime.owned_directory = lambda: target
        runtime.POLICY.receipt = lambda *arguments: {}
        runtime.free_bytes = lambda path: free
        runtime.BOOTSTRAP.download = download
        return runtime.install(10**9, 60, connect_timeout=5, minimum_bytes_per_second=1)

    def test_a_volume_without_room_refuses_before_the_download(self):
        downloads = []
        with self.assertRaises(self.runtime.POLICY.RuntimeRefusal) as caught:
            self._install(174459907, lambda *arguments, **options: downloads.append(arguments))
        self.assertEqual(caught.exception.args, ("install_disk_full",))
        self.assertEqual(downloads, [], "nothing was downloaded")
        self.assertEqual(
            classify(self.runtime.install_failure_evidence(caught.exception)), "disk_full"
        )

    def test_room_for_the_archive_and_margin_alone_refuses_before_the_download(self):
        # OLL-14: the archive stays until its extraction ends.
        downloads = []
        enough_for_the_archive = 174459907 + self.runtime.free_space_margin()
        with self.assertRaises(self.runtime.POLICY.RuntimeRefusal) as caught:
            self._install(
                enough_for_the_archive, lambda *arguments, **options: downloads.append(arguments)
            )
        self.assertEqual(caught.exception.args, ("install_disk_full",))
        self.assertEqual(downloads, [], "nothing was downloaded")

    def test_a_failed_transfer_names_the_download_phase(self):
        runtime = self.runtime

        def unreachable(*arguments, **options):
            raise runtime.BOOTSTRAP.BootstrapFailure("connect")

        with self.assertRaises(runtime.BOOTSTRAP.BootstrapFailure) as caught:
            self._install(10**12, unreachable)
        evidence = runtime.install_failure_evidence(caught.exception)
        self.assertEqual(evidence, "phase=download reason=connect")
        self.assertEqual(classify(evidence), "network")

    def test_free_bytes_reads_the_nearest_existing_folder(self):
        with tempfile.TemporaryDirectory() as owned:
            missing = Path(owned) / "not" / "yet"
            if hasattr(os, "statvfs"):
                self.assertGreater(self.runtime.free_bytes(missing), 0)

    # On macOS the CLI would read the real host; Windows has no SIGHUP to trap.
    @unittest.skipUnless(sys.platform.startswith("linux"), "the CLI refuses a Linux host at once")
    def test_cli_prints_the_evidence_line_before_its_exit(self):
        completed = subprocess.run(
            [
                sys.executable,
                "-I",
                str(RUNTIME),
                "install",
                "--timeout",
                "5",
                "--idle-timeout",
                "5",
                "--connect-timeout",
                "5",
                "--minimum-bytes-per-second",
                "1",
            ],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(completed.returncode, 78)
        self.assertIn("OLLAMA_INSTALL_FAILURE phase=install reason=unavailable\n", completed.stdout)
        self.assertEqual(completed.stderr, "Managed Ollama runtime admission refused.\n")


if __name__ == "__main__":
    unittest.main()
