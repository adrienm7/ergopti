#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_file_read_error_receipts.py
#
# Native files, Lua/libc streams and production read ports execute under strace.
# EIO is deliberately injected at the owned stream's read/close syscall: these
# are simulated syscall failure receipts, not genuine storage/hardware failures.

import os
import pathlib
import re
import subprocess
import tempfile


WORKER = r"""
local source = assert(os.getenv("ERGOPTI_READ_SOURCE"))
local read = os.getenv("ERGOPTI_READ_PORT") == "updater"
	and require("modules.updater.installer").DEFAULT_OPS.read
	or require("adapters.file_system").read
local bytes = read(source)
if os.getenv("ERGOPTI_READ_FAULT") then
	assert(bytes == nil, "a failed stream receipt published successful file contents")
else assert(type(bytes) == "string" and #bytes == 30000, "native byte control failed") end
"""


def run(interpreter, trace, env, injection=None):
    command = ["strace", "-qq", "-yy", "-s", "1", "-e", "trace=read,close"]
    if injection is not None:
        command += ["-e", injection]
    command += ["-o", str(trace), interpreter, "-e", WORKER]
    return subprocess.run(command, env=env, capture_output=True, text=True, timeout=5)


def main():
    interpreter = os.environ.get("ERGOPTI_FILE_READ_TEST_LUA", "luajit")
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-native-read-error-") as folder:
        root = pathlib.Path(folder)
        source = root / "source"
        source.write_bytes(b"R" * 30000)
        for port in ("filesystem", "updater"):
            env = dict(os.environ)
            env.update(
                ERGOPTI_READ_SOURCE=str(source),
                ERGOPTI_READ_PORT=port,
                XDG_CONFIG_HOME=str(root / "config"),
                LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
            )
            reference = root / (port + "-reference.trace")
            probe = run(interpreter, reference, env)
            checks += 1
            assert probe.returncode == 0, (probe.stdout + probe.stderr)[-1000:]
            counts, owned = {"read": 0, "close": 0}, {"read": [], "close": []}
            for line in reference.read_text().splitlines():
                operation = line.split("(", 1)[0]
                if operation in counts:
                    counts[operation] += 1
                    if "<" + str(source) + ">" in line:
                        owned[operation].append(counts[operation])
            assert owned["read"] and len(owned["close"]) == 2, (
                "native stream syscall ownership was not observed"
            )
            print(f"PASS native read receipt {port} healthy", flush=True)
            for operation, index in (("read", owned["read"][0]), ("close", owned["close"][-1])):
                checks += 1
                fault_env = dict(env)
                fault_env["ERGOPTI_READ_FAULT"] = operation
                trace = root / (port + "-" + operation + ".trace")
                result = run(
                    interpreter, trace, fault_env, f"inject={operation}:error=EIO:when={index}"
                )
                recorded = trace.read_text()
                target = re.escape("<" + str(source) + ">")
                injected = re.search(
                    r"^" + operation + r"\([^\n]*" + target + r"[^\n]*EIO[^\n]*INJECTED",
                    recorded,
                    re.MULTILINE,
                )
                try:
                    assert injected, "EIO injection did not reach the owned stream syscall"
                    assert result.returncode == 0, (result.stdout + result.stderr)[-1000:]
                    assert source.read_bytes() == b"R" * 30000, "failed read changed source bytes"
                    print(f"PASS native process {port} simulated {operation} EIO", flush=True)
                except AssertionError as error:
                    failures += 1
                    print(
                        f"FAIL native process {port} simulated {operation} EIO: {error}", flush=True
                    )
    print(
        f"Native process file-read receipts: {checks} checks, {failures} failures (EIO syscalls simulated)"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
