"""Native capture needs both its default include directory and Compose data."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_xkb_source_exit import native_keymap


PROBE = r"""
local root, path = arg[1], arg[2]
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;'
  .. root .. '/../_shared/lua/?.lua;' .. root .. '/../_shared/lua/?/init.lua;' .. package.path
assert(require('ffi').os == 'Linux' and jit ~= nil)
local file = assert(io.open(path))
local text = file:read('*a')
assert(file:close())
local capture = require('adapters.xkb_capture')
local ok, reason = capture.load(text, 'C.UTF-8')
print(require('json').encode({ok=ok,reason=reason or '',ready=capture.is_ready()}))
capture.clear()
"""


class NativeXkbDataTests(unittest.TestCase):
    """Vary only native search-path inputs; retain real constructors and flags."""

    def test_capture_data_admission(self):
        driver = Path(__file__).resolve().parents[2]
        data = native_keymap()
        for mode, expected in (
            ("missing-xkb", "xkb_context_new failed"),
            ("missing-compose", "no Compose table for locale C.UTF-8"),
            ("present", ""),
        ):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                keymap = root / "valid.xkb"
                keymap.write_bytes(data)
                probe = root / "probe.lua"
                probe.write_text(PROBE, encoding="utf-8")
                environment = dict(os.environ)
                for name in (
                    "LUA_PATH",
                    "LUA_CPATH",
                    "XKB_CONFIG_ROOT",
                    "XLOCALEDIR",
                    "XCOMPOSEFILE",
                    "DISPLAY",
                    "WAYLAND_DISPLAY",
                    "DBUS_SESSION_BUS_ADDRESS",
                ):
                    environment.pop(name, None)
                environment.update(
                    HOME=str(root),
                    XDG_CONFIG_HOME=str(root),
                    XKB_CONFIG_EXTRA_PATH=str(root / "absent-extra"),
                )
                if mode == "missing-xkb":
                    environment["XKB_CONFIG_ROOT"] = str(root / "absent-xkb")
                elif mode == "missing-compose":
                    environment["XLOCALEDIR"] = str(root / "absent-compose")
                result = subprocess.run(
                    [RUNTIME, str(probe), str(driver), str(keymap)],
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                observation = json.loads(result.stdout)
                print(
                    "Native XKB data admission: " + json.dumps(dict(mode=mode, **observation)),
                    flush=True,
                )
                self.assertEqual(observation["ok"], mode == "present")
                self.assertEqual(observation["ready"], mode == "present")
                self.assertEqual(observation["reason"], expected)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True)
    options, remaining = parser.parse_known_args()
    RUNTIME = str(Path(options.runtime).resolve())
    unittest.main(argv=[__file__, *remaining])
