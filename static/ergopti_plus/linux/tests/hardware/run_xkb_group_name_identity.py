#!/usr/bin/env python3
"""Load a layout with a non-ASCII group name into an owned Xvfb and check the
daemon still types with keys (run_xkb_group_name_identity.lua)."""

import os
from pathlib import Path
import selectors
import subprocess
import tempfile

SYMBOLS = """default partial alphanumeric_keys
xkb_symbols "basic" {
	include "us(basic)"
	name[Group1] = "Français — bépo";
};
"""

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="ergopti-xkb-name-") as temporary:
    tree = Path(temporary) / "xkb"
    (tree / "symbols").mkdir(parents=True)
    (tree / "symbols" / "zzname").write_text(SYMBOLS, encoding="utf-8")
    read_fd, write_fd = os.pipe()
    # -noreset: the server keeps the uploaded keymap after its one-shot client.
    server = subprocess.Popen(
        [
            "Xvfb",
            "-displayfd",
            str(write_fd),
            "-noreset",
            "-screen",
            "0",
            "640x480x24",
            "-nolisten",
            "tcp",
        ],
        pass_fds=(write_fd,),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    os.close(write_fd)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(read_fd, selectors.EVENT_READ)
            assert selector.select(10), "private Xvfb failed to announce its display"
            display = os.read(read_fd, 32).decode("ascii").strip()
        assert display.isdigit(), "private Xvfb returned an invalid display"
        env = dict(
            os.environ,
            DISPLAY=":" + display,
            HOME=temporary,
            XDG_RUNTIME_DIR=temporary,
            XDG_SESSION_TYPE="x11",
        )
        env.pop("WAYLAND_DISPLAY", None)
        printed = subprocess.run(
            ["setxkbmap", "-I" + str(tree), "-layout", "zzname", "-print"],
            env=env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        subprocess.run(
            ["xkbcomp", "-w0", "-I" + str(tree), "-", ":" + display],
            input=printed,
            env=env,
            check=True,
            text=True,
        )
        result = subprocess.run(
            ["luajit", "tests/hardware/run_xkb_group_name_identity.lua"],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode == 0, (result.stdout[-4000:], result.stderr[-4000:])
        print(result.stdout.strip().splitlines()[-1])
    finally:
        os.close(read_fd)
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)
