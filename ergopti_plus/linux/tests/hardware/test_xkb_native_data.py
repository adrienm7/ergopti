"""Native capture proves include ownership and library-defined missing-data behavior."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_xkb_source_exit import native_keycodes, native_keymap


# The serialized control deliberately has no includes. This input must retain
# its real xkeyboard-config dependencies so missing data reaches the compiler.
INCLUDE_DEPENDENT_KEYMAP = b"""
xkb_keymap {
    xkb_keycodes { include "OWNED_KEYCODES+aliases(qwerty)" };
    xkb_types { include "complete" };
    xkb_compatibility { include "complete" };
    xkb_symbols { include "pc+us+inet(evdev)" };
};
"""


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
local ffi = require('ffi')
ffi.cdef[[
unsigned int xkb_context_num_include_paths(struct xkb_context *context);
const char *xkb_context_include_path_get(struct xkb_context *context, unsigned int index);
]]
local lib = ffi.load(require('_generated.native_runtime').xkbcommon)
local context = assert(lib.xkb_context_new(0))
local paths = {}
for index = 0, tonumber(lib.xkb_context_num_include_paths(context)) - 1 do
  paths[#paths + 1] = ffi.string(lib.xkb_context_include_path_get(context, index))
end
lib.xkb_context_unref(context)
print(require('json').encode({
  ok=ok,reason=reason or '',ready=capture.is_ready(),
  text=capture.is_ready() and capture.peek_text(30) or '',include_paths=paths,
}))
capture.clear()
"""


ISOLATED_PROBE = r"""
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

CONTEXT_PROBE = r"""
local root = arg[1]
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;'
  .. root .. '/../_shared/lua/?.lua;' .. root .. '/../_shared/lua/?/init.lua;' .. package.path
local ffi = require('ffi')
ffi.cdef[[
  struct xkb_context;
  struct xkb_context *xkb_context_new(int flags);
  unsigned int xkb_context_num_include_paths(struct xkb_context *context);
  void xkb_context_unref(struct xkb_context *context);
]]
local lib = ffi.load(require('_generated.native_runtime').xkbcommon)
local context = lib.xkb_context_new(0)
local paths = -1
if context ~= nil then
  paths = tonumber(lib.xkb_context_num_include_paths(context))
  lib.xkb_context_unref(context)
end
print(require('json').encode({context = context ~= nil, include_paths = paths}))
"""


class NativeXkbDataTests(unittest.TestCase):
    """Vary real include-file and Compose inputs with unchanged native flags."""

    def test_capture_data_admission(self):
        driver = Path(__file__).resolve().parents[2]
        self_contained = native_keymap()
        keycodes = native_keycodes()
        for mode, accepted, expected in (
            ("missing-include", False, "xkb_keymap_new_from_string rejected the active keymap"),
            ("missing-compose", False, "no Compose table for locale C.UTF-8"),
            ("present", True, ""),
            ("self-contained", True, ""),
        ):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                # A unique genuine include cannot resolve through a library's
                # compiled system defaults. Only its presence changes on repair.
                extra = root / "extra"
                (extra / "keycodes").mkdir(parents=True)
                name = "ergopti-native-" + root.name
                required = extra / "keycodes" / name
                if mode in ("present", "missing-compose"):
                    required.write_bytes(keycodes)
                else:
                    self.assertFalse(required.exists())
                keymap = root / "valid.xkb"
                keymap.write_bytes(
                    self_contained
                    if mode == "self-contained"
                    else INCLUDE_DEPENDENT_KEYMAP.replace(b"OWNED_KEYCODES", name.encode("ascii"))
                )
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
                    XKB_CONFIG_EXTRA_PATH=str(extra),
                )
                if mode == "missing-compose":
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
                self.assertEqual(observation["ok"], accepted)
                self.assertEqual(observation["ready"], accepted)
                self.assertEqual(observation["reason"], expected)
                self.assertEqual(observation["text"], "a" if accepted else "")
                self.assertIn(str(extra), observation["include_paths"])
                if mode == "missing-include":
                    required.write_bytes(keycodes)
                    restored = subprocess.run(
                        result.args, env=environment, capture_output=True, text=True, timeout=10
                    )
                    self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
                    repaired = json.loads(restored.stdout)
                    print("Native XKB include restored: " + json.dumps(repaired), flush=True)
                    self.assertTrue(repaired["ok"])
                    self.assertTrue(repaired["ready"])
                    self.assertEqual(repaired["reason"], "")
                    self.assertEqual(repaired["text"], "a")
                    self.assertEqual(repaired["include_paths"], observation["include_paths"])

    def test_capture_without_default_xkb_data(self):
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
                probe.write_text(ISOLATED_PROBE, encoding="utf-8")
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
                    # An empty root, not an absent one: libxkbcommon 1.11 falls
                    # back to the legacy /usr/share/X11/xkb when the root it was
                    # given is missing, and skips that only for an empty root.
                    # The extension directories it also scans are moved away.
                    environment["XKB_CONFIG_ROOT"] = ""
                    environment["XKB_CONFIG_VERSIONED_EXTENSIONS_PATH"] = str(
                        root / "absent-versioned"
                    )
                    environment["XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH"] = str(
                        root / "absent-unversioned"
                    )
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
                admitted = mode == "present"
                if mode == "missing-xkb":
                    context_probe = root / "context.lua"
                    context_probe.write_text(CONTEXT_PROBE, encoding="utf-8")
                    native = subprocess.run(
                        [RUNTIME, str(context_probe), str(driver)],
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                    self.assertEqual(native.returncode, 0, native.stdout + native.stderr)
                    library = json.loads(native.stdout)
                    observation["library"] = library
                    if library["context"]:
                        # A lazy-include library: the data really is out of
                        # reach (no include path at all), and the complete
                        # keymap must still be captured from its own text.
                        self.assertEqual(
                            library["include_paths"], 0, "the XKB data must be unreachable"
                        )
                        admitted, expected = True, ""
                print(
                    "Native XKB data admission: " + json.dumps(dict(mode=mode, **observation)),
                    flush=True,
                )
                self.assertEqual(observation["ok"], admitted)
                self.assertEqual(observation["ready"], admitted)
                self.assertEqual(observation["reason"], expected)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True)
    options, remaining = parser.parse_known_args()
    RUNTIME = str(Path(options.runtime).resolve())
    unittest.main(argv=[__file__, *remaining])
