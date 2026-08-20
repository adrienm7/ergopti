--- tests/unit/platform/remap/test_layout_poll_async.lua

--- ==============================================================================
--- MODULE: Regression — layout fallback poll reads asynchronously (F-LOW-4)
--- DESCRIPTION:
--- The Sequoia fallback poll (doEvery LAYOUT_POLL_SEC) called
--- read_current_layout_from_hitoolbox() — a SYNCHRONOUS `defaults read` subprocess
--- on the Hammerspoon main run loop — every 2 s for the whole session. It is not
--- inside an eventtap (so no kCGEventTapDisabledByTimeout), but it is exactly the
--- steady-state main-loop cost the boot/hot-path profiler work aims to eliminate,
--- and it runs forever on the very Sequoia machines the poll exists for.
---
--- Fix: the poll now reads via read_layout_async -> ShellRunner.spawn (off the main
--- loop), guarded by _layout_poll_pending so concurrent ticks cannot pile up. The
--- synchronous read stays only on the infrequent seed + notification paths.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("karabiner.watchers: layout fallback poll is async (F-LOW-4)", function()
	local function read_src()
		-- Selected by a declaration unique to platform/remap/watchers.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function read_current_layout_from_hitoolbox")
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
end)

-- Restore the real adapters for later test files: the stub installed above
-- (shell_runner without exec) would otherwise leak through package.loaded
-- into whichever module the runner loads next
package.loaded["adapters.shell_runner"] = nil
package.loaded["adapters.timer_scheduler"] = nil
package.loaded["platform.remap.watchers"] = nil
