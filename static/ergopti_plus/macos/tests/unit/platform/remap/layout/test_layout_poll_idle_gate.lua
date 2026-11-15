--- tests/unit/platform/remap/layout/test_layout_poll_idle_gate.lua

--- ==============================================================================
--- MODULE: Regression — the layout fallback poll spawns nothing while idle
--- DESCRIPTION:
--- The Sequoia fallback poll spawned `/usr/bin/defaults` every 2 s for the whole
--- session, 150 child processes per 5 minutes of a Mac nobody touched: the
--- idle cost the field run failed on 2026-10-31. A switch the notification
--- missed comes from a key, a click or the menu, so a tick reads HIToolbox only
--- when an input event reached the system since the last read, and at least
--- every layout_idle_poll_ms for a switch no person made (layout-poll-idle-gate).
--- ==============================================================================

local helpers = require("tests.helpers")
local Timings = require("core.timing.engine.timings")

helpers.describe("karabiner.watchers: the layout poll is idle-gated (layout-poll-idle-gate)", function()
	helpers.it("(layout-poll-idle-gate) reads after input, skips while idle, and still reads at the idle bound", function()
		local spawns, idle = 0, 0
		local poll_callback
		package.loaded["adapters.input_source_broker"] = {
			subscribe = function() return true end,
			unsubscribe = function() return true end,
		}
		package.loaded["core.process.adapters.shell_runner"] = {
			spawn = function(_, _, on_done)
				spawns = spawns + 1
				return {
					start = function()
						on_done(0, '({ "KeyboardLayout Name" = ABC; })', "")
						return true
					end,
					terminate = function() return true end,
				}
			end,
			_active_tasks = {},
		}
		package.loaded["core.events.timer_scheduler"] = {
			after = function() return { fired = false }, true end,
			cancel = function() return true end,
		}
		package.loaded["platform.system.info"] = { input_idle_seconds = function() return idle end }
		package.loaded["platform.remap.watchers"] = nil
		local watchers = helpers.load_with_stubs("platform.remap.watchers", {
			timer = {
				new = function(_, callback)
					poll_callback = callback
					local handle = { live = false }
					function handle:start() self.live = true; return self end
					function handle:stop() self.live = false; return self end
					function handle:running() return self.live end
					return handle
				end,
				doAfter = function() return { stop = function() end } end,
			},
			keycodes = { inputSourceChanged = function() end, currentLayout = function() return "ABC" end,
				map = { f17 = 64 } },
		})
		local ok, err = pcall(function()
			helpers.assert_eq(watchers.start_input_source_watcher(function() end), true)
			local poll_sec = Timings.sec("ui", "layout_poll_ms")
			local idle_ticks = math.ceil(Timings.sec("ui", "layout_idle_poll_ms") / poll_sec)
			helpers.assert_true(idle_ticks > 2, "the idle bound spans several poll ticks")

			-- An input event less than one tick ago: the tick reads.
			idle = poll_sec / 2
			poll_callback()
			helpers.assert_eq(spawns, 1, "a tick after input reads HIToolbox")

			-- Nobody touched the Mac since that read: no child process.
			for tick = 1, idle_ticks - 1 do
				idle = idle + poll_sec
				poll_callback()
				helpers.assert_eq(spawns, 1, "idle tick " .. tick .. " spawns nothing")
			end

			-- The idle bound still reads, for a switch no person made.
			idle = idle + poll_sec
			poll_callback()
			helpers.assert_eq(spawns, 2, "the idle bound reads once")

			-- A key pressed after that read: the next tick reads again.
			idle = poll_sec / 4
			poll_callback()
			helpers.assert_eq(spawns, 3, "input since the last read makes the tick read")
		end)
		watchers.stop_input_source_watcher()
		package.loaded["platform.system.info"] = nil
		package.loaded["core.process.adapters.shell_runner"] = nil
		package.loaded["core.events.timer_scheduler"] = nil
		package.loaded["adapters.input_source_broker"] = nil
		package.loaded["platform.remap.watchers"] = nil
		if not ok then error(err, 0) end
	end)
end)
