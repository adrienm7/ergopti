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
local cases = { "pump nil", "pump raised", "pump start raised", "timer nil", "timer raised", "timer start raised", "timer invalidated",
	"prepare nil", "prepare false", "prepare raised", "prepare start nil", "prepare start false", "prepare start raised" }

for _, refusal in ipairs(cases) do
	package.loaded["adapters.event_loop"] = nil
	local loop = require("adapters.event_loop")
	local new_idle, new_timer, idle_start, timer_start = uv.new_idle, uv.new_timer, uv.idle_start, uv.timer_start
	local owned, receipt = {}, nil
	local roles = {}
	local new_prepare, prepare_start = uv.new_prepare, uv.prepare_start
	local foreign = new_timer()
	timer_start(foreign, 10000, 10000, function() end)
	uv.unref(foreign)
	uv.new_prepare = function()
		if refusal == "prepare nil" then return nil end
		if refusal == "prepare false" then return false end
		if refusal == "prepare raised" then error("simulated prepare allocation refusal") end
		local handle = new_prepare()
		owned[#owned + 1] = handle
		roles[handle] = "prepare"
		return handle
	end
	uv.prepare_start = function(handle, callback)
		assert(roles[handle] == "prepare", "prepare start must target the real prepare handle")
		local result = prepare_start(handle, callback)
		if refusal == "prepare start raised" then error("simulated prepare start refusal") end
		if refusal == "prepare start nil" then return nil, "simulated prepare start refusal" end
		if refusal == "prepare start false" then return false, "simulated prepare start refusal" end
		return result
	end
	uv.new_idle = function()
		if refusal == "pump nil" then return nil end
		if refusal == "pump raised" then error("simulated pump allocation refusal") end
		local handle = new_idle()
		owned[#owned + 1] = handle
		roles[handle] = "pump"
		return handle
	end
	uv.new_timer = function()
		local role = #owned == 0 and "pump" or "timer"
		if refusal == role .. " nil" then return nil end
		if refusal == role .. " raised" then error("simulated " .. role .. " allocation refusal") end
		local handle = new_timer()
		owned[#owned + 1] = handle
		roles[handle] = role
		return handle
	end
	uv.idle_start = function(handle, callback)
		local result = idle_start(handle, callback)
		if refusal == "pump start raised" then error("simulated pump start refusal") end
		return result
	end
	uv.timer_start = function(handle, delay, interval, callback)
		local role = delay == 0 and interval == 1 and "pump" or "timer"
		assert(roles[handle] == role, "native timer allocation and start roles must agree")
		if refusal == "timer invalidated" and role == "timer" then
			uv.close(handle) -- Simulated invalidation, native timer and receipt.
			local result, message, code = timer_start(handle, delay, interval, callback)
			receipt = { result, message, code }
			return result, message, code
		end
		local result = timer_start(handle, delay, interval, callback)
		if refusal == role .. " start raised" then error("simulated " .. role .. " start refusal") end
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
		uv.new_prepare, uv.prepare_start = new_prepare, prepare_start
		local callbacks = 0
		loop.run({ onIdle = function() callbacks = callbacks + 1; loop.stop() end })
		assert(callbacks == 1 and not loop.isRunning(), "failed startup made the next run unusable")
	end, debug.traceback)
	uv.new_idle, uv.new_timer, uv.idle_start, uv.timer_start = new_idle, new_timer, idle_start, timer_start
	uv.new_prepare, uv.prepare_start = new_prepare, prepare_start
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
