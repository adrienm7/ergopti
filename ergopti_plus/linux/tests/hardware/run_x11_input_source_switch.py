#!/usr/bin/env python3
"""Run the real switcher only against an owned, isolated Xvfb display."""

import os
from pathlib import Path
import selectors
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="ergopti-xkb-switch-") as temporary:
    read_fd, write_fd = os.pipe()
    server = subprocess.Popen(
        ["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "1024x768x24", "-nolisten", "tcp"],
        pass_fds=(write_fd,),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    os.close(write_fd)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(read_fd, selectors.EVENT_READ)
            assert selector.select(10), "private Xvfb failed to announce its display"
            display = os.read(read_fd, 32).decode("ascii").strip()
        assert display.isdigit(), "private Xvfb returned an invalid display"
        env = dict(os.environ, DISPLAY=":" + display, HOME=temporary, XDG_RUNTIME_DIR=temporary)
        # The worker is opened by literal script path. Exercise the actual
        # switcher with both Lua template delimiter bytes in that path too.
        for component in ("App;dir", "App?dir"):
            app = Path(temporary) / component
            driver = app / "linux"
            driver.mkdir(parents=True)
            for entry in root.iterdir():
                (driver / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
            (app / "_shared").symlink_to(root.parent / "_shared", target_is_directory=True)
            result = subprocess.run(
                ["luajit", "tests/hardware/run_x11_input_source_switch.lua"],
                cwd=driver,
                env=env,
                capture_output=True,
                text=True,
                timeout=20,
            )
            assert result.returncode == 0, (component, result.stdout, result.stderr)
            assert result.stdout.strip() == "real X11 input source group regression passed"
        print("real X11 input source group regression passed for both literal paths")
    finally:
        os.close(read_fd)
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)
        if server.stderr:
            server.stderr.close()
