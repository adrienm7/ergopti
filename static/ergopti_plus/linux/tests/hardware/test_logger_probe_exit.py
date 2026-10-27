"""Failed probe allocation cannot authorize mutation of an unrelated path."""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


PROBE = r"""
local root = arg[1]
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;'
  .. root .. '/../_shared/lua/?.lua;' .. root .. '/../_shared/lua/?/init.lua;' .. package.path
local sink = require('infra.logger_sink')
assert(package.loaded['adapters.shell_runner'] == nil, 'cold sink must not import the shell adapter')
local ok, reason = sink.prepare_dir(arg[2])
print(require('json').encode({ok=ok,reason=reason or ''}))
"""


class LoggerProbeExitTests(unittest.TestCase):
    """Keep native process outcomes, file identity and public admission together."""

    def test_actual_probe_allocation_exit(self):
        driver = Path(__file__).resolve().parents[2]
        mktemp = shutil.which("mktemp")
        self.assertIsNotNone(mktemp)
        for mode in ("healthy", "failed-file", "failed-link"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                logs = root / "logs"
                logs.mkdir()
                target = logs / "retained-target"
                target.write_bytes(b"Unrelated native bytes.\n")
                victim = logs / ".ergopti-log-probe-Existing123"
                if mode == "failed-link":
                    victim.symlink_to(target.name)
                else:
                    victim.write_bytes(b"Unrelated probe-shaped bytes.\n")
                before = victim.lstat()
                binary = root / "bin"
                binary.mkdir()
                executable = binary / "mktemp"
                script = "#!/bin/sh\n"
                if mode != "healthy":
                    # Only the logger allocation fails. A checked owner's own
                    # output-buffer allocations still use the actual mktemp.
                    script += (
                        "if [ \"$1\" = -- ]; then printf '%s\\n' "
                        + shlex.quote(str(victim))
                        + "; exit 73; fi\n"
                    )
                script += "exec " + shlex.quote(mktemp) + ' "$@"\n'
                executable.write_text(script, encoding="utf-8")
                executable.chmod(0o700)
                environment = dict(
                    os.environ,
                    PATH=str(binary) + os.pathsep + os.defpath,
                    HOME=str(root),
                    XDG_CONFIG_HOME=str(root),
                    XDG_STATE_HOME=str(root),
                    XDG_DATA_HOME=str(root),
                    XDG_CACHE_HOME=str(root),
                    XDG_RUNTIME_DIR=str(root),
                    TMPDIR=str(root / "unavailable-tmp"),
                )
                if mode != "healthy":
                    witness = subprocess.run(
                        [str(executable), "--", str(victim)],
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    self.assertEqual(witness.returncode, 73)
                    self.assertEqual(witness.stdout, str(victim) + "\n")
                probe = root / "probe.lua"
                probe.write_text(PROBE, encoding="utf-8")
                result = subprocess.run(
                    [RUNTIME, str(probe), str(driver), str(logs)],
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                receipt = json.loads(result.stdout)
                print(
                    "Native logger probe receipt: " + json.dumps(dict(mode=mode, **receipt)),
                    flush=True,
                )
                self.assertEqual(
                    receipt["ok"],
                    mode == "healthy",
                    "failed allocation cannot grant path ownership",
                )
                self.assertEqual(
                    victim.lstat().st_ino,
                    before.st_ino,
                    "an unrelated path must retain native identity",
                )
                self.assertEqual(target.read_bytes(), b"Unrelated native bytes.\n")
                if mode == "failed-link":
                    self.assertEqual(victim.readlink(), Path(target.name))
                else:
                    self.assertEqual(victim.read_bytes(), b"Unrelated probe-shaped bytes.\n")
                self.assertEqual(
                    sorted(p.name for p in logs.iterdir()),
                    sorted([victim.name, target.name]),
                    "only the acknowledged private probe and capture buffer may be retired",
                )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True)
    options, remaining = parser.parse_known_args()
    RUNTIME = str(Path(options.runtime).resolve())
    unittest.main(argv=[__file__, *remaining])
