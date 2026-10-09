--- tests/support/menu_config_watcher_fixture.lua

--- ==============================================================================
--- MODULE: Menu Config Watcher Fixture
--- DESCRIPTION:
--- Owns native boundaries and real watcher consumers for one complete scenario.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNERS = { "ui.menu.menu_watchers", "infra.logger", "infra.git_status", "reload_gate" }

--- Runs a real menu watcher with deterministic events and reload decisions.
--- @param body function Scenario receiving watcher observations.
--- @param options table|nil Explicit external behavior and watched paths.
--- @return ... Scenario results.
function M.with_watcher(body, options)
	options = options or {}
	local host = hs
	local previous_pathwatcher, previous_timer = host.pathwatcher, host.timer
	local outcome = table.pack(xpcall(function()
		return helpers.with_fresh_modules(OWNERS, function()
			for _, name in ipairs(OWNERS) do package.loaded[name] = nil end
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.git_status"] = {
				operation_in_progress = options.git_probe or function() return false end,
			}
			local Watchers = require("ui.menu.menu_watchers")
			local clock = options.clock or 1000
			local changed, pending, deferred
			local arms, reloads, defer_calls, timer_stops = 0, 0, 0, 0
			host.pathwatcher = { new = function(_, callback)
				changed = callback
				return { start = function(self) return self end, stop = function() end }
			end }
			host.timer = {
				doAfter = function(_, callback)
					arms = arms + 1
					pending = callback
					local timer = {}
					function timer:stop()
						timer_stops = timer_stops + 1
						if options.timer_stop then return options.timer_stop(timer_stops, self) end
					end
					return timer
				end,
				secondsSinceEpoch = function() return clock end,
			}
			local owner = assert(Watchers.start_config_watcher(
				options.base_dir or "/fake/base/",
				function()
					reloads = reloads + 1
					if options.reload then return options.reload(reloads) end
					return true
				end,
				options.suppress_until or function() return 0 end,
				{ defer_reload = function(callback)
					defer_calls = defer_calls + 1
					if options.hold_reload then deferred = callback; return true end
					return callback()
				end },
				options.ignored_dirs,
				options.self_written_files
			), "menu watcher fixture startup must commit")
			return body({
				owner = owner,
				callback = function() return changed end,
				fire = function(paths) return assert(changed, "watcher callback must be registered")(paths) end,
				set_clock = function(value) clock = value end,
				scheduled = function() return pending end,
				deferred = function() return deferred end,
				poll = function()
					local callback = assert(pending, "watcher timer must be owned")
					pending = nil
					return callback()
				end,
				release = function()
					local callback = assert(deferred, "deferred reload must be owned")
					deferred = nil
					return callback()
				end,
				armed_count = function() return arms end,
				reloads = function() return reloads end,
				defer_calls = function() return defer_calls end,
				timer_stops = function() return timer_stops end,
			})
		end)
	end, debug.traceback))
	host.pathwatcher, host.timer = previous_pathwatcher, previous_timer
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

return M
