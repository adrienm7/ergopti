#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_storage_temp_receipts.py
#
# Production JSON storage must not truncate, replace or unlink a temporary path
# it did not create. Actual symlinks, hardlinks, FIFOs and permissions exercise
# the exclusive-open boundary. Kernel RLIMIT_FSIZE generates real buffered and
# partial-write failures, with no file/process adapter mocks. TOML is untouched.

import os
import pathlib
import resource
import signal
import stat
import subprocess
import tempfile
import tomllib

# The application folder under every XDG base, read from the one declaration.
APP_DIRS = pathlib.Path(__file__).resolve().parents[3] / "_shared/modules/paths/app_dirs.toml"
FOLDER = tomllib.loads(APP_DIRS.read_text(encoding="utf-8"))["app"]["linux_folder_name"]


# The store stages under this process's own name (pid and kernel start tick,
# CFD-1), which the parent cannot know: the worker moves the alias the parent
# prepared onto that name before the store is used, then reports it. rename()
# keeps the inode, so the parent still compares the exact identity it made.
WORKER = r"""
local prepared = os.getenv("ERGOPTI_PREPARED_STAGE")
if prepared then
	local store = require("infra.config_paths").default_config_dir() .. "/storage.json"
	local stage = require("infra.stage_owner").stage_path(store)
	assert(os.rename(prepared, stage), "the prepared stage could not take the worker's name")
	io.write("STAGE=", stage, "\n")
end
local Storage = require("adapters.storage")
local mode = assert(os.getenv("ERGOPTI_NATIVE_STORAGE_MODE"))
if mode ~= "fresh" then assert(Storage.get("value") == "retained") end
if mode == "refuse" then
	assert(Storage.set("value", "replacement") == false, "storage reused a foreign temporary path")
	assert(Storage.get("value") == "retained", "failed staging published its cache")
elseif mode == "limit" then
	assert(Storage.set("candidate", string.rep("x", 2000)) == false, "kernel write limit was ignored")
	assert(Storage.get("value") == "retained" and Storage.get("candidate") == nil)
else
	assert(Storage.set("value", "replacement"))
	assert(Storage.get("value") == "replacement")
	package.loaded["adapters.storage"] = nil
	assert(require("adapters.storage").get("value") == "replacement")
end
"""


def kernel_write_limit():
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (64, 64))


def main():
    assert os.getuid() != 0, "storage temp receipts require an ordinary user"
    interpreter = os.environ.get("ERGOPTI_STORAGE_TEST_LUA", "luajit")
    checks, failures = 0, 0
    original = b'{"value":"retained"}'
    foreign = b"Synthetic retained foreign bytes"
    with tempfile.TemporaryDirectory(prefix="ergopti-storage-temp-") as folder:
        root = pathlib.Path(folder)

        def check(name, test):
            nonlocal checks, failures
            checks += 1
            try:
                test()
                print(f"PASS {name}", flush=True)
            except (AssertionError, subprocess.TimeoutExpired) as failure:
                failures += 1
                print(f"FAIL {name}: {failure}", flush=True)

        def run(case_root, mode, limited=False, prepared=None):
            env = dict(os.environ)
            env["XDG_CONFIG_HOME"] = str(case_root)
            env["ERGOPTI_NATIVE_STORAGE_MODE"] = mode
            if prepared is not None:
                env["ERGOPTI_PREPARED_STAGE"] = str(prepared)
            env["LUA_PATH"] = (
                "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;"
            )
            return subprocess.run(
                [interpreter, "-e", WORKER],
                env=env,
                capture_output=True,
                text=True,
                timeout=2,
                preexec_fn=kernel_write_limit if limited else None,
            )

        def alias_case(kind):
            case_root = root / kind
            directory = case_root / FOLDER
            directory.mkdir(parents=True)
            store = directory / "storage.json"
            staging = directory / "prepared-stage"
            target = case_root / "foreign"
            store.write_bytes(original)
            if kind != "dangling":
                target.write_bytes(foreign)
            if kind in ("symlink", "dangling"):
                staging.symlink_to(target)
            elif kind == "device":
                staging.symlink_to("/dev/full")
            elif kind == "hardlink":
                os.link(target, staging)
            elif kind == "fifo":
                os.mkfifo(staging)
            elif kind == "directory":
                staging.mkdir()
            else:
                staging.write_bytes(foreign)
            identity = staging.lstat()
            if kind == "denied-directory":
                directory.chmod(0o555)
            try:
                # A denied directory refuses the rename too: the store's own
                # exclusive creation is what is refused there.
                denied = kind == "denied-directory"
                child = run(case_root, "refuse", prepared=None if denied else staging)
                if not denied:
                    named = [
                        line[len("STAGE=") :]
                        for line in child.stdout.splitlines()
                        if line.startswith("STAGE=")
                    ]
                    assert len(named) == 1, (child.stdout + child.stderr)[-1000:]
                    staging = pathlib.Path(named[0])
                assert (
                    store.is_file() and not store.is_symlink() and store.read_bytes() == original
                ), "foreign staging changed the committed store"
                assert staging.exists() or staging.is_symlink(), "foreign staging path was unlinked"
                current = staging.lstat()
                assert (current.st_dev, current.st_ino, current.st_mode) == (
                    identity.st_dev,
                    identity.st_ino,
                    identity.st_mode,
                ), "foreign staging path was replaced or unlinked"
                if kind == "dangling":
                    assert not target.exists(), "dangling staging created its foreign target"
                else:
                    assert target.read_bytes() == foreign, (
                        "foreign staging truncated another owned file"
                    )
                if stat.S_ISREG(identity.st_mode):
                    assert staging.read_bytes() == foreign, "foreign regular staging was truncated"
                assert child.returncode == 0, (child.stdout + child.stderr)[-1000:]
            finally:
                directory.chmod(0o700)

        for kind in (
            "regular",
            "symlink",
            "hardlink",
            "dangling",
            "fifo",
            "device",
            "denied-directory",
            "directory",
        ):
            check(f"actual {kind} staging remains untouched", lambda kind=kind: alias_case(kind))

        def healthy_case(fresh):
            case_root = root / ("fresh" if fresh else "healthy")
            directory = case_root / FOLDER
            if not fresh:
                directory.mkdir(parents=True)
                (directory / "storage.json").write_bytes(original)
            child = run(case_root, "fresh" if fresh else "healthy")
            assert child.returncode == 0, (child.stdout + child.stderr)[-1000:]
            assert not list(directory.glob("storage.json.*.tmp"))
            assert '"replacement"' in (directory / "storage.json").read_text()

        check("native first write creates its directory and reloads", lambda: healthy_case(True))
        check("native replacement commits and reloads", lambda: healthy_case(False))

        def limited_write():
            case_root = root / "write-limit"
            directory = case_root / FOLDER
            directory.mkdir(parents=True)
            store = directory / "storage.json"
            store.write_bytes(original)
            child = run(case_root, "limit", limited=True)
            assert child.returncode == 0, (child.stdout + child.stderr)[-1000:]
            assert store.read_bytes() == original and not list(
                directory.glob("storage.json.*.tmp")
            ), "failed owned staging changed durable bytes or leaked its temp"

        check(
            "kernel file-size limit preserves store/cache and retires owned staging", limited_write
        )
    print(f"Native JSON storage temp receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
