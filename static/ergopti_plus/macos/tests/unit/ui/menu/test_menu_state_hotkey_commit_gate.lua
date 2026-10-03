--- tests/unit/ui/menu/test_menu_state_hotkey_commit_gate.lua

--- ==============================================================================
--- MODULE: Menu State Retired Metrics Binding Regressions
--- DESCRIPTION:
--- Historical dashboard fields and callbacks have no native owner. Their values
--- must neither acquire a binding nor block synchronization of active modules.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =======================================
-- =======================================
-- ======= 1/ Exact Failure Matrix =======
-- =======================================
-- =======================================

--- Returns a callback with one injected terminal behavior.
--- @param mode string false, nil, or throw.
--- @param calls table Mutable call counter.
--- @return function callback
local function refusing_callback(mode, calls)
	return function()
		calls.count = calls.count + 1
		if mode == "throw" then error("synthetic hotkey refusal") end
		if mode == "nil" then return nil end
		return false
	end
end

--- Drives a minimal state synchronization with one refusing hotkey owner.
--- @param target string metrics or apps.
--- @param mode string false, nil, or throw.
--- @return boolean committed
--- @return table calls
local function run_sync(target, mode)
	package.loaded["ui.menu.menu_state"] = nil
	local MenuState = require("ui.menu.menu_state")
	local calls = { count = 0 }
	local accept = function() return true end
	local metrics = target == "metrics" and refusing_callback(mode, calls) or accept
	local apps = target == "apps" and refusing_callback(mode, calls) or accept
	local state = {
		hotstrings = {},
		metrics_shortcut = { mods = { "ctrl" }, key = "m" },
		apps_time_shortcut = { mods = { "ctrl" }, key = "a" },
	}
	local committed = MenuState.sync_state_to_modules(state, {}, false, {
		apply_apps_time_shortcut = apps,
		apply_metrics_shortcut = metrics,
		core_mods = {},
		hotstring_editor = {},
		save_prefs = accept,
	})
	return committed, calls
end

helpers.describe("menu state ignores retired metric hotkey synchronization", function()
	for _, target in ipairs({ "metrics", "apps" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("ignores retired " .. target .. " shortcut callbacks returning " .. mode, function()
				local committed, calls = run_sync(target, mode)
				helpers.assert_eq(committed, true,
					"retired shortcut data must never gate synchronization of active owners")
				helpers.assert_eq(calls.count, 0,
					"global synchronization must never call the retired native owner")
			end)
		end
	end
end)
