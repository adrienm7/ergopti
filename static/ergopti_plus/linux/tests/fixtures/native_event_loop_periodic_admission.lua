--- tests/fixtures/native_event_loop_periodic_admission.lua
--- ==============================================================================
--- MODULE: Native Event Loop Periodic Duration Admission Regression
--- DESCRIPTION:
--- Exercises actual libuv periodic timers with finite foreign watchdogs, exact
--- cleanup ownership and healthy retries after refused nonfinite durations.
--- Native handles, callbacks and clocks are real; no physical input is needed.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_event_loop_periodic_admission%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. package.path
local uv = require("luv")
local checks, failures = 0, 0
local function fresh()
	package.loaded["adapters.event_loop"] = nil
	return require("adapters.event_loop")
end
local function resources()
	local list = {}
	uv.walk(function(handle) list[#list + 1] = handle end)
	return list
end
local function drain() for _ = 1, 4 do uv.run("nowait") end end
local function exact_foreign(handle)
	drain()
	local list = resources()
	assert(#list == 1 and list[1] == handle, "owned loop handle leaked or foreign handle lost")
	assert(not uv.is_closing(handle), "foreign watchdog closed by event loop")
end
local function execute(loop, period, milliseconds, idle_only)
	local foreign = assert(uv.new_timer())
	local watchdog, idle, periodic = false, 0, 0
	assert(uv.timer_start(foreign, milliseconds or 25, 0, function()
		watchdog = true
		loop.stop()
	end))
	local start = uv.hrtime()
	local ok, err = pcall(loop.run, { periodSec = period,
		onIdle = function() idle = idle + 1; if idle_only then loop.stop() end end,
		onPeriodic = not idle_only and function() periodic = periodic + 1; if period ~= period or period == math.huge or period == -math.huge or math.abs(tonumber(period) or 0) >= 1e12 then return end; loop.stop() end })
	local elapsed = (uv.hrtime() - start) / 1e6
	assert(not loop.isRunning(), "running state retained after return")
	exact_foreign(foreign)
	uv.timer_stop(foreign); uv.close(foreign); drain()
	assert(#resources() == 0 and not uv.loop_alive(), "fixture handles leaked")
	return { ok = ok, err = tostring(err), idle = idle, periodic = periodic, watchdog = watchdog,
		elapsed = elapsed }
end
local function check(name, fn)
	checks = checks + 1
	local ok, err = xpcall(fn, debug.traceback)
	if ok then print("PASS " .. name) else failures = failures + 1; print("FAIL " .. name .. ": " .. err) end
end
for _, entry in ipairs({ {"NaN", 0/0}, {"positive infinity", math.huge}, {"negative infinity", -math.huge},
	{"positive converted overflow", 1e308}, {"negative converted overflow", -1e308} }) do
	check("finite periodic admission: " .. entry[1], function()
		local loop = fresh()
		local receipt = execute(loop, entry[2])
		print(string.format("OBS %s accepted=%s idle=%d periodic=%d watchdog=%s elapsed=%.3f error=%s",
			entry[1], tostring(receipt.ok), receipt.idle, receipt.periodic, tostring(receipt.watchdog), receipt.elapsed,
			receipt.err))
		local recovery = execute(loop, 0.001)
		assert(recovery.ok and recovery.periodic == 1 and not recovery.watchdog, "healthy restart failed")
		assert(not receipt.ok and receipt.idle == 0 and receipt.periodic == 0 and not receipt.watchdog,
			"nonfinite source or converted period admitted native callbacks")
	end)
end
for _, entry in ipairs({ {"zero clamp", 0}, {"negative clamp", -0.005}, {"fractional clamp", 0.0005},
	{"fractional seconds", 0.0055}, {"numeric string", "0.002"}, {"default", false}, {"nonnumeric default", "not a number"} }) do
	check("healthy periodic control: " .. entry[1], function()
		local value = entry[2]
		if value == false then value = nil end
		local receipt = execute(fresh(), value, 400)
		print(string.format("OBS %s accepted=%s idle=%d periodic=%d watchdog=%s elapsed=%.3f", entry[1], tostring(receipt.ok), receipt.idle, receipt.periodic, tostring(receipt.watchdog), receipt.elapsed))
		assert(receipt.ok and receipt.periodic == 1 and not receipt.watchdog)
	end)
end
for _, entry in ipairs({ {"NaN", 0/0}, {"infinity", math.huge}, {"converted overflow", 1e308} }) do
	check("idle-only ignores unused periodic duration: " .. entry[1], function()
		local receipt = execute(fresh(), entry[2], 25, true)
		assert(receipt.ok and receipt.idle == 1 and receipt.periodic == 0 and not receipt.watchdog)
	end)
end
check("finite large duration remains admitted with bounded external stop", function()
	local receipt = execute(fresh(), 1e12)
	assert(receipt.ok and receipt.idle > 0 and receipt.periodic == 0 and receipt.watchdog)
end)
print(string.format("Native periodic duration admission: %d checks, %d failures", checks, failures))
assert(checks == 16)
os.exit(failures == 0 and 0 or 1)
