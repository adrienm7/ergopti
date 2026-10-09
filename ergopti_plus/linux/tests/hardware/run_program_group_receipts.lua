--- tests/hardware/run_program_group_receipts.lua

--- Native private-program retirement with fixture-owned orphan reaping.
--- This process alone becomes a subreaper; every child identity is captured.
local uv, ffi = require("luv"), require("ffi")
ffi.cdef[[
	int prctl(int option, unsigned long arg2, unsigned long arg3, unsigned long arg4, unsigned long arg5);
	int waitpid(int pid, int *status, int options);
]]
assert(ffi.C.prctl(36, 1, 0, 0, 0) == 0, "private program fixture requires child-subreaper support")
local Runner = require("adapters.program_runner")
local Owner = require("modules.gestures.program_owner")
local Shell = require("adapters.shell_runner")
local Json = require("json")
local python = assert(Shell.exec_line("command -v python3"))
assert(python:sub(1, 1) == "/", "the native fixture requires an absolute Python executable")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-private-groups-XXXXXX"))
local script = root .. "/fork.py"
local source = assert(io.open(script, "wb"))
assert(source:write([[
import os
import signal
import sys
import time

child = os.fork()
if child == 0:
    if sys.argv[2] == "stubborn":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open(sys.argv[1] + ".ready", "w", encoding="ascii") as receipt:
        receipt.write("ready")
    time.sleep(30)
    os._exit(0)
while not os.path.exists(sys.argv[1] + ".ready"):
    time.sleep(0.001)
with open(sys.argv[1], "w", encoding="ascii") as receipt:
    receipt.write(str(os.getpid()) + " " + str(child) + "\n")
os._exit(0)
]])); assert(source:close())

local function await(predicate)
	local deadline = uv.hrtime() + 5000000000
	repeat
		uv.run("nowait")
		if predicate() then return true end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	return false
end

local function identity(pid)
	local file = io.open("/proc/" .. tostring(pid) .. "/stat", "rb")
	if not file then return end
	local bytes = assert(file:read("*a")); assert(file:close())
	local fields = {}
	for field in assert(bytes:match("^%d+ %(.+%) (.+)$")):gmatch("%S+") do fields[#fields + 1] = field end
	return fields[1], tonumber(fields[3]), fields[20]
end

local failures, checks = 0, 0
for _, mode in ipairs({ "ordinary", "stubborn", "owner" }) do
	checks = checks + 1
	local receipt = root .. "/" .. mode
	local leader, child, birth, handle, owner
	local completed, settlements = 0, 0
	local function reap()
		if not child then return false end
		local state, group, stamp = identity(child)
		if state then
			assert(group == leader and stamp == birth, "only the original fixture child may be reaped")
			if state ~= "Z" and state ~= "X" then return false end
		end
		local result = ffi.C.waitpid(child, ffi.new("int[1]"), 1)
		return result == child or (result == -1 and ffi.errno() == 10)
	end
	local ok, failure = xpcall(function()
		local args = { script, receipt, mode == "ordinary" and "ordinary" or "stubborn" }
		if mode == "owner" then
			local scalar = assert(Json.encode({ version = 1, executable = python, arguments = args }))
			owner = Owner.new(function() return scalar, function() return true end end)
			assert(owner.run("fixture"), "native owner refused the program")
			owner.when_settled(function() settlements = settlements + 1 end)
		else
			handle = Runner.spawn(python, args, function() completed = completed + 1 end,
				function() return true end)
			assert(handle.start())
			handle.onSettled(function() settlements = settlements + 1 end)
		end
		assert(await(function()
			local file = io.open(receipt, "rb")
			if not file then return false end
			local bytes = assert(file:read("*a")); assert(file:close())
			local parent, descendant = bytes:match("^(%d+) (%d+)\n$")
			leader, child = tonumber(parent), tonumber(descendant)
			if not leader or not child then return false end
			local state, group, stamp = identity(child)
			assert(state and group == leader, "the native child must belong to the detached fixture group")
			birth = stamp
			return identity(leader) == nil
		end), "the native fixture leader did not exit")
		local state = identity(child)
		assert(state ~= "Z" and state ~= "X", "the positive live descendant control is missing")
		assert(settlements == 0 and completed == 0, "leader exit falsely acknowledged the live descendant")
		if owner then
			assert(owner.has_pending() and owner.stop() == false, "shutdown abandoned its retained group")
			assert(owner.set_paused(false) == false and owner.run("replacement") == false,
				"pending group retirement must fence resume and replacement")
		else
			assert(handle.isSettled() == false)
			assert(handle.terminate() == false)
			assert(handle.isSettled() == false, "signal acceptance is not a retirement receipt")
			if mode == "stubborn" then
				assert(identity(child) ~= "Z", "TERM resistance is a positive native control")
				assert(handle.terminate(true) == false)
			end
		end
		assert(await(reap), "the fixture-owned descendant did not physically retire and reap")
		assert(identity(child) == nil, "native retirement must remove the original process identity")
		assert(await(function() return owner and not owner.has_pending() or handle and handle.isSettled() end),
			"group absence did not acknowledge native settlement")
		assert(settlements == 1 and completed == 0, "cancelled ownership must settle once without completion")
		if owner then assert(owner.stop() == true) else assert(handle.terminate(true) == true) end
		assert(await(function() return not uv.loop_alive() end), "native process or timer handles leaked")
	end, debug.traceback)
	-- Cleanup authority is the captured child start time and detached group.
	if child and birth then
		local state, group, stamp = identity(child)
		if state then
			assert(group == leader and stamp == birth, "cleanup refuses a foreign child identity")
			assert(uv.kill(-leader, "sigkill") == 0)
			assert(await(reap), "owned failure cleanup could not reap its child")
		end
	end
	if owner then owner.stop() end
	if handle then handle.terminate(true); handle.isSettled() end
	assert(await(function() return not uv.loop_alive() end), "failure cleanup left native handles")
	uv.fs_unlink(receipt); uv.fs_unlink(receipt .. ".ready")
	if ok then print("PASS private program native group " .. mode) else
		failures = failures + 1
		io.stderr:write("FAIL private program native group " .. mode .. ": " .. tostring(failure) .. "\n")
	end
end
assert(uv.fs_unlink(script)); assert(uv.fs_rmdir(root))
print(string.format("Private program native groups: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
