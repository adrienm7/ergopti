--- tests/unit/menu/ui/tap_holds/test_lone_tap.lua

--- ==============================================================================
--- MODULE: The Tap-Holds Submenu Draws The Lone Modifier Tap Window
--- DESCRIPTION:
--- The shared `tap_hold_lone_tap` list reaches the macOS tray because this
--- driver registers its provider: one row captioned with the current window
--- (off for the strict tap-hold, else « up to <n> ms »), whose choices tick the
--- current one and, once chosen, persist it and redeploy the Karabiner rules.
--- ==============================================================================

local helpers = require("tests.helpers")

local TEMPLATES = {
	["menu.tapholds.lone_tap_title"] = "Alone: %s",
	["menu.tapholds.lone_tap_up_to"] = "up to %s",
	["menu.tapholds.lone_tap_off"] = "off",
}

--- Remap double recording the window writes and the redeploys.
--- @param observed table Mutable observation table.
--- @return table remap_double
local function remap_double(observed)
	return {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Special", holdable = true, tappable = true },
		},
		TAP_HOLD_KEYS = { { id = "return_or_enter", label = "Enter" } },
		MOD_COMBOS = {},
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return true end,
		get_tap_holds_enabled = function() return true end,
		regenerate = function()
			observed.regenerations = observed.regenerations + 1
			return true
		end,
		get_combo_symmetric = function() return false end,
		get_tap_action = function() return "none" end,
		get_hold_action = function() return "none" end,
		get_tap_timeout = function() return nil end,
		get_combo_combo_action = function() return "none" end,
		get_combo_tap_action = function() return "none" end,
		get_combo_hold_action = function() return "none" end,
		get_tap_hold_timeout = function() return 200 end,
		get_sticky_timeout = function() return 1000 end,
		get_lone_modifier_tap_max_ms = function() return observed.window end,
		set_lone_modifier_tap_max_ms = function(ms)
			observed.writes[#observed.writes + 1] = ms
			if observed.refuse then return false end
			observed.window = ms
			return true
		end,
		get_simultaneous_threshold = function() return 50 end,
	}
end

--- Finds the rendered lone tap row.
--- @param rows table Rendered submenu rows.
--- @return table|nil row
local function lone_tap_row(rows)
	for _, row in ipairs(rows or {}) do
		if type(row.title) == "string" and row.title:find("^Alone: ") then return row end
	end
	return nil
end

--- Builds the submenu with readable captions for the lone tap row.
--- @param body function Receives build() and the observation table.
local function with_menu(body)
	return helpers.with_stub_scope({ "tap_hold.ui.menu_tap_holds", "menu.engine.manifest_menu",
		"core.i18n.engine.i18n", "core.logger.engine.logger", "menu.ui.builder.utils" }, function()
		local menu = helpers.load_with_stubs("tap_hold.ui.menu_tap_holds", {})
		local i18n = require("core.i18n.engine.i18n")
		local original_get = i18n.get
		i18n.get = function(key) return TEMPLATES[key] or original_get(key) end
		local observed = { window = 1000, writes = {}, regenerations = 0, refreshes = 0 }
		local ctx = { karabiner = remap_double(observed),
			updateMenu = function() observed.refreshes = observed.refreshes + 1 end }
		local ok, err = pcall(body, function() return menu.build(ctx).submenu end, observed)
		i18n.get = original_get
		if not ok then error(err, 0) end
	end)
end

helpers.describe("the macOS Tap-Holds lone modifier tap window (lone-tap-window)", function()
	helpers.it("captions the current window and ticks its choice (lone-tap-window)", function()
		with_menu(function(build, observed)
			local row = lone_tap_row(build())
			helpers.assert_true(row ~= nil, "the Tap-Holds submenu must draw the lone tap row")
			helpers.assert_eq(row.title, "Alone: up to 1000 ms")
			local titles, ticked = {}, {}
			for _, choice in ipairs(row.menu or {}) do
				titles[#titles + 1] = choice.title
				if choice.checked == true then ticked[#ticked + 1] = choice.title end
			end
			helpers.assert_eq(titles, { "off", "500 ms", "750 ms", "1000 ms", "1500 ms" })
			helpers.assert_eq(ticked, { "1000 ms" })

			observed.window = 0
			helpers.assert_eq(lone_tap_row(build()).title, "Alone: off", "0 is the strict tap-hold")
		end)
	end)

	helpers.it("a choice persists the window and redeploys the rules (lone-tap-window)", function()
		with_menu(function(build, observed)
			local choices = lone_tap_row(build()).menu
			choices[1].fn()
			helpers.assert_eq(observed.writes, { 0 }, "off writes 0")
			helpers.assert_eq(observed.regenerations, 1, "the changed window must be redeployed")
			helpers.assert_eq(observed.refreshes, 1)
			lone_tap_row(build()).menu[5].fn()
			helpers.assert_eq(observed.writes, { 0, 1500 })
			helpers.assert_eq(observed.regenerations, 2)
		end)
	end)

	helpers.it("a refused write does not redeploy (lone-tap-window)", function()
		with_menu(function(build, observed)
			observed.refuse = true
			lone_tap_row(build()).menu[2].fn()
			helpers.assert_eq(observed.writes, { 500 }, "the setter was asked")
			helpers.assert_eq(observed.window, 1000, "the refused window is not applied")
			helpers.assert_eq(observed.regenerations, 0, "nothing new to deploy")
		end)
	end)
end)

return true
