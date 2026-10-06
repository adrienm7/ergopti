--- tests/hardware/run_program_literal_receipts.lua

--- Actual private runner/owner proof with an independent binary argv preimage.
--- This fixture owns its subreaper, executable link, script and all child IDs.
local uv, ffi = require("luv"), require("ffi")
ffi.cdef[[ int prctl(int option, unsigned long arg2, unsigned long arg3, unsigned long arg4, unsigned long arg5); ]]
assert(ffi.C.prctl(36, 1, 0, 0, 0) == 0, "literal program fixture requires owned child-subreaper support")
local Runner = require("adapters.program_runner")
local Owner = require("modules.gestures.program_owner")
local Shell = require("adapters.shell_runner")
local Json = require("json")
local Logger = require("logger.shim")
local python = assert(Shell.exec_line("command -v python3"))
assert(python:sub(1, 1) == "/", "literal program fixture requires an absolute Python executable")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-literal-program-XXXXXX"))
local script = root .. "/programme été 日本語.py"
local executable = root .. "/Python lié executable"
local recorded, metadata = root .. "/argv recorded", root .. "/native identity"
local metadata_release = metadata .. ".continue"
local preimage, release, interpolated = root .. "/argv preimage", root .. "/release", root .. "/interpolated"
local literals = { "", "été 日本語", "literal 'single' and \"double\" quotes",
	"`touch " .. interpolated .. "`", "$(touch " .. interpolated .. ")", "line one\nline two",
	"%PATH%", "e\204\129" } -- U+0065 followed by U+0301; retain the independent UTF-8 bytes.
local expected = {}
for index, value in ipairs(literals) do expected[index] = tostring(#value) .. ":" .. value .. "\n" end
expected = table.concat(expected)

local function write(path, bytes)
	local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
end
local function read(path)
	local file = io.open(path, "rb")
	if not file then return end
	local bytes = assert(file:read("*a")); assert(file:close()); return bytes
end
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
	local bytes = read("/proc/" .. tostring(pid) .. "/stat")
	if not bytes then return end
	local fields = {}
	for field in assert(bytes:match("^%d+ %(.+%) (.+)$")):gmatch("%S+") do fields[#fields + 1] = field end
	return fields[1], tonumber(fields[3]), fields[20]
end

write(preimage, expected)
write(script, [[
import json
import os
import sys
import time

with open(sys.argv[1], "wb") as record:
    for value in sys.argv[4:]:
        data = value.encode("utf-8")
        record.write(str(len(data)).encode("ascii") + b":" + data + b"\n")
with open(sys.argv[2], "w", encoding="ascii") as record:
    encoded = json.dumps({"pid": os.getpid(), "group": os.getpgrp(),
                          "stdout": os.readlink("/proc/self/fd/1"),
                          "stderr": os.readlink("/proc/self/fd/2")})
    midpoint = len(encoded) // 2
    record.write(encoded[:midpoint])
    record.flush()
    deadline = time.monotonic() + 10
    while not os.path.exists(sys.argv[2] + ".continue"):
        if time.monotonic() >= deadline:
            sys.exit(99)
        time.sleep(0.001)
    record.write(encoded[midpoint:])
for unused in range(256):
    os.write(1, b"PRIVATE PROGRAM STDOUT MUST BE DISCARDED\n" * 128)
    os.write(2, b"PRIVATE PROGRAM STDERR MUST BE DISCARDED\n" * 128)
deadline = time.monotonic() + 10
while not os.path.exists(sys.argv[3]):
    if time.monotonic() >= deadline:
        sys.exit(99)
    time.sleep(0.001)
sys.exit(37)
]])
assert(uv.fs_symlink(python, executable))
local owner, handle, leader, birth
local statuses, messages, settlements = {}, {}, 0
local prior_error = Logger.error
Logger.error = function(_, template, ...) messages[#messages + 1] = string.format(template, ...) end
local ok, failure = xpcall(function()
	assert(uv.fs_readlink(executable) == python, "native executable symlink must retain its independently chosen target")
	assert(Runner.available(executable), "actual runner must admit the executable symlink")
	local arguments = { script, recorded, metadata, release }
	for _, value in ipairs(literals) do arguments[#arguments + 1] = value end
	local scalar = assert(Json.encode({ version = 1, executable = executable, arguments = arguments }))
	owner = Owner.new(function(binding)
		assert(binding == "fixture_literal", "native owner must retain the requested binding")
		return scalar, function() return true end
	end, { runner = { spawn = function(binary, argv, completed, admitted)
		-- Observe the real adapter's closed receipt without substituting native ports.
		handle = Runner.spawn(binary, argv, function(status)
			statuses[#statuses + 1] = status
			completed(status)
		end, admitted)
		return handle
	end } })
	assert(owner.run("fixture_literal"), "actual program owner refused the native literal request")
	assert(owner.when_settled(function() settlements = settlements + 1 end))
	local partial
	assert(await(function()
		partial = read(metadata)
		return partial ~= nil and #partial > 0
	end), "native fixture did not publish its deliberate incomplete metadata receipt")
	assert(Json.decode_lossless(partial) == nil,
		"an incomplete actual metadata receipt must remain unready without raising an exception")
	assert(owner.has_pending() and handle.isSettled() == false and settlements == 0,
		"incomplete metadata cannot acknowledge physical retirement")
	write(metadata_release, "continue\n")
	local observed
	assert(await(function()
		local bytes = read(metadata)
		observed = bytes and Json.decode_lossless(bytes) or nil
		return type(observed) == "table" and read(recorded) == expected
	end), "complete native literal receipts were not written")
	leader = observed.pid
	local state, group, stamp = identity(leader)
	assert(state and group == leader and observed.group == leader, "actual fixture must own its detached leader group")
	birth = stamp
	assert(owner.has_pending() and handle.isSettled() == false and settlements == 0,
		"a live literal program cannot acknowledge retirement")
	assert(read(recorded) == read(preimage) and read(preimage) == expected,
		"native argv differs from the binary preimage written before execution")
	assert(observed.stdout == "/dev/null" and observed.stderr == "/dev/null",
		"private native stdout and stderr must be physically discarded")
	local marker, _, marker_code = uv.fs_stat(interpolated)
	assert(marker == nil and marker_code == "ENOENT", "literal arguments must never execute shell interpolation")
	write(release, "release\n")
	assert(await(function() return not owner.has_pending() end), "actual program owner did not physically retire")
	assert(handle.isSettled() == true and settlements == 1, "actual native handle must settle exactly once")
	assert(#statuses == 1 and statuses[1] == 37, "closed native completion must preserve exact exit status 37")
	assert(#messages == 1 and messages[1] == "Private user program exited with status 37.",
		"actual owner diagnostics must contain only the closed nonzero status")
	assert(identity(leader) == nil, "the exact original native leader must have been reaped")
	local signalled, _, signal_code = uv.kill(-leader, 0)
	assert(signalled == nil and signal_code == "ESRCH", "the full original detached group must be absent")
	assert(await(function() return not uv.loop_alive() end), "actual native process or timer handles leaked")
end, debug.traceback)

-- Cleanup never discovers or kills an unrelated process. The actual retained
-- runner capability is authoritative; the captured start time checks its ID.
write(release, "release\n")
write(metadata_release, "continue\n")
if leader and birth then
	local state, group, stamp = identity(leader)
	if state then assert(group == leader and stamp == birth, "failure cleanup refuses a foreign leader identity") end
end
if owner then owner.stop() end
if handle then handle.terminate(true) end
assert(await(function()
	return (not owner or not owner.has_pending()) and (not handle or handle.isSettled()) and not uv.loop_alive()
end), "owned failure cleanup left a native group or handle")
Logger.error = prior_error
for _, path in ipairs({ recorded, metadata, metadata_release, preimage, release, interpolated, executable, script }) do uv.fs_unlink(path) end
assert(uv.fs_rmdir(root))
if not ok then error(failure, 0) end
print("PASS private native literal argv, executable symlink, discarded streams and exit 37")
