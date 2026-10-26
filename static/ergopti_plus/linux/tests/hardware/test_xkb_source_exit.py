"""A failed native keymap acquisition must not publish its otherwise valid output."""

import argparse
import ctypes
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


PROBE = r"""
local root = arg[1]
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;'
  .. root .. '/../_shared/lua/?.lua;' .. root .. '/../_shared/lua/?/init.lua;' .. package.path
require('compat.utf8').install()
assert(require('ffi').os == 'Linux' and jit ~= nil)
local display = require('infra.display_server')
display._set_for_test('wayland', '')
local capture = require('adapters.xkb_capture')
local layout = require('adapters.keyboard_layout')
local loaded = layout.refresh()
local hit = layout.resolve('a')
print('XKB_SOURCE_RESULT ' .. require('json').encode({
  loaded = loaded, ready = layout.is_ready(), capture_ready = capture.is_ready(),
  source = layout.source() or '', keycode = hit and hit.keycode or -1,
  text = capture.is_ready() and capture.peek_text(30) or '',
}))
capture.clear()
"""


def native_keymap():
    """Serialize a real libxkbcommon map without consulting a display server."""
    lib = ctypes.CDLL("libxkbcommon.so.0")
    lib.xkb_context_new.argtypes = [ctypes.c_int]
    lib.xkb_context_new.restype = ctypes.c_void_p
    lib.xkb_keymap_new_from_string.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_int,
    ]
    lib.xkb_keymap_new_from_string.restype = ctypes.c_void_p
    lib.xkb_keymap_get_as_string.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.xkb_keymap_get_as_string.restype = ctypes.c_void_p
    lib.xkb_keymap_unref.argtypes = [ctypes.c_void_p]
    lib.xkb_context_unref.argtypes = [ctypes.c_void_p]
    libc = ctypes.CDLL(None)
    libc.free.argtypes = [ctypes.c_void_p]
    context = lib.xkb_context_new(0)
    assert context
    keymap = None
    serialized = None
    try:
        # Self-contained native input avoids requiring the host's XKB data package.
        # These are fixture coordinates, never a product layout or typing fallback.
        letters = dict(
            zip(
                "abcdefghijklmnopqrstuvwxyz",
                (
                    38,
                    56,
                    54,
                    40,
                    26,
                    41,
                    42,
                    43,
                    31,
                    44,
                    45,
                    46,
                    58,
                    57,
                    32,
                    33,
                    24,
                    27,
                    39,
                    28,
                    30,
                    55,
                    25,
                    53,
                    29,
                    52,
                ),
                strict=True,
            )
        )
        codes = ["<LFSH> = 50;"]
        symbols = ["key <LFSH> { [ Shift_L ] }; modifier_map Shift { <LFSH> };"]
        for index, (letter, code) in enumerate(letters.items()):
            name = f"L{index:02d}"
            codes.append(f"<{name}> = {code};")
            symbols.append(f'key <{name}> {{ type="TWO_LEVEL", [ {letter}, {letter.upper()} ] }};')
        for digit in range(10):
            codes.append(f"<D{digit}> = {10 + digit};")
            symbols.append(f"key <D{digit}> {{ [ {digit} ] }};")
        source = (
            "xkb_keymap { xkb_keycodes { minimum=8; maximum=255; "
            + " ".join(codes)
            + ' }; xkb_types { type "TWO_LEVEL" { modifiers=Shift; map[None]=Level1; map[Shift]=Level2; }; };'
            + " xkb_compatibility { interpret Shift_L+AnyOf(all) { action=SetMods(modifiers=Shift); }; };"
            + " xkb_symbols { "
            + " ".join(symbols)
            + " }; };"
        ).encode()

        keymap = lib.xkb_keymap_new_from_string(context, source, 1, 0)
        assert keymap, "the real native compiler must admit the unchanged US control"
        serialized = lib.xkb_keymap_get_as_string(keymap, 1)
        assert serialized
        return ctypes.string_at(serialized)
    finally:
        if serialized:
            libc.free(serialized)
        if keymap:
            lib.xkb_keymap_unref(keymap)
        lib.xkb_context_unref(context)


class KeymapSourceExitTests(unittest.TestCase):
    """Keep actual process status, native parsing and inverse publication together."""

    def test_actual_keymap_source_exit(self):
        driver = Path(__file__).resolve().parents[2]
        keymap = native_keymap()
        for route in ("wayland", "xwayland", "compile"):
            for exit_code in (0, 73):
                with (
                    self.subTest(route=route, exit_code=exit_code),
                    tempfile.TemporaryDirectory() as temporary,
                ):
                    root = Path(temporary)
                    binary = root / "bin"
                    binary.mkdir()
                    map_path = root / "valid.xkb"
                    map_path.write_bytes(keymap)
                    probe = root / "probe.lua"
                    probe.write_text(PROBE, encoding="utf-8")
                    output = "cat " + shlex.quote(str(map_path)) + "; exit " + str(exit_code)
                    xkbcli = binary / "xkbcli"
                    selector = "dump-keymap-wayland" if route == "wayland" else "compile-keymap"
                    xkbcli.write_text(
                        '#!/bin/sh\ncase "$1" in\n'
                        + selector
                        + ") "
                        + (output if route != "xwayland" else "exit 1")
                        + ";;\n*) exit 1;;\nesac\n",
                        encoding="utf-8",
                    )
                    (binary / "xkbcomp").write_text(
                        "#!/bin/sh\n" + (output if route == "xwayland" else "exit 1") + "\n",
                        encoding="utf-8",
                    )
                    # These private clients never contact a desktop or system bus.
                    for name in ("gsettings", "localectl"):
                        (binary / name).write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
                    for executable in binary.iterdir():
                        executable.chmod(0o700)
                    environment = dict(os.environ)
                    for name in (
                        "LUA_PATH",
                        "LUA_CPATH",
                        "DISPLAY",
                        "WAYLAND_DISPLAY",
                        "DBUS_SESSION_BUS_ADDRESS",
                        "XKB_DEFAULT_LAYOUT",
                        "XKB_DEFAULT_VARIANT",
                        "XKB_DEFAULT_OPTIONS",
                    ):
                        environment.pop(name, None)
                    environment.update(
                        PATH=str(binary) + os.pathsep + os.defpath,
                        HOME=str(root),
                        XDG_CONFIG_HOME=str(root),
                        XDG_DATA_HOME=str(root),
                        XDG_CACHE_HOME=str(root),
                        XDG_STATE_HOME=str(root),
                        XDG_RUNTIME_DIR=str(root),
                        XKB_DEFAULT_LAYOUT="us",
                    )
                    if route == "xwayland":
                        environment["DISPLAY"] = ":private-fixture"
                    command = (
                        [str(binary / "xkbcomp"), "-xkb", ":private-fixture", "-"]
                        if route == "xwayland"
                        else [str(xkbcli), selector]
                    )
                    witness = subprocess.run(
                        command, env=environment, capture_output=True, timeout=5
                    )
                    self.assertEqual(witness.returncode, exit_code)
                    self.assertEqual(
                        witness.stdout,
                        keymap,
                        "failure output must remain a complete genuinely compiled map",
                    )
                    result = subprocess.run(
                        [RUNTIME, str(probe), str(driver)],
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    lines = [
                        line.removeprefix("XKB_SOURCE_RESULT ")
                        for line in result.stdout.splitlines()
                        if line.startswith("XKB_SOURCE_RESULT ")
                    ]
                    self.assertEqual(len(lines), 1, result.stdout)
                    observation = json.loads(lines[0])
                    print(
                        "Native XKB source observation: "
                        + json.dumps(dict(route=route, exit_code=exit_code, **observation)),
                        flush=True,
                    )
                    self.assertEqual(
                        observation["loaded"],
                        exit_code == 0,
                        "failed acquisition must never publish valid-looking stdout",
                    )
                    self.assertEqual(observation["ready"], exit_code == 0)
                    self.assertEqual(observation["capture_ready"], exit_code == 0)
                    if exit_code == 0:
                        self.assertEqual(observation["keycode"], 30)
                        self.assertEqual(observation["text"], "a")
                        self.assertIn(
                            "xkbcomp" if route == "xwayland" else selector, observation["source"]
                        )
                    else:
                        self.assertEqual(observation["source"], "")
                        self.assertEqual(observation["keycode"], -1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True)
    options, remaining = parser.parse_known_args()
    RUNTIME = str(Path(options.runtime).resolve())
    unittest.main(argv=[__file__, *remaining])
