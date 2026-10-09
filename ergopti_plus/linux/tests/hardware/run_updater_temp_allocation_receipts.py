#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_updater_temp_allocation_receipts.py
#
# Lower only an owned child's real descriptor limit after production modules
# load. Native mkstemp must fail without escaping public download APIs. Restore
# the limit before checking receipts and cancellation. No allocator, filesystem,
# process or HTTP adapter is mocked; healthy controls use curl's protocol fence.
# A fixture seam seeds the selected release before the native resource limit.

import os
import pathlib
import resource
import select
import subprocess
import tempfile


WORKER = r"""
local uv = require("luv")
local Manager = require("modules.updater.manager")
local ScriptActions = require("modules.shortcuts.script_actions")
local controller = ScriptActions.new({
 reset = function() assert(Manager.cancel_update()) end,
 reload = function() Manager.stop_background_checks(); assert(Manager.cancel_update()) end,
 quit = function() Manager.stop_background_checks(); assert(Manager.cancel_update()) end,
})
Manager.init({ is_paused = controller.is_paused })
assert(Manager.stop_background_checks() == true, "Actual updater background cancellation refused")
uv.run()
assert(not uv.loop_alive(), "Actual updater preparation retained native timer debt")
-- Prepare actual runtime libraries before the parent applies RLIMIT_NOFILE.
-- These production factories acquire no archive/reader/EVP context or timer.
-- Keep them reachable through the original operation and native retirement.
local prepared_transfer = require("modules.updater.archive_transfer")
local Output = require("infra.archive_output")
local prepared_artifact = assert(Output.native_artifact("ergopti-plus-linux.tar.gz"),
 "Actual native archive runtime preparation unavailable")
local prepared_output = Output.native()
local prepared_digest = require("infra.fd_sha256").native()
local api = assert(os.getenv("ERGOPTI_NATIVE_UPDATER_API"))
local denied = os.getenv("ERGOPTI_NATIVE_UPDATER_DENIED") == "true"
local wants_callback = os.getenv("ERGOPTI_NATIVE_UPDATER_CALLBACK") == "true"
local release = { tag = "v4.0.0", download_url = "https://127.0.0.1:1/archive",
	checksum_url = "https://127.0.0.1:1/checksum" }
Manager._test_set_cached_release(release)
local callbacks, received_path, received_error = 0, nil, nil
local callback
if wants_callback then
	callback = function(path, err) callbacks = callbacks + 1; received_path, received_error = path, err end
end
print("ready"); io.stdout:flush(); assert(io.read("*l") == "go")
local ok, dispatched = pcall(function()
	if api == "update" then return Manager.download_update(nil, callback) end
	return Manager.download_release(release, callback)
end)
print("receipt", ok, dispatched == false, callbacks); io.stdout:flush()
assert(io.read("*l") == "restored")
assert(ok, "native temporary allocation exception escaped public API")
assert(dispatched == not denied, "native allocation dispatch receipt differs from its capacity")
uv.run()
assert(callbacks == (wants_callback and 1 or 0), "refusal did not acknowledge the callback exactly once")
if wants_callback then
	assert(received_path == nil and type(received_error) == "string")
	if denied then assert(received_error == "temporary path unavailable") end
end
assert(not uv.loop_alive(), "refused operation left a native owner alive")
local expected_state = denied and "available" or (api == "update" and "idle" or "available")
assert(Manager.get_state() == expected_state, "refusal changed the pre-allocation state")
assert(Manager.get_cached_release().tag == release.tag)
assert(Manager.cancel_update() and Manager.get_state() == "idle")
assert(type(prepared_artifact) == "table" and type(prepared_output) == "table"
 and type(prepared_digest) == "table" and type(prepared_transfer) == "table", "Actual prepared runtime owners lost")
"""


def main():
    interpreter = os.environ.get("ERGOPTI_HTTP_TEST_LUA", "luajit")
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-updater-temp-allocation-") as folder:
        root = pathlib.Path(folder)
        for api in ("update", "release"):
            for limit in (0, 3, None):
                for callback in (True, False):
                    checks += 1
                    case_name = f"{api}-limit-{limit}-callback-{callback}"
                    env = dict(os.environ)
                    env.update(
                        {
                            "XDG_CONFIG_HOME": str(root / case_name / "config"),
                            "ERGOPTI_NATIVE_UPDATER_API": api,
                            "ERGOPTI_NATIVE_UPDATER_DENIED": "true"
                            if limit is not None
                            else "false",
                            "ERGOPTI_NATIVE_UPDATER_CALLBACK": "true" if callback else "false",
                            "LUA_PATH": "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                        }
                    )
                    child = None
                    previous_limit = None
                    try:
                        child = subprocess.Popen(
                            [interpreter, "-e", WORKER],
                            env=env,
                            stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            text=True,
                        )
                        assert child.stdout.readline().strip() == "ready", (
                            "native modules did not load"
                        )
                        if limit is not None:
                            previous_limit = resource.prlimit(child.pid, resource.RLIMIT_NOFILE)
                            resource.prlimit(
                                child.pid, resource.RLIMIT_NOFILE, (limit, previous_limit[1])
                            )
                            assert resource.prlimit(child.pid, resource.RLIMIT_NOFILE) == (
                                limit,
                                previous_limit[1],
                            )
                        child.stdin.write("go\n")
                        child.stdin.flush()
                        assert select.select([child.stdout], [], [], 5)[0], (
                            "native allocation did not settle"
                        )
                        receipt = child.stdout.readline().strip()
                        assert receipt.startswith("receipt\t"), (
                            "native allocation did not produce its receipt"
                        )
                        if previous_limit is not None:
                            resource.prlimit(child.pid, resource.RLIMIT_NOFILE, previous_limit)
                            previous_limit = None
                        stdout, stderr = child.communicate(input="restored\n", timeout=5)
                        assert child.returncode == 0, (receipt + "\n" + stdout + stderr)[-1200:]
                        print(f"PASS native {case_name}", flush=True)
                    except (AssertionError, subprocess.TimeoutExpired) as error:
                        failures += 1
                        print(f"FAIL native {case_name}: {error}", flush=True)
                    finally:
                        if child and child.poll() is None:
                            if previous_limit is not None:
                                resource.prlimit(child.pid, resource.RLIMIT_NOFILE, previous_limit)
                            child.kill()
                            child.communicate()
    print(f"Native updater temporary allocation receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
