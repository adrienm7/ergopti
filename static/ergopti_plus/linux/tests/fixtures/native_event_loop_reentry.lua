--- tests/fixtures/native_event_loop_reentry.lua
--- ==============================================================================
--- MODULE: Native Event Loop Reentry Ownership Regression
--- DESCRIPTION:
--- Exercises real libuv callback reentry and exact handle retirement after stop,
--- including throwing callbacks and healthy sequential restarts. One final case
--- explicitly simulates a refused start receipt after real native activation.
--- No physical input, graphical session or process signal is involved.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_event_loop_reentry%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. package.path
local uv = require("luv")
local checks, failures = 0, 0

local function fresh_loop()
	package.loaded["adapters.event_loop"] = nil
	return require("adapters.event_loop")
end

local function handle_count()
	local count = 0
	uv.walk(function() count = count + 1 end)
	return count
end

local function drain()
	for _ = 1, 4 do uv.run("nowait") end
end

assert(handle_count() == 0, "native fixture must start with exclusive loop ownership")

local function check(name, test)
	checks = checks + 1
	local loop = fresh_loop()
	local foreign = assert(uv.new_timer())
	assert(uv.timer_start(foreign, 10000, 10000, function() end) == 0)
	uv.unref(foreign)
	local ok, err = xpcall(function()
		test(loop)
		drain()
		assert(not loop.isRunning(), "run retained its running state after return")
		assert(uv.is_active(foreign) and not uv.is_closing(foreign), "run stole foreign timer ownership")
		assert(handle_count() == 1, "run lost an owned native handle before cleanup")
	end, debug.traceback)
	-- This child owns all handles. Cleanup follows the exact count assertion;
	-- closing a leaked handle here cannot hide a failing ownership observation.
	loop.stop()
	uv.walk(function(handle) if not uv.is_closing(handle) then uv.close(handle) end end)
	drain()
	assert(handle_count() == 0 and not uv.loop_alive(), "native fixture cleanup retained a handle")
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, callback_source in ipairs({ "idle", "periodic", "deferred" }) do
	for _, stopping in ipairs({ false, true }) do
		check(callback_source .. " reentry while " .. (stopping and "stopping" or "running"), function(loop)
			local outer, nested = 0, 0
			local function callback()
				outer = outer + 1
				if stopping then loop.stop() end
				loop.run({ onIdle = function() nested = nested + 1; loop.stop() end })
				loop.stop()
			end
			local options = {}
			if callback_source == "idle" then options.onIdle = callback
			elseif callback_source == "periodic" then options.onPeriodic, options.periodSec = callback, 0.001
			else assert(loop.defer(callback)); options.onIdle = function() end end
			loop.run(options)
			assert(outer == 1 and nested == 0, "callback reentry crossed live run ownership")
		end)
	end
end

check("throwing callback after stopping reentry", function(loop)
	local calls = 0
	loop.run({ onIdle = function()
		calls = calls + 1
		loop.stop()
		loop.run({ onIdle = function() error("nested callback must not be admitted") end })
		error("owned callback failure after stop")
	end })
	assert(calls == 1, "throwing callback was replayed")
end)

check("healthy sequential runs after completed cleanup", function(loop)
	local calls = 0
	for _ = 1, 3 do
		loop.run({ onIdle = function() calls = calls + 1; loop.stop() end })
		drain()
		assert(handle_count() == 1, "completed run retained its native handles")
	end
	assert(calls == 3, "a completed run must release the reentry guard")
end)

check("simulated start receipt refusal after native activation permits retry", function(loop)
	local native_start = uv.idle_start
	uv.idle_start = function(handle, callback)
		assert(native_start(handle, callback) == 0)
		return nil, "simulated start receipt refusal"
	end
	local ok, err = pcall(loop.run, { onIdle = function() loop.stop() end })
	uv.idle_start = native_start
	assert(not ok and tostring(err):find("simulated start receipt refusal", 1, true), "refusal did not propagate")
	drain()
	assert(handle_count() == 1 and not loop.isRunning(), "refused activation retained run ownership")
	local calls = 0
	loop.run({ onIdle = function() calls = calls + 1; loop.stop() end })
	assert(calls == 1, "native startup rollback left the run guard wedged")
end)

assert(checks == 9, "native reentry fixture lost a case")
print(string.format("Native event loop reentry: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
