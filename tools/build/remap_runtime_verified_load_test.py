# tools/build/remap_runtime_verified_load_test.py
"""Real CLI/cache controls over private copies; no native compilation authority."""

import hashlib
import importlib.util
import json
import marshal
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FILES = (
    "tools/build/remap_runtime_build.py",
    "tools/diagnostics/hs274_native_build.py",
    "tools/build/remap_runtime_patch.py",
)
IDENTIFIERS = {
    "core": "com.ergoptiplus.remap.core",
    "console": "com.ergoptiplus.remap.console",
    "cli": "com.ergoptiplus.remap.cli",
}


class VerifiedLoadControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ergopti-verified-load-")
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name).resolve()
        self.repository.chmod(0o700)
        for relative in FILES:
            destination = self.repository / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        self.sources = self.hashes()
        self.marker = self.repository / "foreign-cache-executed"

    def hashes(self):
        return {
            relative: hashlib.sha256((self.repository / relative).read_bytes()).hexdigest()
            for relative in FILES
        }

    def foreign_cache(self, relative, optimize):
        source = self.repository / relative
        suffix = ".opt-1" if optimize else ""
        cache = (
            source.parent
            / "__pycache__"
            / (source.stem + "." + sys.implementation.cache_tag + suffix + ".pyc")
        )
        cache.parent.mkdir(mode=0o700)
        payload = (
            "from pathlib import Path\nPath("
            + repr(str(self.marker))
            + ').write_text("foreign bytecode")\nraise RuntimeError("owned cache witness")\n'
        )
        code = compile(payload, str(source), "exec", optimize=1 if optimize else 0)
        info = source.stat()
        cache.write_bytes(
            importlib.util.MAGIC_NUMBER
            + struct.pack("<III", 0, int(info.st_mtime) & 0xFFFFFFFF, info.st_size & 0xFFFFFFFF)
            + marshal.dumps(code)
        )
        return cache

    def run_copy(self, provider=False, foreign=None, optimize=False, dontwrite=False):
        if foreign is not None:
            self.foreign_cache(foreign, optimize)
        environment = dict(os.environ)
        for name in ("PYTHONOPTIMIZE", "PYTHONDONTWRITEBYTECODE", "PYTHONPYCACHEPREFIX"):
            environment.pop(name, None)
        if optimize:
            environment["PYTHONOPTIMIZE"] = "1"
        if dontwrite:
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
        builder = self.repository / FILES[0]
        if provider:
            script = """import importlib.util,json,sys
from pathlib import Path
path=Path(sys.argv[1])
spec=importlib.util.spec_from_file_location('actual_verified_builder',path)
module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module
spec.loader.exec_module(module)
print(json.dumps(module._identifiers(),sort_keys=True))
"""
            command = [sys.executable, "-c", script, str(builder)]
        else:
            command = [sys.executable, str(builder), "--help"]
        result = subprocess.run(
            command, cwd=self.repository, env=environment, capture_output=True, timeout=10
        )
        self.assertEqual(self.hashes(), self.sources)
        self.assertFalse(
            self.marker.exists(), "Verified source must not execute foreign cache bytes"
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        if provider:
            self.assertEqual(json.loads(result.stdout), IDENTIFIERS)
        else:
            self.assertIn(b"usage:", result.stdout)
            self.assertIn(b"--source-controls", result.stdout)

    def test_healthy_actual_cli(self):
        self.run_copy()

    def test_healthy_actual_provider(self):
        self.run_copy(provider=True)

    def test_foreign_base_cache_normal(self):
        self.run_copy(foreign=FILES[1])

    def test_foreign_base_cache_dontwrite_still_cannot_execute(self):
        self.run_copy(foreign=FILES[1], dontwrite=True)

    def test_foreign_base_cache_inherited_optimization(self):
        self.run_copy(foreign=FILES[1], optimize=True)

    def test_foreign_provider_cache_normal(self):
        self.run_copy(provider=True, foreign=FILES[2])

    def test_foreign_provider_cache_inherited_optimization(self):
        self.run_copy(provider=True, foreign=FILES[2], optimize=True)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(VerifiedLoadControls)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    passed = result.wasSuccessful() and result.testsRun == 7 and not result.skipped
    print(
        ("PASS" if passed else "FAIL")
        + " portable retained builder source tests="
        + str(result.testsRun)
        + " failures="
        + str(len(result.failures))
        + " errors="
        + str(len(result.errors))
        + " skipped="
        + str(len(result.skipped))
    )
    raise SystemExit(0 if passed else 1)
