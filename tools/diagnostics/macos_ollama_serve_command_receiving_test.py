# tools/diagnostics/macos_ollama_serve_command_receiving_test.py
"""Receive the production Lua-emitted command with actual Python and guard."""

import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("ERGOPTI_SOURCE_ROOT", ROOT))


@unittest.skipUnless(os.name == "posix", "Actual foreground POSIX execution required")
class EmittedServeCommand(unittest.TestCase):
    def test_actual_emitted_foreground_python_guard_preserves_refusal_without_acquisition(self):
        emitted = subprocess.run(
            [
                "lua5.4",
                str(ROOT / "tools/test/managed_ollama_serve_command_test.lua"),
                str(ROOT),
                str(SOURCE),
                "emit",
                sys.executable,
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        command = emitted.stdout.strip()
        self.assertTrue(command.startswith("exec "))
        self.assertEqual(emitted.stderr, "")
        self.assertNotIn("apply_system_network", command)
        self.assertNotIn("while IFS=", command)
        with tempfile.TemporaryDirectory(prefix="ergopti-serve-guard-") as directory:
            environment = dict(os.environ)
            environment["HOME"] = directory
            result = subprocess.run(
                ["/bin/sh", "-c", command],
                env=environment,
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 78)
            self.assertEqual(result.stdout, "")
            self.assertEqual(result.stderr, "Managed Ollama daemon admission refused.\n")
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_emitted_isolated_serve_does_not_write_source_payload_caches(self):
        with tempfile.TemporaryDirectory(prefix="ergopti-serve-source-copy-") as directory:
            copied = Path(directory) / "source"
            for relative in (
                "static/ergopti_plus/_shared/python",
                "static/ergopti_plus/macos/modules/llm",
                "static/ergopti_plus/macos/platform",
                "static/ergopti_plus/macos/platform/network",
            ):
                for source in (ROOT / relative).glob("*.py"):
                    target = copied / relative / source.name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
            for relative in (
                "static/ergopti_plus/macos/modules/llm/ollama_server_command.lua",
                "static/ergopti_plus/macos/modules/llm/ollama_binary.lua",
                "tools/test/managed_ollama_serve_command_test.lua",
                "tools/test/fixtures/managed_ollama_runtime_hint.lua",
            ):
                target = copied / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / relative, target)
            emitted = subprocess.run(
                [
                    "lua5.4",
                    str(copied / "tools/test/managed_ollama_serve_command_test.lua"),
                    str(copied),
                    str(SOURCE),
                    "emit",
                    sys.executable,
                ],
                check=True,
                capture_output=True,
                text=True,
                timeout=30,
            )
            environment = dict(os.environ)
            home = Path(directory) / "home"
            home.mkdir()
            environment["HOME"] = str(home)
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            result = subprocess.run(
                ["/bin/sh", "-c", emitted.stdout.strip()],
                env=environment,
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 78)
            self.assertEqual(result.stdout, "")
            self.assertEqual(result.stderr, "Managed Ollama daemon admission refused.\n")
            self.assertEqual(list(home.iterdir()), [])
            self.assertEqual(list(copied.rglob("*.pyc")), [])


if __name__ == "__main__":
    unittest.main()
