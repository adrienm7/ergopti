--- tests/unit/modules/test_program_literal_native.lua

--- Mandatory actual POSIX proof: private scripts run in a fresh Linux LuaJIT
--- subprocess, so no unit fixture's module cache can replace their native ports.
local helpers = require("tests.helpers")
local Native = require("luv")

local function run_fixture(fixture, expected)
	local path = require("infra.paths").driver_root() .. "/tests/hardware/" .. fixture
	local code = "package.path = " .. string.format("%q", package.path)
		.. "; require('compat.utf8').install(); dofile(" .. string.format("%q", path) .. ")"
	local stdout, stderr = assert(Native.new_pipe(false)), assert(Native.new_pipe(false))
	local output, errors, status, signal = "", "", nil, nil
	local ended, closed, timed_out = 0, 0, false
	local process, reason = Native.spawn("luajit", {
		args = { "-e", code }, stdio = { nil, stdout, stderr },
	}, function(value, terminated) status, signal = value, terminated end)
	if not process then
		Native.close(stdout); Native.close(stderr); Native.run("nowait")
		error("mandatory literal fixture requires the installed Linux LuaJIT target: " .. tostring(reason))
	end
	local function reader(stream)
		return function(err, bytes)
			if err then errors = errors .. tostring(err) end
			if bytes then
				if stream == "stdout" then output = output .. bytes else errors = errors .. bytes end
			else ended = ended + 1 end
		end
	end
	local started_stdout = Native.read_start(stdout, reader("stdout"))
	local started_stderr = Native.read_start(stderr, reader("stderr"))
	-- The child owns its subreaper and bounded native cleanup. The outer
	-- deadline exceeds all fixture waits; only this acquired process handle
	-- is signalled if its acknowledgement still fails to arrive.
	local deadline = Native.hrtime() + 30000000000
	while (status == nil or ended ~= 2) and Native.hrtime() < deadline do
		Native.run("nowait"); Native.sleep(1)
	end
	if status == nil then
		timed_out = true
		process:kill("sigkill")
		local cleanup = Native.hrtime() + 3000000000
		while status == nil and Native.hrtime() < cleanup do Native.run("nowait"); Native.sleep(1) end
	end
	Native.read_stop(stdout); Native.read_stop(stderr)
	Native.close(stdout, function() closed = closed + 1 end)
	Native.close(stderr, function() closed = closed + 1 end)
	if status ~= nil then Native.close(process, function() closed = closed + 1 end) end
	local cleanup = Native.hrtime() + 3000000000
	while closed ~= 3 and Native.hrtime() < cleanup do Native.run("nowait"); Native.sleep(1) end
	helpers.assert_eq(started_stdout, 0, "the exact native stdout pipe must start")
	helpers.assert_eq(started_stderr, 0, "the exact native stderr pipe must start")
	helpers.assert_eq(timed_out, false, "the mandatory native literal fixture exceeded its deadline")
	helpers.assert_eq(status, 0, errors)
	helpers.assert_eq(signal, 0, "the owned native fixture must exit normally")
	helpers.assert_eq(ended, 2, "both exact native fixture streams must retire")
	helpers.assert_eq(closed, 3, "the exact fixture process and pipes must physically close")
	helpers.assert_eq(errors, "", "the private native fixture must retain empty stderr")
	local checks = 0
	for line in output:gmatch("[^\n]+") do if line:match("^PASS ") then checks = checks + 1 end end
	helpers.assert_eq(checks, 1, "mandatory native fixture discovery must acknowledge one nonempty check")
	helpers.assert_eq(output,
		expected,
		"the native literal proof must emit its independently declared single receipt")
end

helpers.describe("private native program literal receipts", function()
	helpers.it("qualifies independent literal argv and physical retirement (program106-literal-native)", function()
		run_fixture("run_program_literal_receipts.lua",
			"PASS private native literal argv, executable symlink, discarded streams and exit 37\n")
	end)

	helpers.it("qualifies discovered providers through actual native execution and retirement (program106-provider-native)", function()
		run_fixture("run_program_provider_receipts.lua",
			"PASS native provider discovery, literal sh/python/executable argv, exit 37, refusal and cancellation retirement\n")
	end)
end)
