# tests/hardware/run_caps_word_real.py

"""Owned Xvfb and genuine kernel CapsWord receipts; no simulated native backend."""

import os
import sys
import pathlib
import select
import subprocess
import tempfile
from native_fixture_family import run

ROOT = pathlib.Path(__file__).resolve().parents[2]


def main():
    if not pathlib.Path("/dev/uinput").exists() or not pathlib.Path("/dev/input").is_dir():
        raise RuntimeError("ENVIRONMENT: genuine uinput/input prerequisites are absent")
    with tempfile.TemporaryDirectory(prefix="ergopti-caps-word-display-") as namespace:
        reader, writer = os.pipe()
        server = None
        try:
            with open(pathlib.Path(namespace) / "xvfb.log", "wb") as log:
                server = subprocess.Popen(
                    ["Xvfb", "-displayfd", str(writer), "-screen", "0", "800x600x24", "-ac"],
                    pass_fds=(writer,),
                    stdout=log,
                    stderr=log,
                )
                os.close(writer)
                writer = None
                if not select.select([reader], [], [], 5)[0]:
                    raise RuntimeError("ENVIRONMENT: owned Xvfb display receipt refused")
                display = os.read(reader, 32).decode("ascii").strip()
                if not display.isdecimal():
                    raise RuntimeError("ENVIRONMENT: owned Xvfb display identity refused")
                env = dict(
                    os.environ,
                    DISPLAY=":" + display,
                    LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                )
                result = run(
                    ["luajit", "tests/hardware/run_caps_word_real.lua", namespace],
                    cwd=ROOT,
                    env=env,
                    timeout=40,
                )
                if result.stdout:
                    print(result.stdout, end="", flush=True)
                if result.stderr:
                    print(result.stderr, end="", file=sys.stderr, flush=True)
                if result.returncode != 0:
                    raise RuntimeError("genuine CapsWord native owner qualification failed")
        finally:
            os.close(reader)
            if writer is not None:
                os.close(writer)
            if server is not None and server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=3)


if __name__ == "__main__":
    main()
