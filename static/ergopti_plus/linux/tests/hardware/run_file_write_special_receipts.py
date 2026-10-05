#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_file_write_special_receipts.py
#
# Real filesystem endpoints exercise the production write/append ports under a
# child watchdog. The rename hook simulates a competing path edit at stream-open
# time; descriptor opens, metadata, byte writes and FIFO endpoints remain native.

import os
import pathlib
import resource
import signal
import socket
import subprocess
import tempfile


WORKER = r"""
local source = assert(os.getenv("ERGOPTI_WRITE_SOURCE"))
local method = assert(os.getenv("ERGOPTI_WRITE_METHOD"))
local kind = assert(os.getenv("ERGOPTI_WRITE_KIND"))
local backend = assert(os.getenv("ERGOPTI_WRITE_BACKEND"))
local observer = require("luv")
local function descriptor_count()
	local entries, count = assert(observer.fs_scandir("/proc/self/fd")), 0
	while observer.fs_scandir_next(entries) do count = count + 1 end
	return count
end
local descriptors_before = descriptor_count()
if backend == "ffi" then package.loaded.luv = {} else assert(require("luv")) end
local FileSystem = require("adapters.file_system")
if kind == "metadata-refusal" then
	if backend == "luv" then
		local uv = require("luv")
		package.loaded.luv = {
			fs_open = uv.fs_open, fs_close = uv.fs_close,
			fs_fstat = function() return nil, "simulated native metadata refusal", "EACCES" end,
		}
	else
		local ffi = require("ffi")
		ffi.cdef([[int ergopti_write_open(const char *path, int flags, ...) __asm__("open");
			int close(int fd);]])
		package.loaded.ffi = setmetatable({ C = {
			ergopti_write_open = ffi.C.ergopti_write_open, close = ffi.C.close,
			statx = function() return -1 end,
		} }, { __index = ffi })
	end
	assert(FileSystem[method](source, "replacement") == false, "unproven metadata was accepted")
elseif kind == "limit-buffered" or kind == "limit-immediate" then
	local mode = method == "write" and "w" or "a"
	local payload = string.rep("x", kind == "limit-buffered" and 32 or 65536)
	local control = assert(io.open(source .. ".control", mode))
	local written = control:write(payload)
	local closed = control:close()
	if kind == "limit-buffered" then
		assert(written and not closed, "regular fixture must fail at buffered flush")
	else
		assert(not written, "regular fixture must fail in the native write")
	end
	assert(FileSystem[method](source, payload) == false, "native EFBIG was reported as success")
elseif kind == "retarget" then
	local original_open = io.open
	local swapped = false
	io.open = function(path, mode)
		if not swapped and (mode == "w" or mode == "a") then
			swapped = true
			assert(os.rename(source, source .. ".owned"))
			assert(os.rename(source .. ".fifo", source))
		end
		return original_open(path, mode)
	end
	local result = FileSystem[method](source, "new\0bytes\r\n")
	io.open = original_open
	assert(swapped, "the controlled path-edit boundary did not execute")
	assert(result == true, "the pinned regular destination was lost")
else
	local result = FileSystem[method](source, "new\0bytes\r\n")
	local accepted = kind == "regular" or kind == "regular-link" or kind == "create"
	assert(result == accepted, "unexpected write receipt: " .. tostring(result))
end
assert(descriptor_count() == descriptors_before, "write admission retained an owned descriptor")
"""


def main():
    interpreter = os.environ.get("ERGOPTI_FILE_WRITE_TEST_LUA", "luajit")
    backend = os.environ.get("ERGOPTI_WRITE_BACKEND", "ffi")
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-native-file-write-") as folder:
        base = pathlib.Path(folder)
        for kind in (
            "regular",
            "regular-link",
            "create",
            "fifo",
            "fifo-link",
            "fifo-with-peer",
            "directory",
            "socket",
            "retarget",
            "limit-buffered",
            "limit-immediate",
            "metadata-refusal",
        ):
            for method in ("write", "append"):
                root = base / str(checks)
                root.mkdir()
                source, endpoint = root / "source", root / "endpoint"
                original = b"old\xc3\xa9\r\n"
                replacement = b"new\0bytes\r\n"
                peer, listener = None, None
                if kind in (
                    "regular",
                    "retarget",
                    "limit-buffered",
                    "limit-immediate",
                    "metadata-refusal",
                ):
                    source.write_bytes(original)
                    source.chmod(0o640)
                elif kind == "regular-link":
                    endpoint.write_bytes(original)
                    endpoint.chmod(0o640)
                    source.symlink_to(endpoint)
                elif kind in ("fifo", "fifo-with-peer"):
                    os.mkfifo(source)
                    if kind == "fifo-with-peer":
                        peer = os.open(source, os.O_RDWR | os.O_NONBLOCK)
                elif kind == "fifo-link":
                    os.mkfifo(endpoint)
                    source.symlink_to(endpoint)
                elif kind == "directory":
                    source.mkdir()
                elif kind == "socket":
                    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    listener.bind(str(source))
                if kind == "retarget":
                    os.mkfifo(str(source) + ".fifo", 0o600)
                before = None if kind == "create" else source.lstat()
                env = dict(os.environ)
                env.update(
                    XDG_CONFIG_HOME=str(root / "config"),
                    LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                    ERGOPTI_WRITE_SOURCE=str(source),
                    ERGOPTI_WRITE_METHOD=method,
                    ERGOPTI_WRITE_KIND=kind,
                    ERGOPTI_WRITE_BACKEND=backend,
                )
                checks += 1
                try:

                    def constrain_file_size():
                        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
                        resource.setrlimit(resource.RLIMIT_FSIZE, (16, 16))

                    child = subprocess.run(
                        [interpreter, "-e", WORKER],
                        env=env,
                        capture_output=True,
                        text=True,
                        timeout=2,
                        umask=0o027,
                        preexec_fn=constrain_file_size if kind.startswith("limit-") else None,
                    )
                    assert child.returncode == 0, (child.stdout + child.stderr)[-1000:]
                    if kind in ("regular", "regular-link", "create", "retarget"):
                        written = source.with_name("source.owned") if kind == "retarget" else source
                        expected = (
                            replacement
                            if method == "write" or kind == "create"
                            else original + replacement
                        )
                        assert written.read_bytes() == expected, "regular file bytes changed"
                        assert written.stat().st_mode & 0o777 == 0o640, "mode/umask changed"
                    if before is not None and kind != "retarget":
                        after = source.lstat()
                        assert (after.st_ino, after.st_mode) == (before.st_ino, before.st_mode)
                    if kind == "fifo-with-peer":
                        try:
                            leaked = os.read(peer, 100)
                        except BlockingIOError:
                            leaked = b""
                        assert leaked == b"", "rejected FIFO received payload bytes"
                    if kind.startswith("limit-"):
                        assert source.stat().st_size == 16, (
                            "native partial-write boundary was not reached"
                        )
                    if kind == "metadata-refusal":
                        assert source.read_bytes() == original, (
                            "classification failure truncated the source"
                        )
                    evidence = "native"
                    if kind == "retarget":
                        evidence = "SIMULATED path-edit timing over native files"
                    elif kind == "metadata-refusal":
                        evidence = "SIMULATED metadata refusal over native descriptors"
                    print(f"PASS {evidence} file {method} {kind}", flush=True)
                except (AssertionError, subprocess.TimeoutExpired) as error:
                    failures += 1
                    detail = (
                        "child exceeded the 2-second watchdog"
                        if isinstance(error, subprocess.TimeoutExpired)
                        else str(error)
                    )
                    print(f"FAIL native file {method} {kind}: {detail}", flush=True)
                finally:
                    if peer is not None:
                        os.close(peer)
                    if listener is not None:
                        listener.close()
    assert checks == 24
    print(f"Native special file write receipts ({backend}): {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
