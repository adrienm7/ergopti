#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/test_startup_desktop.py
#
# Exercise the platform desktop-entry parser and launch only an inert executable
# in a private temporary directory. Quoting must preserve both decoding layers.

from pathlib import Path
import subprocess
import tempfile
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio  # noqa: E402


def main():
    root = Path(__file__).resolve().parents[2]
    helper = root / "install/desktop_entry.sh"
    with tempfile.TemporaryDirectory(prefix="ergopti-desktop-") as temporary:
        folder = Path(temporary)
        executable = folder / 'a space $cash `tick` "quote" \\slash %percent'
        result = folder / "result"
        executable.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ERGOPTI_DESKTOP_RESULT"\n')
        executable.chmod(0o700)
        encoded = subprocess.check_output(
            [
                "/bin/bash",
                "-c",
                'source "$1"; ergopti_desktop_exec "$2"',
                "desktop-test",
                str(helper),
                str(executable),
            ],
            text=True,
        )
        desktop = folder / "ergopti.desktop"
        desktop.write_text("[Desktop Entry]\nType=Application\nName=Fixture\n" + encoded)
        app = Gio.DesktopAppInfo.new_from_filename(str(desktop))
        assert app is not None, "the native desktop parser rejected the entry"
        context = Gio.AppLaunchContext()
        context.setenv("ERGOPTI_DESKTOP_RESULT", str(result))
        assert app.launch([], context), "the native launcher rejected the entry"
        deadline = time.monotonic() + 5
        while not result.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert result.read_text() == "--session-start\n--tray\n"
        assert not (folder / "cash").exists()
        print("PASS native desktop parser preserves startup executable and arguments")


if __name__ == "__main__":
    main()
