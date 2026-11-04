"""Failed desktop metadata must not select a successful native keymap compilation."""

import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

from test_xkb_source_exit import PROBE, native_keymap


class SessionKeymapExitTests(unittest.TestCase):
    """Witness actual metadata status, compile argv and native publication."""

    def test_actual_session_metadata_exit(self):
        driver = Path(__file__).resolve().parents[2]
        keymap = native_keymap()
        for field in ("mru-sources", "sources", "xkb-options", "localectl"):
            for exit_code in (0, 73):
                with (
                    self.subTest(field=field, exit_code=exit_code),
                    tempfile.TemporaryDirectory() as temporary,
                ):
                    root = Path(temporary)
                    binary = root / "bin"
                    binary.mkdir()
                    data = root / "valid.xkb"
                    data.write_bytes(keymap)
                    commands = root / "compile-argv"
                    defaults = root / "keyboard"
                    defaults.write_text('XKBLAYOUT="us"\n', encoding="utf-8")
                    # Redirect only the two system-default reads to private files;
                    # all metadata processes and the native parser remain genuine.
                    private_reads = r"""
local native_open = io.open
io.open = function(path, mode)
  if path == '/etc/default/keyboard' then return native_open(arg[2], mode) end
  if path == '/etc/vconsole.conf' then return nil end
  return native_open(path, mode)
end
"""
                    probe = root / "probe.lua"
                    probe.write_text(private_reads + PROBE, encoding="utf-8")
                    answers = {"mru-sources": "[]", "sources": "[]", "xkb-options": "@as []"}
                    if field == "mru-sources":
                        answers.update(
                            {"mru-sources": "[('xkb', 'fr')]", "sources": "[('xkb', 'us')]"}
                        )
                    elif field == "sources":
                        answers["sources"] = "[('xkb', 'fr')]"
                    elif field == "xkb-options":
                        answers.update(
                            {"mru-sources": "[('xkb', 'fr')]", "xkb-options": "['caps:escape']"}
                        )
                    gsettings = binary / "gsettings"
                    script = '#!/bin/sh\ncase "$3" in\n'
                    for name, value in answers.items():
                        script += (
                            name
                            + ") printf '%s\\n' "
                            + shlex.quote(value)
                            + "; exit "
                            + str(exit_code if field == name else 0)
                            + ";;\n"
                        )
                    gsettings.write_text(script + "*) exit 1;;\nesac\n", encoding="utf-8")
                    localectl = binary / "localectl"
                    status = "   X11 Layout: fr\n" if field == "localectl" else ""
                    localectl.write_text(
                        "#!/bin/sh\nprintf '%s' "
                        + shlex.quote(status)
                        + "; exit "
                        + str(exit_code if field == "localectl" else 0)
                        + "\n",
                        encoding="utf-8",
                    )
                    xkbcli = binary / "xkbcli"
                    xkbcli.write_text(
                        '#!/bin/sh\n[ "$1" = compile-keymap ] || exit 1\n'
                        + "printf '%s\\n' \"$@\" > "
                        + shlex.quote(str(commands))
                        + "\ncat "
                        + shlex.quote(str(data))
                        + "\n",
                        encoding="utf-8",
                    )
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
                    )
                    if field != "localectl":
                        environment["XKB_DEFAULT_LAYOUT"] = "us"
                    witness_command = (
                        [str(localectl), "status"]
                        if field == "localectl"
                        else [str(gsettings), "get", "org.gnome.desktop.input-sources", field]
                    )
                    witness = subprocess.run(
                        witness_command, env=environment, capture_output=True, text=True, timeout=5
                    )
                    self.assertEqual(witness.returncode, exit_code)
                    self.assertEqual(
                        witness.stdout, status if field == "localectl" else answers[field] + "\n"
                    )
                    result = subprocess.run(
                        [RUNTIME, str(probe), str(driver), str(defaults)],
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
                    argv = commands.read_text().splitlines()
                    print(
                        "Native XKB metadata observation: "
                        + json.dumps(
                            dict(field=field, exit_code=exit_code, argv=argv, **observation)
                        ),
                        flush=True,
                    )
                    expected = ["compile-keymap", "--layout", "fr" if exit_code == 0 else "us"]
                    if field == "xkb-options" and exit_code == 0:
                        expected.extend(["--options", "caps:escape"])
                    self.assertEqual(
                        argv,
                        expected,
                        "failed session metadata must never enter compilation arguments",
                    )
                    self.assertTrue(
                        observation["loaded"]
                        and observation["ready"]
                        and observation["capture_ready"],
                        "the acknowledged source or independent healthy fallback must still publish",
                    )
                    self.assertEqual(observation["keycode"], 30)
                    self.assertEqual(observation["text"], "a")
                    self.assertIn("compile-keymap", observation["source"])
                    expected_source = (
                        "gnome"
                        if field == "mru-sources" or (field != "localectl" and exit_code == 0)
                        else "localectl"
                        if field == "localectl" and exit_code == 0
                        else "env"
                        if field != "localectl"
                        else "keyboard-defaults"
                    )
                    self.assertIn(expected_source, observation["source"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True)
    options, remaining = parser.parse_known_args()
    RUNTIME = str(Path(options.runtime).resolve())
    unittest.main(argv=[__file__, *remaining])
