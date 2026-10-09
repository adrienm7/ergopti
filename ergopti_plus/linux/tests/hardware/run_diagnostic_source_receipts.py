#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_diagnostic_source_receipts.py
#
# Production diagnostic readers inspect real files, FIFOs and UNIX sockets.
# No filesystem adapter or syscall is simulated. Healthy /proc and /etc probes
# remain controls alongside build-stamp and git-metadata admission.

import os
import pathlib
import socket
import subprocess
import tempfile

WORKER = r"""
local Collector = require("infra.diagnostic_snapshot")
if os.getenv("ERGOPTI_DIAGNOSTIC_CONTROL") == "pid" then
    assert(tonumber(Collector.pid()) and tonumber(Collector.pid()) > 0, "native /proc pid missing")
elseif os.getenv("ERGOPTI_DIAGNOSTIC_CONTROL") == "facts" then
    local facts = Collector.system_facts()
    assert(type(facts.os_name) == "string" and facts.os_name ~= "", "native /etc OS name missing")
    assert(type(facts.kernel) == "string" and facts.kernel ~= "", "native /proc kernel missing")
    assert(type(facts.ram_total) == "number" and facts.ram_total > 0, "native /proc memory missing")
else
    local commit, source = Collector.resolve_commit({ shared_root = assert(os.getenv("ERGOPTI_DIAGNOSTIC_SHARED")), source_dir = assert(os.getenv("ERGOPTI_DIAGNOSTIC_SOURCE")) })
    assert(commit == os.getenv("ERGOPTI_DIAGNOSTIC_COMMIT"), "unexpected native commit: " .. tostring(commit))
    assert(source == os.getenv("ERGOPTI_DIAGNOSTIC_ORIGIN"), "unexpected native commit source: " .. tostring(source))
end
"""


def main():
    interpreter = os.environ.get("ERGOPTI_DIAGNOSTIC_TEST_LUA", "luajit")
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-native-diag-") as folder:
        root = pathlib.Path(folder)
        for port in ("stamp", "head", "pointer"):
            for kind in (
                "regular",
                "file-link",
                "fifo",
                "fifo-link",
                "fifo-peer",
                "directory",
                "socket",
                "missing",
            ):
                checks += 1
                case = root / (port + "-" + kind)
                shared, source = case / "shared", case / "source"
                shared.mkdir(parents=True)
                source.mkdir()
                endpoint = shared / "build_stamp.txt" if port == "stamp" else source / ".git"
                sha = "123456789" + "0" * 31
                content = ("commit=" + sha + "\n").encode()
                if port == "head":
                    endpoint.mkdir()
                    endpoint /= "HEAD"
                    content = (sha + "\n").encode()
                elif port == "pointer":
                    metadata = case / "metadata"
                    metadata.mkdir()
                    (metadata / "HEAD").write_text(sha + "\n")
                    content = ("gitdir: " + str(metadata) + "\n").encode()
                peer, owner = None, None
                expected, origin = "unknown", "unknown"
                if kind in ("regular", "file-link"):
                    actual = case / "target" if kind == "file-link" else endpoint
                    actual.write_bytes(content)
                    if kind == "file-link":
                        endpoint.symlink_to(actual)
                    expected, origin = sha[:9], "build" if port == "stamp" else "git"
                elif kind.startswith("fifo"):
                    actual = case / "pipe" if kind == "fifo-link" else endpoint
                    os.mkfifo(actual)
                    if kind == "fifo-link":
                        endpoint.symlink_to(actual)
                    if kind == "fifo-peer":
                        peer = os.open(actual, os.O_RDWR | os.O_NONBLOCK)
                        os.write(peer, content)
                elif kind == "directory":
                    endpoint.mkdir()
                elif kind == "socket":
                    owner = socket.socket(socket.AF_UNIX)
                    owner.bind(str(endpoint))
                before = endpoint.lstat() if endpoint.exists() else None
                env = dict(os.environ)
                env.update(
                    ERGOPTI_DIAGNOSTIC_SHARED=str(shared),
                    ERGOPTI_DIAGNOSTIC_SOURCE=str(source),
                    ERGOPTI_DIAGNOSTIC_COMMIT=expected,
                    ERGOPTI_DIAGNOSTIC_ORIGIN=origin,
                    XDG_CONFIG_HOME=str(root / "config"),
                    LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                )
                try:
                    result = subprocess.run(
                        [interpreter, "-e", WORKER],
                        env=env,
                        capture_output=True,
                        text=True,
                        timeout=1,
                    )
                    assert result.returncode == 0, (result.stdout + result.stderr)[-1000:]
                    if before:
                        after = endpoint.lstat()
                        assert (after.st_dev, after.st_ino, after.st_mode) == (
                            before.st_dev,
                            before.st_ino,
                            before.st_mode,
                        ), "diagnostics changed source metadata"
                    else:
                        assert not endpoint.exists(), "diagnostics created missing metadata"
                    if kind in ("regular", "file-link"):
                        assert endpoint.read_bytes() == content, "diagnostics changed source bytes"
                    print(f"PASS native diagnostic {port} {kind}", flush=True)
                except (AssertionError, subprocess.TimeoutExpired) as error:
                    failures += 1
                    print(f"FAIL native diagnostic {port} {kind}: {error}", flush=True)
                finally:
                    if peer is not None:
                        os.close(peer)
                    if owner is not None:
                        owner.close()
        for control in ("pid", "facts"):
            checks += 1
            env.update(ERGOPTI_DIAGNOSTIC_CONTROL=control)
            result = subprocess.run(
                [interpreter, "-e", WORKER], env=env, capture_output=True, text=True, timeout=5
            )
            if result.returncode:
                failures += 1
                print(
                    f"FAIL native diagnostic {control}: " + (result.stdout + result.stderr)[-1000:],
                    flush=True,
                )
            else:
                print(f"PASS native diagnostic {control}", flush=True)
    print(f"Native diagnostic sources: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
