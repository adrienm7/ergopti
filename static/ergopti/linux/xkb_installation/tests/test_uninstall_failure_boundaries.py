"""Exercise the shell's real uninstall boundary without desktop or root writes."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("bash"), "requires Linux and bash")
class UninstallFailureBoundaryTests(unittest.TestCase):
    def test_desktop_refusal_prevents_privileged_uninstall_for_both_methods(self):
        installer = Path(__file__).resolve().parents[1] / "install.sh"
        for method in ("clean", "legacy"):
            for refusal in (False, True):
                with self.subTest(method=method, refusal=refusal), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    binaries = root / "bin"
                    binaries.mkdir()
                    marker = root / "privileged-uninstall-called"
                    python = binaries / "test-python"
                    python.write_text(
                        f"#!{sys.executable}\n"
                        "import os, sys\n"
                        "from pathlib import Path\n"
                        "if '--deactivate-only' in sys.argv:\n"
                        "    print('desktop cleanup fixture result')\n"
                        "    sys.exit(int(os.environ['DEACTIVATION_EXIT']))\n"
                        "if '--uninstall' in sys.argv:\n"
                        f"    Path({str(marker)!r}).write_text('called', encoding='utf-8')\n"
                        "    sys.exit(0)\n"
                        f"os.execv({sys.executable!r}, [{sys.executable!r}] + sys.argv[1:])\n",
                        encoding="utf-8",
                    )
                    python.chmod(0o755)
                    for name in ("sudo", "doas"):
                        helper = binaries / name
                        helper.write_text('#!/bin/sh\nexec "$@"\n', encoding="utf-8")
                        helper.chmod(0o755)
                    environment = {
                        **os.environ,
                        "PATH": str(binaries) + os.pathsep + os.environ.get("PATH", os.defpath),
                        "PYTHON": str(python),
                        "DEACTIVATION_EXIT": "4" if refusal else "0",
                        "ERGOPTI_INSTALL_LOG": str(root / "install.log"),
                        "ERGOPTI_XKB_EXTENSIONS_ROOT": str(root / "extensions"),
                        "ERGOPTI_XKB_SYSTEM_ROOT": str(root / "system"),
                        "ERGOPTI_XKB_CACHE_DIR": str(root / "cache"),
                        "ERGOPTI_XKB_USER_HOME": str(root / "home"),
                    }
                    result = subprocess.run(
                        ["bash", str(installer), "--uninstall", "--yes", "--installation-method", method],
                        env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, timeout=30, check=False,
                    )
                    self.assertIn("desktop cleanup fixture result", result.stdout)
                    if refusal:
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        self.assertFalse(marker.exists(), "desktop refusal must fence privileged file removal")
                    else:
                        self.assertEqual(result.returncode, 0, result.stdout)
                        self.assertEqual(marker.read_text(encoding="utf-8"), "called")
