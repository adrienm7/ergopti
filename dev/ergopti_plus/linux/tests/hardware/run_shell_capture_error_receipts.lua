--- tests/hardware/run_shell_capture_error_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Shell Capture Error Receipts
--- DESCRIPTION:
--- Real argv-size and file-descriptor limits refuse production io.popen calls.
--- The command contains only synthetic canary data. Returned diagnostics and
--- the real shared logger must not copy that payload on a native launch failure.
--- Successful stdout remains caller data. No process/syscall adapter is mocked.
--- ==============================================================================

local uv = require("luv")
local ffi = require("ffi")
ffi.cdef[[
	struct ergopti_capture_rlimit { unsigned long current; unsigned long maximum; };
	int getrlimit(int resource, struct ergopti_capture_rlimit *limit);
	int setrlimit(int resource, const struct ergopti_capture_rlimit *limit);
]]
local Logger = require("logger.shim")
local CANARY = "ERGOPTI_SYNTHETIC_PRIVATE_CAPTURE_CANARY"
local checks, failures = 0, 0
Logger.set_level("debug")

local function fresh_shell()
	package.loaded["adapters.shell_runner"] = nil
	Logger.ring_buffer_clear()
	Logger.reset_dedup()
	return require("adapters.shell_runner")
end

local function assert_private_failure(shell, command)
	local accepted, output, reason = shell.exec_checked(command)
	assert(accepted == false and output == "", "native pipe refusal became success")
	assert(type(reason) == "string" and reason ~= "", "native refusal lost its diagnostic")
	assert(not reason:find(CANARY, 1, true), "returned native failure exposed the command payload")
	assert(#reason < 200, "native failure diagnostic grew with argument length")
	for _, line in ipairs(Logger.ring_buffer_snapshot()) do
		assert(not line:find(CANARY, 1, true), "shared logger copied the private command payload")
	end
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, size in ipairs({ 200000, 400000 }) do
	check("real argv-size refusal keeps " .. size .. " synthetic bytes private", function()
		local shell = fresh_shell()
		assert_private_failure(shell, "printf '%s' " .. shell.quote(CANARY .. string.rep("x", size)))
	end)
end

check("real descriptor exhaustion keeps its command payload private", function()
	local shell = fresh_shell()
	local previous = ffi.new("struct ergopti_capture_rlimit[1]")
	assert(ffi.C.getrlimit(7, previous) == 0) -- Linux RLIMIT_NOFILE ABI.
	local selected = ffi.new("struct ergopti_capture_rlimit[1]")
	selected[0].current = math.min(64, tonumber(previous[0].current))
	selected[0].maximum = previous[0].maximum
	assert(ffi.C.setrlimit(7, selected) == 0)
	local descriptors = {}
	local ok, err = xpcall(function()
		local exhausted = false
		for _ = 1, 128 do
			local fd, _, code = uv.fs_open("/dev/null", "r", 0)
			if not fd then assert(code == "EMFILE"); exhausted = true; break end
			descriptors[#descriptors + 1] = fd
		end
		assert(exhausted, "fixture did not reach the real native descriptor limit")
		assert_private_failure(shell, "printf '%s' " .. shell.quote(CANARY))
	end, debug.traceback)
	for _, fd in ipairs(descriptors) do assert(uv.fs_close(fd)) end
	assert(ffi.C.setrlimit(7, previous) == 0, "fixture could not restore its own descriptor limit")
	assert(ok, err)
end)

check("ordinary native stdout preserves caller data", function()
	local shell = fresh_shell()
	local accepted, output, reason = shell.exec_checked("printf '%s' " .. shell.quote(CANARY))
	assert(accepted and output == CANARY and reason == nil)
	for _, line in ipairs(Logger.ring_buffer_snapshot()) do assert(not line:find(CANARY, 1, true)) end
end)

check("native successful empty output remains a successful receipt", function()
	local accepted, output, reason = fresh_shell().exec_checked("printf ''")
	assert(accepted and output == "" and reason == nil)
end)

check("native nonzero completion preserves its status without copying stdout into logs", function()
	local shell = fresh_shell()
	local accepted, output, reason = shell.exec_checked("printf '%s' " .. shell.quote(CANARY) .. "; exit 7")
	assert(not accepted and output == CANARY and reason:find("status 7", 1, true))
	for _, line in ipairs(Logger.ring_buffer_snapshot()) do assert(not line:find(CANARY, 1, true)) end
end)

check("native receipt transmitter failure cannot certify complete stdout", function()
	-- This controlled native utility emits all bytes through the real cat and
	-- then exits 17. No Lua pipe is mocked: LuaJIT discards that child's status,
	-- so a complete leading frame alone cannot certify capture completion.
	local directory = assert(uv.fs_mkdtemp("/tmp/ergopti-capture-receipt-XXXXXX"))
	local path = directory .. "/cat"
	local descriptor = assert(uv.fs_open(path, "w", 448))
	assert(uv.fs_write(descriptor, '#!/bin/sh\n/bin/cat "$@" || exit $?\nexit 17\n', 0))
	assert(uv.fs_close(descriptor))
	local previous_path = assert(os.getenv("PATH"))
	assert(uv.os_setenv("PATH", directory .. ":" .. previous_path))
	local ok, err = xpcall(function()
		local accepted, output, reason = fresh_shell().exec_checked("printf '%s' " .. CANARY)
		assert(not accepted, "failed native receipt transmitter certified success")
		assert(output == CANARY, "completed caller bytes were lost on transmitter failure")
		assert(type(reason) == "string" and reason ~= "", "transmitter failure lost its diagnostic")
		assert(not reason:find(CANARY, 1, true), "transmitter failure exposed caller bytes")
	end, debug.traceback)
	assert(uv.os_setenv("PATH", previous_path))
	assert(uv.fs_unlink(path))
	assert(uv.fs_rmdir(directory))
	assert(ok, err)
end)

print(string.format("Native shell capture error receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
