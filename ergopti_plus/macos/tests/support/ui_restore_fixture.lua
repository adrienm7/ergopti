--- tests/support/ui_restore_fixture.lua

--- ==============================================================================
--- MODULE: UI Restore Fixture
--- DESCRIPTION:
--- Owns native settings, scheduler doubles and every observed window cache entry.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local MODULE_NAMES = {
	"adapters.storage", "adapters.timer_scheduler", "infra.logger", "infra.timings",
	"infra.ui_restore", "ui.hotstring_editor", "ui.metrics_typing", "ui.metrics_typing.init",
	"ui.metrics_apps", "ui.metrics_apps.init",
}

--- Runs one complete UI restore scenario with isolated native and module state.
--- @param options table|nil Scheduler, window and settings controls.
--- @param scenario function Receives the real module, scheduler and window state.
--- @return ... Scenario results.
function M.with_fixture(options, scenario)
	options = options or {}
	local saved_hs = _G.hs
	local outcome = table.pack(xpcall(function()
		return helpers.with_fresh_modules(MODULE_NAMES, function()
			for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = nil end
			local settings = options.settings or {}
			local ui_state = { open = options.initial_open ~= false, reopen_calls = 0, errors = {} }
			_G.hs = {
				configdir = "/tmp/ergopti-test",
				settings = {
					get = function(key) return settings[key] end,
					set = function(key, value) settings[key] = value end,
					clear = function(key) settings[key] = nil; return true end,
				},
			}
			local function noop() end
			package.loaded["infra.logger"] = setmetatable({}, {
				__index = function(_, method)
					if method == "error" then
						return function(_log, format, ...)
							ui_state.errors[#ui_state.errors + 1] = string.format(format, ...)
						end
					end
					return noop
				end,
			})
			package.loaded["infra.timings"] = { sec = function() return 1 end }

			package.loaded["ui.hotstring_editor"] = {
				is_open = function() return ui_state.open end,
				open = function()
					ui_state.reopen_calls = ui_state.reopen_calls + 1
					ui_state.open = options.reopen_opens ~= false
				end,
			}

			local scheduler = {
				handles = {},
				after_handles = {},
				cancel_calls = {},
			}
			function scheduler.every(_, callback)
				local mode = options.every_mode or "commit"
				if mode == "throw" then error("poller constructor exploded") end
				if mode == "nil" then return nil, false end
				local handle = { active = true, callback = callback, timer = {} }
				scheduler.handles[#scheduler.handles + 1] = handle
				return handle, mode == "commit"
			end
			function scheduler.after(_, callback)
				local mode = options.after_mode or "commit"
				if mode == "throw" then error("one-shot constructor exploded") end
				if mode == "nil" then return nil, false end
				local handle = { active = true, callback = callback, timer = {} }
				scheduler.after_handles[#scheduler.after_handles + 1] = handle
				return handle, mode == "commit"
			end
			function scheduler.cancel(handle)
				scheduler.cancel_calls[#scheduler.cancel_calls + 1] = handle
				local result = options.cancel_results
					and options.cancel_results[#scheduler.cancel_calls]
				if result == "throw" then error("poller cancel exploded") end
				if result == false then return false end
				handle.active = false
				handle.timer = nil
				return true
			end
			package.loaded["adapters.timer_scheduler"] = scheduler

			local ui_restore = require("infra.ui_restore")
			local result = table.pack(xpcall(function()
				return scenario(ui_restore, scheduler, ui_state)
			end, debug.traceback))
			local stopped, stop_result = xpcall(ui_restore.stop, debug.traceback)
			if not result[1] then error(result[2], 0) end
			if not stopped then error(stop_result, 0) end
			assert(stop_result == true, "UI restore fixture cleanup did not settle")
			return table.unpack(result, 2, result.n)
		end)
	end, debug.traceback))
	_G.hs = saved_hs
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

return M
