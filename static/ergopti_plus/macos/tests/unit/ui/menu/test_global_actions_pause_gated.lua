--- tests/unit/ui/menu/test_global_actions_pause_gated.lua

--- ==============================================================================
--- MODULE: Regression — the global actions must be pause-gated
---         (global-actions-pause-gate)
--- DESCRIPTION:
--- « Tout activer » stayed live during a pause. Clicking it re-enabled every
--- feature and bound every shortcut hotkey on the spot, which is the exact
--- opposite of what a pause promises: « pause = tout éteint ».
---
--- ROOT CAUSE ENCODED: pause owns the bindings axis for the whole pause window —
--- pause_all() snapshots what was running and resume_all() restores from that
--- snapshot. A change made in between is therefore either silently discarded on
--- resume, or, for the enable direction, applied immediately in defiance of the
--- pause. The per-feature toggles were gated for precisely this reason; the
--- three GLOBAL actions, which move all of those toggles at once, were the
--- siblings that never were — the same one-missed-site shape as the Shortcuts
--- master toggle before it.
---
--- WHY IT WAS SILENT: every visible signal reported success. The item rendered
--- enabled, the notification fired, the menu rebuilt. Only the resume, minutes
--- later, quietly undid it.
---
--- Driven through Builder.generate rather than scanned, so the assertion is on
--- what the menu actually offers the user while paused.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Minimal actions table satisfying builder.generate's top-level-tail loop. The
--- three global actions record their invocation so a "gated" item that still
--- fires can never pass.
--- @param fired table Table the global actions record their id into.
--- @return table
local function make_actions(fired)
	return {
		set_log_level     = function() end,
		open_logs         = function() end,
		open_today_log    = function() end,
		open_error_log    = function() end,
		open_console      = function() end,
		show_setup_wizard = function() end,
		open_paths        = function() end,
		reload            = function() end,
		quit              = function() end,
		enable_all        = function() fired[#fired + 1] = "enable_all" end,
		disable_all       = function() fired[#fired + 1] = "disable_all" end,
		reset_defaults    = function() fired[#fired + 1] = "reset_defaults" end,
	}
end

--- Builds the menu and returns the « Actions globales » submenu items.
--- @param paused boolean Value of ctx.paused for this build.
--- @param fired table Invocation recorder handed to make_actions.
--- @return table|nil
local function global_actions_items(paused, fired)
	local builder = helpers.load_with_stubs("ui.menu.builder")
	local i18n = require("lib.i18n")
	i18n.get = function(k) return k end
	i18n.build_language_menu_items = function() return {} end

	local ok, menu = pcall(builder.generate, { config = { log_level = 2 }, paused = paused }, {}, make_actions(fired))
	if not ok or type(menu) ~= "table" then return nil end

	for _, item in ipairs(menu) do
		if item.title == "menu.global.title" and type(item.menu) == "table" then
			return item.menu
		end
	end
	return nil
end

--- Collects the three action entries by title, ignoring separators.
--- @param items table
--- @return table Map of title → item.
local function by_title(items)
	local out = {}
	for _, it in ipairs(items or {}) do
		if type(it.title) == "string" and it.title ~= "-" then out[it.title] = it end
	end
	return out
end

local ACTION_TITLES = {
	"menu.global.enable_all",
	"menu.global.disable_all",
	"menu.global.reset_defaults",
}




-- ==========================================================
-- ==========================================================
-- ======= 1/ Paused: the global actions are inert ==========
-- ==========================================================
-- ==========================================================

helpers.describe("global actions: nothing global is actionable during a pause", function()
	helpers.it("every global action is disabled while paused", function()
		local fired = {}
		local items = global_actions_items(true, fired)
		helpers.assert_true(items ~= nil, "the global-actions submenu must be built")

		local found = by_title(items)
		for _, title in ipairs(ACTION_TITLES) do
			local item = found[title]
			helpers.assert_true(item ~= nil, title .. " must be present in the submenu")
			helpers.assert_true(item and item.disabled == true,
				title .. " must be DISABLED while paused. « Tout activer » re-enables every "
					.. "feature and binds every shortcut hotkey on the spot, which is precisely "
					.. "what « pause = tout éteint » promises will not happen")
			helpers.assert_true(item and item.fn == nil,
				title .. " must carry no handler while paused — a greyed item whose fn survives "
					.. "still fires the moment the gate is rendered wrong somewhere else")
		end

		helpers.assert_eq(#fired, 0,
			"building the menu must not itself invoke a global action")
	end)
end)




-- ==========================================================
-- ==========================================================
-- ======= 2/ Unpaused: they still work ====================
-- ==========================================================
-- ==========================================================

helpers.describe("global actions: unpaused, they remain fully usable", function()
	helpers.it("each action is enabled and fires when not paused", function()
		local fired = {}
		local items = global_actions_items(false, fired)
		helpers.assert_true(items ~= nil, "the global-actions submenu must be built")

		local found = by_title(items)
		for _, title in ipairs(ACTION_TITLES) do
			local item = found[title]
			helpers.assert_true(item ~= nil, title .. " must be present in the submenu")
			helpers.assert_true(item and not item.disabled,
				title .. " must stay enabled when the script is running — a gate that never opens "
					.. "removes the feature instead of protecting the pause")
			helpers.assert_eq(type(item and item.fn), "function",
				title .. " must carry its handler when not paused")
			item.fn()
		end

		helpers.assert_eq(#fired, #ACTION_TITLES,
			"each handler must reach its action. Asserting only that the paused build is inert "
				.. "would also pass on a build where the items never work at all")
	end)
end)
