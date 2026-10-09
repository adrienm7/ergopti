--- tests/unit/platform/remap/test_layout_poll_async.lua

--- ==============================================================================
--- MODULE: Regression — input-source refreshes read asynchronously (HS-197)
--- DESCRIPTION:
--- Input-source notifications and the Sequoia fallback poll must never call a
--- synchronous `defaults read` subprocess on Hammerspoon's main run loop. When
--- cfprefsd is slow or contended that freezes all hotkey handling and keystroke
--- delivery.
---
--- Notification and poll paths both enter one watchdog-backed ShellRunner read,
--- guarded by _layout_poll_pending so concurrent refreshes cannot pile up.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("karabiner.watchers: layout refresh is async (HS-197)", function()
	local function read_src()
		-- Selected by a declaration unique to platform/remap/watchers.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function parse_layout_name")
		helpers.assert_true(src ~= nil, "platform/remap/watchers.lua source must be locatable")
		if not src then return end
		return src
	end

	helpers.it("the poll calls the async read, not the synchronous one", function()
		local src = read_src()
		helpers.assert_true(src:find("read_layout_async(function(current)", 1, true) ~= nil,
			"the doEvery poll must read via read_layout_async (off the main loop)")
		helpers.assert_true(src:find("_layout_poll_pending", 1, true) ~= nil,
			"the poll must guard against piling up concurrent async reads")
		helpers.assert_true(src:find("local current = read_current_layout_from_hitoolbox()", 1, true) == nil,
			"the poll must NOT call the synchronous read_current_layout_from_hitoolbox() any more")
		helpers.assert_true(src:find("read_current_layout_from_hitoolbox", 1, true) == nil,
			"notification, seed, and poll must not retain a synchronous HIToolbox reader")
		helpers.assert_true(src:find('run_layout_refresh("notification")', 1, true) ~= nil,
			"the notification must enter the unified async refresh transaction")
		helpers.assert_true(src:find('run_layout_refresh, "poll"', 1, true) ~= nil,
			"the fallback timer must enter that same transaction")
	end)

	helpers.it("read_layout_async uses the ShellRunner adapter (not a synchronous hs.execute)", function()
		local src = read_src()
		local fn = src:match("local function read_layout_async.-\nend")
		helpers.assert_true(fn ~= nil, "read_layout_async must exist")
		helpers.assert_true(fn:find("ShellRunner.spawn", 1, true) ~= nil,
			"read_layout_async must spawn the read via the ShellRunner adapter")
		helpers.assert_true(fn:find("hs.execute", 1, true) == nil,
			"read_layout_async must not use a synchronous hs.execute")
	end)

	-- H-2 regression: the handle returned by ShellRunner.spawn() must be captured
	-- and .start() called — otherwise the subprocess never launches, the callback
	-- never fires, and _layout_poll_pending leaks true forever.
	helpers.it("read_layout_async captures the handle and calls handle.start() (H-2)", function()
		local src = read_src()
		local fn = src:match("local function read_layout_async.-\nend")
		helpers.assert_true(fn ~= nil, "read_layout_async must exist")
		-- The handle must be assigned (not just ShellRunner.spawn discarded)
		helpers.assert_true(fn:find("local handle", 1, true) ~= nil or
			fn:find("= ShellRunner%.spawn") ~= nil,
			"read_layout_async must capture the handle returned by ShellRunner.spawn()")
		-- .start() must be called on the handle
		helpers.assert_true(fn:find("handle%.start") ~= nil or fn:find("handle.start", 1, true) ~= nil,
			"read_layout_async must call handle.start() to actually launch the subprocess")
	end)

	helpers.it("read_layout_async handle.start() is called (behaviour spy — H-2)", function()
		-- Stub ShellRunner at module level so watchers.lua gets it on require
		local started = false
		local poll_callback = nil
		package.loaded["adapters.shell_runner"] = {
			spawn = function(_, _, on_done)
				-- Return a fake handle that records whether .start() was invoked
				return {
					start     = function() started = true; return true end,
					terminate = function() return true end,
				}
			end,
			_active_tasks = {},
		}
		package.loaded["adapters.timer_scheduler"] = {
			after = function(_delay, callback)
			return { callback = callback, fired = false }, true
			end,
			cancel = function() return true end,
		}
		-- Also clear watchers so it re-requires with the stub
		package.loaded["platform.remap.watchers"] = nil

		local watchers = helpers.load_with_stubs("platform.remap.watchers", {
			timer    = { new = function(_delay, callback)
					poll_callback = callback
					local handle = { live = false }
					function handle:start() self.live = true; return self end
					function handle:stop() self.live = false; return self end
					function handle:running() return self.live end
					return handle
				end,
			          doAfter  = function() return { stop = function() end } end },
			-- load_with_stubs replaces hs.keycodes wholesale (shallow key
			-- overwrite, not a merge — see helpers/init.lua), so this override
			-- must carry its own .map. watchers.lua calls
			-- Keycodes.to_name(Keycodes.F17_CYCLE_WINDOWS) at module load time
			-- (top-level KEYCODE_F17_NAME assignment), which does
			-- `for _, code in pairs(hs.keycodes.map)` — without .map here that
			-- pairs() crashes on nil before this test's own assertions run.
			-- F17_CYCLE_WINDOWS = 64 in _shared/lua/keycodes/init.lua.
			keycodes = { inputSourceChanged = function() end, currentLayout = function() return "ABC" end,
			          map = { f17 = 64 } },
			execute  = function() return "", true end,
		})

		helpers.assert_eq(watchers.start_input_source_watcher(function() end), true)
		helpers.assert_true(type(poll_callback) == "function",
			"the fallback poll callback must be installed before it can exercise the read")
		poll_callback()
		helpers.assert_true(started,
			"a real fallback poll tick must call the exact ShellRunner handle's start()")
	end)

	helpers.it("notification and poll share one asynchronous read owner (HS-197)", function()
		local state = {
			debounces = {},
			execute_calls = 0,
			read_callbacks = {},
			spawn_calls = 0,
			watchdogs = {},
		}
		local notification_callback
		local poll_callback
		package.loaded["adapters.input_source_broker"] = {
			subscribe = function(_id, callback)
				notification_callback = callback
				return true
			end,
			unsubscribe = function() return true end,
		}
		package.loaded["adapters.shell_runner"] = {
			spawn = function(executable, args, on_done)
				state.spawn_calls = state.spawn_calls + 1
				state.executable = executable
				state.args = args
				state.read_callbacks[#state.read_callbacks + 1] = on_done
				return {
					start = function() return true end,
					terminate = function() return true end,
				}
			end,
			_active_tasks = {},
		}
		package.loaded["adapters.timer_scheduler"] = {
			after = function(_delay, callback)
				local watchdog = { callback = callback, fired = false }
				state.watchdogs[#state.watchdogs + 1] = watchdog
				return watchdog, true
			end,
			cancel = function(watchdog)
				watchdog.cancelled = true
				return true
			end,
		}

		local watchers = helpers.load_with_stubs("platform.remap.watchers", {
			execute = function()
				state.execute_calls = state.execute_calls + 1
				return '({ "KeyboardLayout Name" = "ABC"; })', true
			end,
			keycodes = {
				inputSourceChanged = function() end,
				currentLayout = function() return "ABC" end,
				map = { f17 = 64 },
			},
			timer = {
				new = function(_delay, callback)
					poll_callback = callback
					local handle = { live = false }
					function handle:start() self.live = true; return self end
					function handle:stop() self.live = false; return self end
					function handle:running() return self.live end
					return handle
				end,
				doAfter = function(_delay, callback)
					local timer = { callback = callback }
					function timer:stop() self.stopped = true; return self end
					state.debounces[#state.debounces + 1] = timer
					return timer
				end,
			},
		})

		local changes = {}
		helpers.assert_true(watchers.start_input_source_watcher(function(layout)
			changes[#changes + 1] = layout
		end))
		helpers.assert_true(type(notification_callback) == "function")
		helpers.assert_true(type(poll_callback) == "function")
		state.execute_calls = 0

		notification_callback()
		helpers.assert_eq(state.execute_calls, 0,
			"an input-source notification must not spawn synchronous defaults")
		helpers.assert_eq(state.spawn_calls, 1)
		helpers.assert_eq(state.executable, "/usr/bin/defaults")
		helpers.assert_eq(table.concat(state.args, " "),
			"read com.apple.HIToolbox AppleSelectedInputSources")
		helpers.assert_eq(#state.watchdogs, 1,
			"the notification read must own the same watchdog as the poll")
		state.read_callbacks[1](0, '({ "KeyboardLayout Name" = "French"; })', "")
		state.debounces[1].callback()
		helpers.assert_eq(changes[1], "French")

		poll_callback()
		helpers.assert_eq(state.spawn_calls, 2)
		helpers.assert_eq(#state.watchdogs, 2,
			"the poll must enter through the same watchdog-backed transaction")
		state.read_callbacks[2](0, '({ "KeyboardLayout Name" = "German"; })', "")
		state.debounces[2].callback()
		helpers.assert_eq(changes[2], "German")
	end)
end)

-- Restore the real adapters for later test files: the stub installed above
-- (shell_runner without exec) would otherwise leak through package.loaded
-- into whichever module the runner loads next
package.loaded["adapters.shell_runner"] = nil
package.loaded["adapters.timer_scheduler"] = nil
package.loaded["adapters.input_source_broker"] = nil
package.loaded["platform.remap.watchers"] = nil
