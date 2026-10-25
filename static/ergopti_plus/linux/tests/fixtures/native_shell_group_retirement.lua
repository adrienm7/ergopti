--- tests/fixtures/native_shell_group_retirement.lua

--- ==============================================================================
--- MODULE: Actual ShellRunner Process Family Retirement Regression
--- DESCRIPTION:
--- Owns real Python leaders and descendants under a Linux subreaper. Children
--- that close their pipes remain process-group debt just like children retaining
--- them. Success, failure and cancellation cannot abandon a live descendant or
--- publish before exact group absence and every native close acknowledgement.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_shell_group_retirement%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
local uv, ffi = require("luv"), require("ffi")
ffi.cdef([[
	int prctl(int option, ...);
	int waitpid(int pid, int *status, int options);
]])
local PR_SET_CHILD_SUBREAPER, WNOHANG = 36, 1
assert(ffi.C.prctl(PR_SET_CHILD_SUBREAPER, ffi.new("int", 1), ffi.new("int", 0), ffi.new("int", 0), ffi.new("int", 0)) == 0)
-- The other native admission fixture initializes ShellRunner first. This
-- order proves the canonical owner's deferred validator cannot create a cycle.
require("adapters.owned_process")
local Shell = require("adapters.shell_runner")
local directory = assert(uv.fs_mkdtemp("/var/tmp/erg-shell-family-XXXXXX"))
local checks, failures = 0, 0
local PROGRAM = [[
import os, signal, sys, time
mode, receipt = sys.argv[1:3]
leader, child = os.getpid(), 0
if mode in ("closed", "retained", "cancel"):
    child = os.fork()
    if child == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if mode == "closed":
            for fd in (0, 1, 2): os.close(fd)
        with open(receipt + ".ready", "w") as output: output.write("ready")
        time.sleep(30)
        os._exit(0)
    while not os.path.exists(receipt + ".ready"): time.sleep(0.001)
with open(receipt, "w") as output: output.write(str(leader) + " " + str(child))
print("leader-output", flush=True)
print("leader-warning", file=sys.stderr, flush=True)
if mode == "cancel": time.sleep(30)
sys.exit(7 if mode == "failed" else 0)
]]

local function identities(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = assert(file:read("*a")); assert(file:close())
	local leader, child = text:match("^(%d+) (%d+)$")
	return tonumber(leader), tonumber(child)
end

local function absent(pid)
	local value, _, code = uv.kill(-pid, 0)
	return value == nil and code == "ESRCH"
end

local function handles()
	local count = 0
	uv.walk(function() count = count + 1 end)
	return count
end

for _, mode in ipairs({ "success", "failed", "closed", "retained", "cancel" }) do
	checks = checks + 1
	local path = directory .. "/" .. mode
	local leader, child, operation, result
	local child_reaped = false
	local callbacks, retired_at_callback = 0, false
	local function reap()
		if child and child > 0 and not child_reaped then
			child_reaped = ffi.C.waitpid(child, ffi.new("int[1]"), WNOHANG) == child
		end
	end
	local function await(predicate)
		local deadline = uv.hrtime() + 3000000000
		repeat
			uv.run("nowait"); reap()
			if predicate() then return end
			uv.sleep(1)
		until uv.hrtime() >= deadline
		error("exact native shell family did not retire")
	end
	local ok, err = xpcall(function()
		operation = assert(Shell.run_async("python3", { "-c", PROGRAM, mode, path }, { timeout_ms = 500 }, function(value)
			result, callbacks = value, callbacks + 1
			leader, child = identities(path)
			retired_at_callback = leader ~= nil and absent(leader) and handles() == 0
		end))
		if mode == "cancel" then
			await(function() leader, child = identities(path); return leader ~= nil end)
			assert(not absent(leader), "cancel control lost its live family before cancellation")
			operation.cancel(); operation.cancel()
		end
		await(function()
			leader, child = identities(path)
			if result then
				assert(retired_at_callback, "shell callback preceded exact group absence or native close ACK: " .. tostring(result.error) .. " / " .. tostring(result.stderr))
				if mode == "closed" or mode == "retained" then
					assert(result.ok == false and type(result.error) == "string", "orphaned native family reported success")
				end
			end
			return leader ~= nil and absent(leader) and handles() == 0
		end)
		if mode == "cancel" then
			assert(callbacks == 0, "cancelled native family published a result")
		else
			assert(callbacks == 1, "native family did not publish exactly once")
			if mode == "success" or mode == "failed" then
				assert(result.ok == (mode == "success") and result.code == (mode == "success" and 0 or 7))
				assert(result.stdout == "leader-output\n" and result.stderr == "leader-warning\n")
			end
		end
	end, debug.traceback)
	leader, child = identities(path)
	if leader and not absent(leader) then
		uv.kill(-leader, "sigkill")
		if child and child > 0 and not child_reaped then uv.kill(child, "sigkill") end
	end
	if operation then operation.cancel() end
	await(function() return not uv.loop_alive() and (not leader or absent(leader)) end)
	assert(handles() == 0, "fixture retained a native handle")
	if uv.fs_stat(path) then assert(uv.fs_unlink(path)) end
	if uv.fs_stat(path .. ".ready") then assert(uv.fs_unlink(path .. ".ready")) end
	if ok then print("PASS actual shell family " .. mode .. " retires exact group and native handles") else
		failures = failures + 1
		io.stderr:write("FAIL actual shell family " .. mode .. ": " .. tostring(err) .. "\n")
	end
end
assert(uv.fs_rmdir(directory))
print(string.format("Native shell family retirement: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
