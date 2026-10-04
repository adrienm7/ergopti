#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_native_path_literal_receipts.py
#
# Copy the real loader into actual sibling/child filesystem layouts. Native Lua
# source localization, working directories, file reads and updater default probes
# must preserve POSIX filename bytes. This is a layout fixture, not an installed
# daemon. No path, filesystem, shell or debug-source adapter is mocked. Accurate,
# absent and stale PWD values and a real post-launch chdir exercise cwd ownership.

import itertools
import os
import pathlib
import shutil
import subprocess
import tempfile


WORKER = r"""
if os.getenv("ERGOPTI_NATIVE_CHDIR") then
	assert(require("luv").chdir(os.getenv("ERGOPTI_NATIVE_CHDIR")))
end
local Paths = assert(loadfile(assert(os.getenv("ERGOPTI_NATIVE_PATH_SOURCE"))))()
local root = assert(os.getenv("ERGOPTI_NATIVE_DRIVER_ROOT"))
local shared = assert(os.getenv("ERGOPTI_NATIVE_SHARED_ROOT"))
assert(Paths.driver_root() == root, "native source/cwd filename bytes were rewritten")
assert(Paths.shared_root() == shared, "real shared-tree lookup lost literal directory bytes")
local locale_path = assert(Paths.shared("data/locales/en.json"))
local file = assert(io.open(locale_path, "rb")); local bytes = assert(file:read("*a")); assert(file:close())
assert(#bytes > 100 and require("json").decode(bytes), "actual shared locale file was not read")
package.loaded["infra.paths"] = Paths
local Installer = require("modules.updater.installer")
local context = Installer.resolve(assert(os.getenv("ERGOPTI_NATIVE_MANAGER_SOURCE")))
assert(context.kind == "standalone", "literal directory bytes prevented native installation classification")
assert(context.install_root == os.getenv("ERGOPTI_NATIVE_INSTALL_ROOT"))
assert(context.parent == os.getenv("ERGOPTI_NATIVE_INSTALL_PARENT"))
assert(context.wrapper == os.getenv("ERGOPTI_NATIVE_INSTALL_WRAPPER"))
"""


def main():
    driver = pathlib.Path.cwd()
    shared_source = driver.parent / "_shared"
    interpreter = os.environ.get("ERGOPTI_PATH_TEST_LUA", "luajit")
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-native-literal-path-") as folder:
        base = pathlib.Path(folder)
        for name, layout, loading, cwd_state in itertools.product(
            (
                "ordinary",
                "space ' ü",
                "line\r\nbreak",
                r"literal\backslash",
                r"double\\backslash",
                r"\leading",
            ),
            ("sibling", "child"),
            ("absolute", "relative"),
            ("accurate", "stale", "unset", "changed"),
        ):
            prefix = base / name / layout / loading / cwd_state
            install = prefix / "lib" / "ergopti_plus"
            root = install / "linux"
            shared = install / "_shared" if layout == "sibling" else root / "_shared"
            (root / "infra").mkdir(parents=True)
            (root / "modules" / "updater").mkdir(parents=True)
            (shared / "data" / "locales").mkdir(parents=True)
            (shared / "lua").mkdir()
            (prefix / "bin").mkdir()
            source = root / "infra" / "paths.lua"
            manager = root / "modules" / "updater" / "manager.lua"
            wrapper = prefix / "bin" / "ergopti-hotstrings"
            shutil.copyfile(driver / "infra" / "paths.lua", source)
            shutil.copyfile(driver / "modules" / "updater" / "manager.lua", manager)
            shutil.copyfile(
                shared_source / "data" / "locales" / "en.json",
                shared / "data" / "locales" / "en.json",
            )
            wrapper.write_text("#!/bin/sh\n")
            expected_shared = str(root) + "/../_shared" if layout == "sibling" else str(shared)
            checks += 1
            env = dict(os.environ)
            env.update(
                {
                    "PWD": str(install),
                    "XDG_CONFIG_HOME": str(prefix / "config"),
                    "ERGOPTI_NATIVE_PATH_SOURCE": str(source)
                    if loading == "absolute"
                    else "linux/infra/paths.lua",
                    "ERGOPTI_NATIVE_DRIVER_ROOT": str(root),
                    "ERGOPTI_NATIVE_SHARED_ROOT": expected_shared,
                    "ERGOPTI_NATIVE_MANAGER_SOURCE": str(manager)
                    if loading == "absolute"
                    else "linux/modules/updater/manager.lua",
                    "ERGOPTI_NATIVE_INSTALL_ROOT": str(install),
                    "ERGOPTI_NATIVE_INSTALL_PARENT": str(prefix / "lib"),
                    "ERGOPTI_NATIVE_INSTALL_WRAPPER": str(wrapper),
                    "LUA_PATH": str(driver / "?.lua")
                    + ";"
                    + str(driver / "?" / "init.lua")
                    + ";"
                    + str(shared_source / "lua" / "?.lua")
                    + ";"
                    + str(shared_source / "lua" / "?" / "init.lua")
                    + ";;",
                }
            )
            child_cwd = install
            if cwd_state in ("stale", "changed"):
                env["PWD"] = str(base)
            elif cwd_state == "unset":
                env.pop("PWD", None)
            if cwd_state == "changed":
                child_cwd = base
                env["ERGOPTI_NATIVE_CHDIR"] = str(install)
            try:
                child = subprocess.run(
                    [interpreter, "-e", WORKER],
                    cwd=child_cwd,
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                assert child.returncode == 0, (child.stdout + child.stderr)[-1000:]
                print(f"PASS native {name!r} {layout} {loading} {cwd_state}", flush=True)
            except (AssertionError, subprocess.TimeoutExpired) as error:
                failures += 1
                print(f"FAIL native {name!r} {layout} {loading} {cwd_state}: {error}", flush=True)
    print(f"Native literal path receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
