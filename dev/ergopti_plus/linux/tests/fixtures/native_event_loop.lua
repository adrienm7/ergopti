--- tests/fixtures/native_event_loop.lua

--- ==============================================================================
--- MODULE: Native Event Loop Integration Fixture
--- DESCRIPTION:
--- Exercises the real installed libuv loop in a separate process so unrelated
--- suite handles cannot keep its shutdown alive. The independent deadline is
--- unreferenced and every fixture-owned handle is closed before reporting.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_event_loop%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path

local luv = require("luv")
local native = require("adapters.event_loop")
local idle, periodic, leaked = 0, 0, 0
local timed_out = false
local watchdog = luv.new_timer()
luv.timer_start(watchdog, 2000, 0, function()
	timed_out = true
	native.stop()
end)
-- The deadline must not hold a successfully stopped loop open.
luv.unref(watchdog)

local ok, err = pcall(native.run, {
	onIdle = function()
		idle = idle + 1
		if periodic > 0 then native.stop() end
	end,
	onPeriodic = function()
		periodic = periodic + 1
		if idle > 0 then native.stop() end
	end,
	periodSec = 0.001,
})

native.stop()
luv.timer_stop(watchdog)
luv.close(watchdog)
luv.walk(function(handle)
	if handle ~= watchdog and not luv.is_closing(handle) then
		leaked = leaked + 1
		luv.close(handle)
	end
end)
luv.run("nowait")
assert(ok, tostring(err))
assert(not timed_out, "native callbacks exceeded their independent deadline")
assert(leaked == 0, "native loop leaked an owned handle")
assert(native.HAS_LUV and idle > 0 and periodic == 1, "native idle and timer callbacks must both run")
assert(not native.isRunning(), "native loop must finish stopped")
print("Native luv integration passed: idle and timer dispatch, bounded shutdown, no leaked handles.")

-- Real libuv children install SIGCHLD handling. Their exits interrupt the
-- caller's blocking nanosleep without any mocked FFI or signal delivery.
local children, exits, abnormal_exits = {}, 0, 0
local wait_ok, wait_error = xpcall(function()
	for _, delay in ipairs({ "0.05", "0.10", "0.15" }) do
		local process, pid
		process, pid = luv.spawn("/bin/sleep", { args = { delay } }, function(code, signal)
			exits = exits + 1
			if code ~= 0 or signal ~= 0 then abnormal_exits = abnormal_exits + 1 end
			luv.close(process)
		end)
		assert(process and pid, "native wait fixture could not start its child")
		children[#children + 1] = pid
	end
	local cpu_start, wall_start = os.clock(), luv.hrtime()
	local completed = native.sleep_ms(400)
	local elapsed_ms = (luv.hrtime() - wall_start) / 1000000
	local cpu_ms = (os.clock() - cpu_start) * 1000
	assert(completed and elapsed_ms >= 390 and elapsed_ms < 3000,
		string.format("SIGCHLD shortened a completed 400 ms wait to %.2f ms", elapsed_ms))
	assert(cpu_ms < 80, string.format("native wait consumed %.2f ms CPU instead of sleeping", cpu_ms))
	-- Requiring zombie states before dispatch proves the children actually
	-- exited during the measured wait, even on a heavily loaded runner.
	for _, pid in ipairs(children) do
		local file = assert(io.open("/proc/" .. pid .. "/stat", "r"))
		local stat = file:read("*a")
		file:close()
		assert(stat:match("^%d+ %(.+%) (%a) ") == "Z", "fixture child did not exit during the measured wait")
	end
	print(string.format("Native SIGCHLD wait passed: %.2f ms wall, %.2f ms CPU.", elapsed_ms, cpu_ms))
end, debug.traceback)
-- Retire every owned child even when reproducing the unfixed adapter.
for _, pid in ipairs(children) do luv.kill(pid, "sigkill") end
luv.run()
assert(not luv.loop_alive(), "native wait fixture left child or pipe handles active")
assert(wait_ok, wait_error)
assert(exits == #children and exits == 3, "every native child must be reaped exactly once")
assert(abnormal_exits == 0, "native wait fixture child did not exit normally")


-- An actual quit handler and a consumed tap can be queued by one keyboard
-- pump. Native stop must retire the pending tap before its executor is called.
local tap_path = os.tmpname()
local consumer_calls, close_callback, consumer_timeout = {}, false, false
local consumer_watchdog = assert(luv.new_timer())
assert(luv.timer_start(consumer_watchdog, 2000, 0, function()
	consumer_timeout = true
	native.stop()
end))
luv.unref(consumer_watchdog)
local consumer_ok, consumer_error = xpcall(function()
	local file = assert(io.open(tap_path, "w"))
	assert(file:write('[shortcuts.tap_keys]\nnumber_row_left="screen_capture"\n'))
	assert(file:close())
	package.loaded["infra.config_paths"] = { config = function() return tap_path end }
	package.loaded["modules.gestures.manager"] = {
		is_assignable = function(id) return id == "screen_capture" end,
		execute_action = function(action) consumer_calls[#consumer_calls + 1] = action end,
	}
	local controller = require("modules.shortcuts.script_actions").new({
		reset = function() end, reload = function() end,
		quit = function()
			consumer_calls[#consumer_calls + 1] = "script_quit"
			local closing = assert(luv.new_timer())
			luv.close(closing, function() close_callback = true end)
			native.stop()
		end,
	})
	local tap = require("modules.shortcuts.tap_keys")
	tap.init({ is_active = function() return not controller.is_paused() end, defer = native.defer })
	assert(native.defer(controller.handlers.script_quit))
	assert(tap.on_key({ code = 41, mods = {} }), "actual assigned tap must be consumed and queued")
	native.run({ onIdle = function() end })
	assert(table.concat(consumer_calls, ",") == "script_quit", "the tap executor ran after native quit")
	local restarted = 0
	native.run({ onIdle = function() restarted = restarted + 1; native.stop() end })
	assert(restarted == 1 and #consumer_calls == 1, "native restart replayed stopped actions")
	assert(close_callback, "stop must still drain native close acknowledgements")
end, debug.traceback)
native.stop()
os.remove(tap_path)
luv.timer_stop(consumer_watchdog)
luv.close(consumer_watchdog)
luv.run("nowait")
assert(consumer_ok, consumer_error)
assert(not consumer_timeout, "native shortcut stop exceeded its independent deadline")
assert(not luv.loop_alive(), "native shortcut stop retained handles")
print("Native queued shortcut stop passed: quit cancels later tap, restart stays clean, close callbacks drain.")
