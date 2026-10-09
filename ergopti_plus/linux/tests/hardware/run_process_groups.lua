--- tests/hardware/run_process_groups.lua

--- ==============================================================================
--- MODULE: Native Asynchronous Process Group Regression
--- DESCRIPTION:
--- Drives both production libuv runners against a real forked descendant that
--- retains stdout/stderr after its leader exits. Deadlines and cancellation must
--- terminate that descendant, not merely close the daemon's pipes. No input
--- device or display server is required (linux-orphaned-process-group).
--- A real ENOENT spawn also proves refusal does not publish a second outcome.
--- SIGTERM-resistant descendants must settle on deadlines and cancellation.
--- A child actually killed by a signal must never report successful completion.
--- ==============================================================================

local uv = require("luv")
local ShellRunner = require("adapters.shell_runner")
local ProcessRunner = require("adapters.process_runner")

local TIMEOUT_MS = 500
local WAIT_MS = 3000
local directory = assert(uv.fs_mkdtemp("/tmp/ergopti-process-groups-XXXXXX"))
local failures = 0

local PROGRAM = [[
import os
import signal
import sys
import time

leader = os.getpid()
child = os.fork()
if child == 0:
    if len(sys.argv) > 2:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open(sys.argv[1] + ".ready", "w", encoding="ascii") as receipt:
        receipt.write("ready")
    time.sleep(30)
    os._exit(0)
with open(sys.argv[1], "w", encoding="ascii") as receipt:
    receipt.write(str(leader) + " " + str(child))
os._exit(0)
]]

--- Reads the fixture's exact process identities.
--- @param path string
--- @return number|nil leader
--- @return number|nil descendant
local function read_receipt(path)
	local file = io.open(path, "r")
	if not file then return nil end
	local text = file:read("*a")
	file:close()
	local leader, descendant = text:match("^(%d+) (%d+)$")
	return tonumber(leader), tonumber(descendant)
end

--- A zombie has stopped executing but can await this container's init reaper.
--- @param pid number
--- @return boolean
local function running(pid)
	local file = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
	if not file then return false end
	local text = file:read("*a")
	file:close()
	local state = assert(text:match("^%d+ %(.+%) (%a) "), "invalid process state receipt")
	return state ~= "Z" and state ~= "X"
end

--- Pumps actual libuv events for a bounded readiness or teardown check.
--- @param predicate function
--- @return boolean
local function await(predicate)
	local deadline = uv.hrtime() + WAIT_MS * 1000000
	repeat
		uv.run("nowait")
		if predicate() then return true end
		uv.sleep(10)
	until uv.hrtime() >= deadline
	return false
end

--- Exercises one production runner and always cleans up its owned group.
--- @param name string
--- @param dispatch function
--- @param cancel boolean
local function check(name, dispatch, cancel)
	local path = directory .. "/" .. name
	local leader, descendant, handle
	local answers, result = 0, nil
	local ok, err = xpcall(function()
		handle = assert(dispatch(path, function(answer)
			answers, result = answers + 1, answer
		end), "the production runner did not dispatch")
		assert(await(function()
			leader, descendant = read_receipt(path)
			return leader and not running(leader) and uv.fs_stat(path .. ".ready") ~= nil
		end), "the leader did not exit before the deadline")
		assert(running(descendant), "the fixture did not retain a live descendant")
		if cancel then
			handle.cancel()
		else
			assert(await(function() return answers > 0 end), "missing deadline callback")
			assert(result.error and (result.error == "timeout" or result.error:find("did not finish", 1, true)),
				"the result must identify the deadline")
		end
		assert(await(function() return not running(descendant) end),
			"descendant survived after its leader exited")
		assert(answers == (cancel and 0 or 1), "terminal callback count changed")
		assert(await(function() return not uv.loop_alive() end), "libuv handles survived teardown")
	end, debug.traceback)
	-- Re-read even when a failed readiness assertion preceded identity capture.
	leader, descendant = read_receipt(path)
	if leader then uv.kill(-leader, "sigkill") end
	if descendant and running(descendant) then uv.kill(descendant, "sigkill") end
	if type(handle) == "table" then handle.cancel() end
	await(function() return not uv.loop_alive() end)
	uv.fs_unlink(path)
	uv.fs_unlink(path .. ".ready")
	if ok then
		print("PASS " .. name .. " (native fork, pipes, process group and libuv)")
	else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

check("shell-deadline", function(path, callback)
	return ShellRunner.run_async("python3", { "-c", PROGRAM, path }, { timeout_ms = TIMEOUT_MS }, callback)
end, false)

check("process-deadline", function(path, callback)
	return ProcessRunner.run("python3", { "-c", PROGRAM, path }, { timeout_ms = TIMEOUT_MS }, callback)
end, false)

check("shell-cancel", function(path, callback)
	return ShellRunner.run_async("python3", { "-c", PROGRAM, path }, { timeout_ms = WAIT_MS }, callback)
end, true)

check("shell-stubborn-deadline", function(path, callback)
	return ShellRunner.run_async("python3", { "-c", PROGRAM, path, "ignore-term" },
		{ timeout_ms = TIMEOUT_MS }, callback)
end, false)

check("shell-stubborn-cancel", function(path, callback)
	return ShellRunner.run_async("python3", { "-c", PROGRAM, path, "ignore-term" },
		{ timeout_ms = WAIT_MS }, callback)
end, true)

check("process-stubborn-deadline", function(path, callback)
	return ProcessRunner.run("python3", { "-c", PROGRAM, path, "ignore-term" },
		{ timeout_ms = TIMEOUT_MS }, callback)
end, false)

local callbacks = 0
local handle, reason = ShellRunner.run_async(directory .. "/missing-program", {},
	{ timeout_ms = TIMEOUT_MS }, function() callbacks = callbacks + 1 end)
local settled = await(function() return not uv.loop_alive() end)
local refusal_ok = handle == nil and type(reason) == "string"
	and reason:find("ENOENT", 1, true) ~= nil and callbacks == 0 and settled
if refusal_ok then
	print("PASS shell-spawn-refusal (native ENOENT, no callback and no live handles)")
else
	failures = failures + 1
	io.stderr:write(string.format("FAIL shell-spawn-refusal: handle=%s reason=%s callbacks=%d settled=%s\n",
		tostring(handle), tostring(reason), callbacks, tostring(settled)))
end

local signalled_args = { "-c", "import os, signal; os.kill(os.getpid(), signal.SIGTERM)" }
for _, runner in ipairs({ "shell", "process" }) do
	local result, answers = nil, 0
	local callback = function(value) result, answers = value, answers + 1 end
	local dispatched
	if runner == "shell" then
		dispatched = ShellRunner.run_async("python3", signalled_args, { timeout_ms = TIMEOUT_MS }, callback)
	else
		dispatched = ProcessRunner.run("python3", signalled_args, { timeout_ms = TIMEOUT_MS }, callback)
	end
	local settled_signal = await(function() return result ~= nil and not uv.loop_alive() end)
	local exit_code = result and (result.code or result.exit_code)
	if dispatched and settled_signal and answers == 1 and exit_code == 143
		and result.error ~= nil and result.ok ~= true then
		print("PASS " .. runner .. "-signal-exit (native SIGTERM reports failure and exit code 143)")
	else
		failures = failures + 1
		io.stderr:write(string.format("FAIL %s-signal-exit: exit_code=%s callbacks=%d settled=%s\n",
			runner, tostring(exit_code), answers, tostring(settled_signal)))
	end
end

assert(uv.fs_rmdir(directory))
print(string.format("Native process groups: %d passed, %d failed", 9 - failures, failures))
os.exit(failures == 0 and 0 or 1)
