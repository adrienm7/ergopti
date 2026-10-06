--- tests/hardware/run_event_loop_stop_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Event Loop Stop Receipts
--- DESCRIPTION:
--- Exercises production stop() while actual sockets, inotify or repeating
--- timers remain owned by another component. A finite watchdog makes the old
--- deadlock reproducible without hanging the harness. Stop must return before
--- that watchdog and leave foreign resources active for their own cleanup.
--- No libuv function is mocked and no physical input or graphics is required.
--- ==============================================================================

local uv = require("luv")
local Loop = require("adapters.event_loop")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-event-stop-XXXXXX"))
local checks, failures = 0, 0
local owned = {}

local function retain(handle)
	owned[#owned + 1] = assert(handle)
	return handle
end

local function close(handle)
	if not uv.is_closing(handle) then uv.close(handle) end
end

local function foreign_handle(kind)
	if kind == "tcp" then
		local handle = retain(uv.new_tcp())
		assert(uv.tcp_bind(handle, "127.0.0.1", 0))
		assert(uv.listen(handle, 1, function() end))
		return handle
	elseif kind == "fs_event" then
		local handle = retain(uv.new_fs_event())
		assert(uv.fs_event_start(handle, root, {}, function() end))
		return handle
	else
		local handle = retain(uv.new_timer())
		assert(uv.timer_start(handle, 1, 1, function() end))
		return handle
	end
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	Loop.stop()
	for _, handle in ipairs(owned) do close(handle) end
	owned = {}
	uv.run("nowait")
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, kind in ipairs({ "tcp", "fs_event", "timer" }) do
	for _, source in ipairs({ "idle", "periodic", "deferred" }) do
		check(source .. " stop leaves foreign " .. kind .. " active", function()
			local foreign = foreign_handle(kind)
			local watchdog = retain(uv.new_timer())
			local expired, stops = false, 0
			assert(uv.timer_start(watchdog, 200, 0, function()
				expired = true
				close(foreign)
				close(watchdog)
			end))
			local function stop()
				stops = stops + 1
				Loop.stop()
			end
			local options = {}
			if source == "idle" then options.onIdle = stop
			elseif source == "periodic" then options.onPeriodic, options.periodSec = stop, 0.001
			else
				assert(Loop.defer(stop))
				options.onIdle = function() end
			end
			Loop.run(options)
			assert(not expired, "stop waited for the foreign resource's watchdog retirement")
			assert(stops == 1 and not Loop.isRunning(), "stop did not settle loop ownership exactly once")
			assert(uv.is_active(foreign) and not uv.is_closing(foreign), "stop stole foreign resource ownership")
			close(watchdog)
			uv.run("nowait")
			local foreign_count, others = 0, 0
			uv.walk(function(handle)
				if handle == foreign then foreign_count = foreign_count + 1 else others = others + 1 end
			end)
			assert(foreign_count == 1 and others == 0, "event loop retained its own handles after return")
		end)
	end
	check("loop restarts around the same foreign " .. kind, function()
		local foreign = foreign_handle(kind)
		local watchdog = retain(uv.new_timer())
		local expired, stops = false, 0
		assert(uv.timer_start(watchdog, 200, 0, function()
			expired = true
			close(foreign)
			close(watchdog)
		end))
		for _ = 1, 2 do
			Loop.run({ onIdle = function() stops = stops + 1; Loop.stop() end })
			assert(not expired and uv.is_active(foreign), "restart depends on foreign cleanup")
		end
		assert(stops == 2 and not Loop.isRunning())
	end)
end

check("stop outside run does not stop another owner's native loop", function()
	local completed = false
	local timer = retain(uv.new_timer())
	assert(uv.timer_start(timer, 1, 0, function() completed = true; close(timer) end))
	Loop.stop()
	Loop.stop()
	uv.run()
	assert(completed, "an inactive adapter interrupted the foreign owner's uv.run")
end)

check("ordinary stop returns and retires only its own handles", function()
	local stops = 0
	Loop.run({ onIdle = function() stops = stops + 1; Loop.stop() end })
	uv.run("nowait")
	assert(stops == 1 and not Loop.isRunning() and not uv.loop_alive())
end)

assert(uv.fs_rmdir(root))
local remaining = 0
uv.walk(function() remaining = remaining + 1 end)
assert(remaining == 0 and not uv.loop_alive(), "fixture leaked native ownership")
print(string.format("Native event loop stop receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
