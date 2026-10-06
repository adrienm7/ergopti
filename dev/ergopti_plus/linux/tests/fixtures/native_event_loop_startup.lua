--- tests/fixtures/native_event_loop_startup.lua
--- ==============================================================================
--- MODULE: Native Event Loop Startup Ownership Regression
--- DESCRIPTION:
--- Constructor refusals and raised start failures are explicitly simulated.
--- Timer invalidation closes a real timer before its native EINVAL receipt.
--- Every acquired handle, foreign-owner boundary and recovery run uses actual
--- libuv; no ordinary production allocation failure is claimed.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_event_loop_startup%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. package.path
local uv = require("luv")
local failures = 0
local cases = { "idle nil", "idle raised", "idle start raised", "timer nil", "timer raised", "timer start raised", "timer invalidated" }

for _, refusal in ipairs(cases) do
	package.loaded["adapters.event_loop"] = nil
	local loop = require("adapters.event_loop")
	local new_idle, new_timer, idle_start, timer_start = uv.new_idle, uv.new_timer, uv.idle_start, uv.timer_start
	local owned, receipt = {}, nil
	local foreign = new_timer()
	timer_start(foreign, 10000, 10000, function() end)
	uv.unref(foreign)
	uv.new_idle = function()
		if refusal == "idle nil" then return nil end
		if refusal == "idle raised" then error("simulated idle allocation refusal") end
		local handle = new_idle()
		owned[#owned + 1] = handle
		return handle
	end
	uv.new_timer = function()
		if refusal == "timer nil" then return nil end
		if refusal == "timer raised" then error("simulated timer allocation refusal") end
		local handle = new_timer()
		owned[#owned + 1] = handle
		return handle
	end
	uv.idle_start = function(handle, callback)
		local result = idle_start(handle, callback)
		if refusal == "idle start raised" then error("simulated idle start refusal") end
		return result
	end
	uv.timer_start = function(handle, ...)
		if refusal == "timer invalidated" then
			uv.close(handle) -- Simulated invalidation, native timer and receipt.
			local result, message, code = timer_start(handle, ...)
			receipt = { result, message, code }
			return result, message, code
		end
		local result = timer_start(handle, ...)
		if refusal == "timer start raised" then error("simulated timer start refusal") end
		return result
	end
	local ok, err = xpcall(function()
		local ran, reason = pcall(loop.run, { onIdle = function() loop.stop() end,
			onPeriodic = function() end, periodSec = 0.001 })
		assert(not ran and type(reason) == "string", "refused startup must raise instead of reporting a complete run")
		assert(not loop.isRunning(), "failed startup retained running state")
		for _, handle in ipairs(owned) do assert(uv.is_closing(handle), "failed startup retained a native handle") end
		assert(not uv.is_closing(foreign) and uv.is_active(foreign), "startup rollback retired another owner's timer")
		if receipt then assert(receipt[1] == nil and receipt[3] == "EINVAL", "fixture did not reach native timer refusal") end
		uv.new_idle, uv.new_timer, uv.idle_start, uv.timer_start = new_idle, new_timer, idle_start, timer_start
		local callbacks = 0
		loop.run({ onIdle = function() callbacks = callbacks + 1; loop.stop() end })
		assert(callbacks == 1 and not loop.isRunning(), "failed startup made the next run unusable")
	end, debug.traceback)
	uv.new_idle, uv.new_timer, uv.idle_start, uv.timer_start = new_idle, new_timer, idle_start, timer_start
	-- Cleanup cannot hide the assertions above, and owns only this fixture's handles.
	loop.stop()
	for _, handle in ipairs(owned) do if not uv.is_closing(handle) then uv.close(handle) end end
	uv.close(foreign)
	for _ = 1, 4 do uv.run("nowait") end
	assert(not uv.loop_alive(), "startup fixture left active native handles")
	if ok then print("PASS " .. refusal .. " (simulated refusal; native ownership cleanup and recovery)")
	else failures = failures + 1; io.stderr:write("FAIL " .. refusal .. ": " .. tostring(err) .. "\n") end
end
print(string.format("Native event startup ownership: %d checks, %d failures", #cases, failures))
os.exit(failures == 0 and 0 or 1)
