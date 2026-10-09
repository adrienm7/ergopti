# tools/diagnostics/macos_ollama_hint_metadata_test.py
"""Actual POSIX metadata reads and independent source/catalogue selection vectors."""

import importlib.util
import os
import re
import shutil
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("ERGOPTI_SOURCE_ROOT", ROOT))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


PORT = load("hint_port", ROOT / "static/ergopti_plus/macos/platform/ollama_hint_metadata.py")
ENTRY = load("hint_entry", ROOT / "static/ergopti_plus/macos/modules/llm/managed_ollama_hint.py")
VECTORS = load("hint_original_vectors", SOURCE / "tools/test/managed_ollama_runtime_policy_test.py")


@unittest.skipUnless(os.name == "posix", "Actual POSIX file ownership required")
class MetadataPort(unittest.TestCase):
    def setUp(self):
        self.owned = tempfile.TemporaryDirectory()
        self.addCleanup(self.owned.cleanup)
        self.path = Path(self.owned.name) / "metadata"
        self.path.write_bytes(b"independent regular bytes")

    def read(self, maximum=64):
        return PORT.read_regular(self.path, maximum, progress=lambda: None)

    def test_actual_regular_fd_has_nofollow_nonblock_cloexec_and_is_closed(self):
        opened = []
        original = os.open

        def acquire(path, flags):
            descriptor = original(path, flags)
            opened.append((descriptor, flags))
            return descriptor

        with mock.patch.object(PORT.os, "open", side_effect=acquire):
            self.assertEqual(self.read(), b"independent regular bytes")
        self.assertEqual(len(opened), 1)
        self.assertEqual(
            opened[0][1] & (os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC),
            os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
        )
        with self.assertRaises(OSError):
            os.fstat(opened[0][0])

    def test_genuine_fifo_without_writer_refuses_in_actual_bounded_process(self):
        self.path.unlink()
        os.mkfifo(self.path)
        code = "import importlib.util,sys; s=importlib.util.spec_from_file_location('port',sys.argv[1]);p=importlib.util.module_from_spec(s);s.loader.exec_module(p);p.read_regular(sys.argv[2],64,progress=lambda:None)"
        completed = subprocess.run(
            [sys.executable, "-IB", "-c", code, PORT.__file__, str(self.path)],
            capture_output=True,
            timeout=3,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(b"MetadataRefusal", completed.stderr)

    def test_actual_symlink_refuses_without_following_target(self):
        target = self.path.with_name("foreign")
        self.path.rename(target)
        self.path.symlink_to(target)
        with self.assertRaises(OSError):
            self.read()

    def test_initial_oversize_refuses_before_any_body_read(self):
        self.path.write_bytes(b"x" * 65)
        with mock.patch.object(PORT.os, "read", wraps=os.read) as observed:
            with self.assertRaises(PORT.MetadataRefusal):
                self.read()
        observed.assert_not_called()

    def test_genuine_growth_during_read_never_consumes_more_than_limit_plus_probe(self):
        self.path.write_bytes(b"x" * 20)
        original = os.read
        counts = []

        def read(descriptor, count):
            if not counts:
                with self.path.open("ab") as stream:
                    stream.write(b"g" * (2 * 1024 * 1024))
            result = original(descriptor, count)
            counts.append(len(result))
            return result

        with mock.patch.object(PORT.os, "read", side_effect=read):
            with self.assertRaises(PORT.MetadataRefusal):
                self.read()
        self.assertLessEqual(sum(counts), 65)

    def test_real_named_replacement_refuses_original_retained_bytes(self):
        original = os.read
        replaced = False

        def read(descriptor, count):
            nonlocal replaced
            if not replaced:
                replaced = True
                self.path.rename(self.path.with_name("original"))
                self.path.write_bytes(b"independent regular bytes")
            return original(descriptor, count)

        with mock.patch.object(PORT.os, "read", side_effect=read):
            with self.assertRaises(PORT.MetadataRefusal):
                self.read()

    def test_uncertain_close_after_actual_close_is_terminal_cleanup_debt(self):
        original = os.close

        def close(descriptor):
            original(descriptor)
            raise OSError("controlled uncertain close")

        with mock.patch.object(PORT.os, "close", side_effect=close):
            with self.assertRaises(PORT.MetadataRefusal) as caught:
                self.read()
        self.assertEqual(str(caught.exception), "cleanup")
        self.assertIsInstance(caught.exception.cleanup, OSError)

    def test_genuine_sigint_after_native_open_is_delivered_only_after_owned_registration(self):
        opened = []
        original = os.open

        def acquire(path, flags):
            descriptor = original(path, flags)
            opened.append(descriptor)
            os.kill(os.getpid(), signal.SIGINT)
            return descriptor

        with mock.patch.object(PORT.os, "open", side_effect=acquire):
            with self.assertRaises(KeyboardInterrupt):
                self.read()
        self.assertEqual(len(opened), 1)
        with self.assertRaises(OSError):
            os.fstat(opened[0])


class HintSelection(unittest.TestCase):
    def setUp(self):
        self.vector = VECTORS.RuntimePolicyTests("runTest")
        self.vector.setUp()
        self.addCleanup(self.vector.doCleanups)
        self.owned = tempfile.TemporaryDirectory()
        self.addCleanup(self.owned.cleanup)
        self.home = Path(self.owned.name) / "home"
        self.driver = Path(self.owned.name) / "macos"
        self.shared = self.driver.parent / "_shared/modules/llm"
        self.shared.mkdir(parents=True)
        retry_data = self.driver.parent / "_shared/modules/network/bootstrap_retry.json"
        retry_data.parent.mkdir(parents=True)
        retry_data.write_bytes(
            b'{"schema_version":1,"admission_seconds":30,"idle_seconds":60,"retirement_seconds":600}'
        )
        self.directory = self.home / "Library/Application Support/Ergopti/ollama-native-http"
        self.directory.mkdir(parents=True)
        self.binary = self.directory / "ollama"
        self.binary.write_bytes(b"provisional executable, deliberately not native authority")
        self.binary.chmod(0o755)
        (self.driver / "modules/llm").mkdir(parents=True)
        self.retry = self.driver / "modules/llm/network-retry.sh"
        self.retry.write_bytes(
            b"CURL_CONNECT_TIMEOUT_SEC=30\nCURL_STALL_SEC=60\nCURL_MAX_TIME_SEC=600\n"
        )
        (self.shared / "managed_ollama_bootstrap.json").write_bytes(
            b'{"maximum_metadata_bytes":1048576}'
        )
        (self.shared / "managed_ollama_runtime.json").write_bytes(self.vector.contract_bytes)
        (self.shared / "managed_ollama_release.json").write_bytes(self.vector.encode())
        self.receipt = self.directory / ENTRY.POLICY.RECEIPT_BASENAME
        import json

        expected = VECTORS.POLICY.receipt(
            self.vector.contract_bytes, self.vector.encode(), "macos-arm64", self.vector.asset
        )
        self.receipt.write_text(json.dumps(expected))

    def receive(self, **options):
        return ENTRY.receive(self.driver, str(self.home), "macos-arm64", **options)

    def test_exact_original_vector_emits_hint_and_existing_budgets_without_source_authority(self):
        self.assertEqual(
            self.receive(),
            {
                "version": 1,
                "candidate": str(self.binary),
                "budgets": {"admission": 30, "idle": 60, "retirement": 600},
            },
        )
        self.assertEqual(
            self.binary.read_bytes(), b"provisional executable, deliberately not native authority"
        )

    def test_foreign_receipt_and_duplicate_json_refuse_candidate(self):
        for data in (b'{"schema_version":1}', b'{"host":"macos-arm64","host":"macos-arm64"}'):
            self.receipt.write_bytes(data)
            with self.assertRaises(ENTRY.POLICY.RuntimeRefusal):
                self.receive()

    def test_duplicate_or_boolean_style_budget_refuses(self):
        for data in (
            b"CURL_CONNECT_TIMEOUT_SEC=30\nCURL_STALL_SEC=60\nCURL_STALL_SEC=60\nCURL_MAX_TIME_SEC=600\n",
            b"CURL_CONNECT_TIMEOUT_SEC=true\nCURL_STALL_SEC=60\nCURL_MAX_TIME_SEC=600\n",
        ):
            self.retry.write_bytes(data)
            with self.assertRaises(ENTRY.POLICY.RuntimeRefusal):
                self.receive()

    def test_clock_captured_before_first_read_cannot_gain_new_admission_budget(self):
        samples = iter((1.0, 32.0))
        with mock.patch.object(
            ENTRY.NATIVE, "read_regular", wraps=ENTRY.NATIVE.read_regular
        ) as reads:
            with self.assertRaises(ENTRY.POLICY.RuntimeRefusal) as caught:
                self.receive(clock=lambda: next(samples))
        self.assertEqual(str(caught.exception), "deadline")
        self.assertEqual(reads.call_count, 1)

    def test_initial_bootstrap_policy_is_capped_by_existing_canonical_metadata_limit(self):
        (self.shared / "managed_ollama_bootstrap.json").write_bytes(
            b"x" * (ENTRY.POLICY.MAXIMUM_METADATA_BYTES + 1)
        )
        with self.assertRaises(ENTRY.NATIVE.MetadataRefusal):
            self.receive()

    def test_wrong_host_and_noncanonical_metadata_cap_refuse(self):
        with self.assertRaises(ENTRY.POLICY.RuntimeRefusal):
            ENTRY.receive(self.driver, str(self.home), "macos-amd64")
        (self.shared / "managed_ollama_bootstrap.json").write_bytes(
            b'{"maximum_metadata_bytes":true}'
        )
        with self.assertRaises(ENTRY.POLICY.RuntimeRefusal):
            self.receive()

    def test_retry_file_real_fifo_refuses_before_budget_or_source_reads(self):
        self.retry.unlink()
        os.mkfifo(self.retry)
        with self.assertRaises(ENTRY.NATIVE.MetadataRefusal):
            self.receive()


class OriginalRemainingBudget(unittest.TestCase):
    setUp = HintSelection.setUp
    receive = HintSelection.receive

    def test_parent_remaining_budget_covers_initial_canonical_read(self):
        samples = iter((1.0, 3.0))
        with mock.patch.object(
            ENTRY.NATIVE, "read_regular", wraps=ENTRY.NATIVE.read_regular
        ) as reads:
            with self.assertRaises(ENTRY.POLICY.RuntimeRefusal):
                self.receive(remaining=1.0, clock=lambda: next(samples))
        self.assertEqual(reads.call_count, 1)

    def test_changed_canonical_source_and_shell_binding_refuse(self):
        with self.assertRaises(ENTRY.POLICY.RuntimeRefusal):
            self.receive(expected_policy_sha256="f" * 64)
        self.retry.write_bytes(
            b"CURL_CONNECT_TIMEOUT_SEC=31\nCURL_STALL_SEC=60\nCURL_MAX_TIME_SEC=600\n"
        )
        with self.assertRaises(ENTRY.POLICY.RuntimeRefusal):
            self.receive()


class IsolatedBytecodeControls(unittest.TestCase):
    def copied_cli(self, flag):
        with tempfile.TemporaryDirectory() as temporary:
            copied = Path(temporary)
            paths = (
                "static/ergopti_plus/macos/modules/llm/managed_ollama_hint.py",
                "static/ergopti_plus/macos/platform/ollama_hint_metadata.py",
                "static/ergopti_plus/_shared/python/managed_ollama_runtime.py",
                "static/ergopti_plus/_shared/python/managed_ollama_hint.py",
            )
            for relative in paths:
                destination = copied / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / relative, destination)
            environment = dict(os.environ)
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            completed = subprocess.run(
                [sys.executable, flag, str(copied / paths[0])],
                env=environment,
                capture_output=True,
                timeout=3,
            )
            self.assertNotEqual(completed.returncode, 0)
            return list(copied.rglob("*.pyc")) != []

    def test_isolation_ignores_inherited_no_bytecode_on_exact_production_imports(self):
        self.assertTrue(self.copied_cli("-I"))

    def test_emitted_hint_option_disables_bytecode_without_moving_arguments(self):
        source = (ROOT / "static/ergopti_plus/macos/adapters/managed_ollama_hint.lua").read_text()
        matched = re.search(
            r'pcall\(ShellRunner\.spawn, python, \{\s*"([^"]+)", driver \.\. "/modules/llm/managed_ollama_hint\.py"',
            source,
        )
        self.assertIsNotNone(matched)
        self.assertFalse(self.copied_cli(matched[1]))
        self.assertEqual(matched[1], "-IB")


if __name__ == "__main__":
    unittest.main()
