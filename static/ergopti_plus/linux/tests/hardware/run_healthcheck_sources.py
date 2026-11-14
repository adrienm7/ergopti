#!/usr/bin/env python3
"""Exercise healthcheck proc and device reads against real native inodes."""

import argparse
import os
from pathlib import Path
import socket
import subprocess
import tempfile

WORKER = r"""
require("core.lifecycle.engine.compat.utf8").install()
local target, endpoint, kind = os.getenv("HC_TARGET"), os.getenv("HC_SOURCE_PATH"), os.getenv("HC_KIND")
local regular = os.getenv("HC_REGULAR") == "1"
local old_open = io.open
io.open = function(path, mode) if path == target then return old_open(endpoint, mode) end return old_open(path, mode) end
local reader = require("core.fs.engine.regular_file_reader")
local old_source = reader.open_source
reader.open_source = function(path) return old_source(path == target and endpoint or path) end
local bridge = require("ui.healthcheck.bridge")
if kind == "snapshot" then
    local snapshot = bridge.build_snapshot({}, false, false)
    assert(type(snapshot) == "table" and type(snapshot.sections) == "table", "snapshot must complete")
    if regular and target == "/sys/class/dmi/id/sys_vendor" then
        assert(snapshot.sections.hardware.model:find("FixtureVendor", 1, true), "vendor must be read")
    end
    if regular and target == "/sys/class/dmi/id/product_name" then
        assert(snapshot.sections.hardware.model:find("FixtureProduct", 1, true), "product must be read")
    end
    if regular and target == "/proc/self/status" then
        assert(snapshot.sections.system.process_memory == 123 * 1024, "status must be read")
    end
elseif kind == "cpu" then
    local schema = bridge.config().schema
    package.loaded["core.events.timer_scheduler"] = { HAS_ASYNC = true,
        after = function() return { armed = true } end, cancel = function() return true end }
    package.loaded["core.network.adapters.http_client"] = { HAS_ASYNC = false }
    package.loaded["adapters.shell_runner"] = { HAS_ASYNC = false, has_command = function() return false end }
    local results = {}
    local run = require("ui.healthcheck.probes").start(schema, {}, {}, function(id, result) results[id] = result end)
    if regular then assert(results.cpu_load == nil, "valid first sample must wait for the timer")
    else assert(results.cpu_load and results.cpu_load.state == "error", "special source must fail closed") end
    run.cancel()
else
    local state = bridge._device_access_for_test(endpoint)
    local expected = os.getenv("HC_CHAR") == "1" and "granted" or "unknown"
    assert(state == expected, "input node admission: " .. tostring(state))
end
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--driver", type=Path, required=True)
    args = parser.parse_args()
    records = {
        "/sys/class/dmi/id/sys_vendor": ("snapshot", b"FixtureVendor\n"),
        "/sys/class/dmi/id/product_name": ("snapshot", b"FixtureProduct\n"),
        "/proc/self/status": ("snapshot", b"Name:\tlua\nVmRSS:\t123 kB\nUid:\t1000\t1000\n"),
        "/proc/bus/input/devices": (
            "snapshot",
            b"I: Bus=0003 Vendor=0001 Product=0002\nH: Handlers=kbd event42\n",
        ),
        "/proc/stat": ("cpu", b"cpu  1000 0 500 8000 500 0 0 0 0 0\n"),
        "/proc/self/stat": (
            "cpu",
            b"4242 (lua) S 1 4242 4242 0 -1 4194304 1000 0 0 0 100 50 0 0 20 0 3 0 12345\n",
        ),
        "device": ("device", b"ordinary file"),
    }
    total = 0
    with tempfile.TemporaryDirectory(prefix="ergopti-health-sources-") as root_text:
        root = Path(root_text)
        for index, (target, (kind, payload)) in enumerate(records.items()):
            shapes = (
                "regular",
                "file-link",
                "fifo",
                "fifo-peer",
                "fifo-link",
                "directory",
                "socket",
            )
            if kind == "device":
                shapes += ("char-link",)
            for shape in shapes:
                case = root / (str(index) + "-" + shape)
                case.mkdir()
                endpoint = case / "source"
                peer, sock = None, None
                if shape in ("regular", "file-link"):
                    actual = case / "regular-target" if shape == "file-link" else endpoint
                    actual.write_bytes(payload)
                    if shape == "file-link":
                        endpoint.symlink_to(actual)
                elif shape.startswith("fifo"):
                    actual = case / "pipe" if shape == "fifo-link" else endpoint
                    os.mkfifo(actual)
                    if shape == "fifo-link":
                        endpoint.symlink_to(actual)
                    if shape == "fifo-peer":
                        peer = os.open(actual, os.O_RDWR | os.O_NONBLOCK)
                        os.write(peer, b"do-not-consume")
                elif shape == "directory":
                    endpoint.mkdir()
                elif shape == "char-link":
                    endpoint.symlink_to("/dev/null")
                else:
                    sock = socket.socket(socket.AF_UNIX)
                    sock.bind(str(endpoint))
                before = endpoint.lstat()
                env = dict(
                    os.environ,
                    HC_TARGET=target,
                    HC_SOURCE_PATH=str(endpoint),
                    HC_KIND=kind,
                    HC_REGULAR="1" if shape in ("regular", "file-link") else "0",
                    HC_CHAR="1" if shape == "char-link" else "0",
                    XDG_CONFIG_HOME=str(root / "config"),
                    LUA_PATH="./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;",
                )
                try:
                    result = subprocess.run(
                        [args.runtime, "-e", WORKER],
                        cwd=args.driver,
                        env=env,
                        capture_output=True,
                        text=True,
                        timeout=3,
                        check=False,
                    )
                    assert result.returncode == 0, (
                        target,
                        shape,
                        result.stdout[-1200:],
                        result.stderr[-1200:],
                    )
                    after = endpoint.lstat()
                    assert (before.st_dev, before.st_ino, before.st_mode) == (
                        after.st_dev,
                        after.st_ino,
                        after.st_mode,
                    )
                    if peer is not None:
                        assert os.read(peer, 64) == b"do-not-consume"
                    total += 1
                finally:
                    if peer is not None:
                        os.close(peer)
                    if sock is not None:
                        sock.close()
    print(f"Healthcheck source admission: {total} real inode cases passed")


if __name__ == "__main__":
    main()
