--- tests/unit/ui/menu/test_every_category_toggle_reachable.lua

--- ==============================================================================
--- MODULE: Regression — every category switch is reachable in the macOS tray
--- DESCRIPTION:
--- Builds the real tray from the real menu modules, through Builder.generate
--- and the shared renderer, and requires of every feature submenu that its
--- first row is the category switch: clickable, ticked from the category state
--- and running the category's own transaction. The parent row carries the same
--- tick and no action.
---
--- WHY IT EXISTS: Gestures, Shortcuts, Metrics and the Hotstrings master put
--- their switch on the parent row's `action`. AppKit never sends the action of
--- an item that opens a submenu, and the shared renderer drops a provider row's
--- action when the row has a subtree, so those four features could not be
--- switched on from the menu bar at all — and every row under a switched-off
--- category was greyed, which read as « everything is disabled ». The manifest
--- declared a `toggle` row for each, and this driver registered no command, so
--- the renderer skipped it with a DEBUG line.
--- ==============================================================================

local helpers = require("tests.helpers")
local CaptionFixture = require("tests.support.hotstrings_parent_caption_fixture")

-- The menu modules ui/menu/init.lua loads, under the keys Builder.generate reads.
local MENU_MODULES = {
	keyboard_layout = "ui.menu.menu_keyboard_layout",
	hotstrings      = "ui.menu.menu_hotstrings",
	keylogger       = "ui.menu.menu_metrics",
	shortcuts       = "ui.menu.menu_shortcuts",
	tap_holds       = "ui.menu.menu_tap_holds",
	gestures        = "ui.menu.menu_gestures",
	apps            = "ui.menu.menu_apps",
	about           = "ui.menu.menu_about",
}

-- Each feature submenu with a switch on macOS, by its title key, and the key of
-- the switch row that must open it.
local CATEGORIES = {
	{ title = "menu.hotstrings.title", switch = "menu.hotstrings.enable" },
	{ title = "menu.llm.title",        switch = "menu.llm.enable" },
	{ title = "menu.metrics.title",    switch = "menu.metrics.enable" },
	{ title = "menu.shortcuts.title",  switch = "menu.shortcuts.enable" },
	{ title = "menu.tapholds.title",   switch = "menu.tapholds.enable" },
	{ title = "menu.gestures.title",   switch = "menu.gestures.enable" },
}

--- A platform.remap double whose tap-holds switch reads `observed.enabled`.
--- @param observed table
--- @return table
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
		get_tap_holds_enabled = function() return observed.tapholds end,
		get_mod_combos_enabled = function() return observed.tapholds end,
		get_combo_symmetric = function() return false end,
		get_tap_action = function() return "none" end,
		get_hold_action = function() return "none" end,
		get_tap_timeout = function() return nil end,
		get_combo_combo_action = function() return "none" end,
		get_combo_tap_action = function() return "none" end,
		get_combo_hold_action = function() return "none" end,
		get_tap_hold_timeout = function() return 200 end,
		get_sticky_timeout = function() return 1000 end,
		get_simultaneous_threshold = function() return 50 end,
		regenerate = function() error("building the tray must not regenerate") end,
	}
end

--- The gesture engine surface the gestures submenu reads and toggles.
--- @param observed table Records lifecycle calls.
--- @return table
local function gestures_double(observed)
	return {
		get_sg_names = function() return {} end,
		get_action = function() return "none" end,
		get_action_label = function() return "none" end,
		get_action_parameter = function() return nil end,
		get_mode = function() return "single" end,
		get_sensitivity = function() return 1 end,
		enable_all = function() observed.gesture_calls[#observed.gesture_calls + 1] = "enable"; return true end,
		disable_all = function() observed.gesture_calls[#observed.gesture_calls + 1] = "disable"; return true end,
	}
end

--- The shortcut engine surface the shortcuts submenu reads and toggles.
--- @param observed table Records lifecycle calls.
--- @return table
local function shortcuts_double(observed)
	return {
		list_shortcuts = function() return {} end,
		is_enabled = function() return true end,
		set_wrap_pairs_getter = function() end,
		is_paused = function() return false end,
		resume_bindings = function() observed.shortcut_calls[#observed.shortcut_calls + 1] = "resume"; return true end,
		pause_bindings = function() observed.shortcut_calls[#observed.shortcut_calls + 1] = "pause"; return true end,
	}
end

--- Builds the real tray for one posture of every category.
--- @param on boolean Whether every category starts switched on.
--- @param extra table|nil Context fields to add, such as a scope port.
--- @return table tray, table ctx, table observed, table errors
local function build_tray(on, extra)
	local llm_item = nil
	require("tests.support.llm_count_menu_fixture")(function(llm_menu, state)
		state.llm_enabled = on
		llm_item = llm_menu.build_item()
	end)

	local errors = {}
	package.loaded["infra.logger"] = nil
	local real_logger = require("infra.logger")
	helpers.admit_logger_privacy(real_logger)
	local spy = setmetatable({}, { __index = real_logger })
	spy.error = function(module_name, fmt, ...)
		local ok, text = pcall(string.format, fmt, ...)
		errors[#errors + 1] = tostring(module_name) .. ": " .. (ok and text or tostring(fmt))
		return real_logger.error(module_name, fmt, ...)
	end
	package.loaded["infra.logger"] = spy

	helpers.load_with_stubs("ui.menu.builder")
	CaptionFixture.install(require("infra.i18n"))
	-- The provider rows the builders hand the renderer, before it drops what no
	-- tray can use: an action on a row that opens a submenu is lost there.
	local ManifestMenu = require("infra.manifest_menu")
	local render_rows = ManifestMenu.render_rows
	local provided = nil
	ManifestMenu.render_rows = function(rows, list_id)
		if list_id == "top_level" then provided = rows end
		return render_rows(rows, list_id)
	end
	local i18n = require("infra.i18n")
	i18n.build_language_menu_items = function()
		return { { label = "Français", checked = true, action = function() end } }
	end
	local mods = {}
	for key, name in pairs(MENU_MODULES) do
		package.loaded[name] = nil
		mods[key] = require(name)
	end
	local observed = { tapholds = on, gesture_calls = {}, shortcut_calls = {}, saves = 0,
		starts = 0, start_result = true, stops = 0, stop_result = true }
	local groups = { "rolls", "autocorrection" }
	local group_on = { rolls = on, autocorrection = on }
	local ctx = {
		config     = { log_level = 2 },
		base_dir   = helpers.driver_root(),
		-- `keymap` is hotstrings.enabled, the typing engine the Hotstrings switch runs.
		state      = { shortcuts = on, gestures = on, keylogger_enabled = on, keymap = on, hotstrings = {} },
		hotfiles   = groups,
		get_group_name = function(name) return name end,
		keymap     = {
			start = function()
				observed.starts = observed.starts + 1
				return observed.start_result
			end,
			stop = function()
				observed.stops = observed.stops + 1
				return observed.stop_result
			end,
			is_group_enabled = function(name) return group_on[name] == true end,
			enable_group = function(name) group_on[name] = true end,
			disable_group = function(name) group_on[name] = false end,
			get_sections = function() return {} end,
			is_section_enabled = function() return true end,
		},
		save_prefs = function() observed.saves = observed.saves + 1; return true end,
		updateMenu = function() end,
		do_reload  = function() end,
		notify_feature = function() end,
		applyTriggerChar = function(text) return text end,
		karabiner  = remap_double(observed),
		gestures   = gestures_double(observed),
		shortcuts  = shortcuts_double(observed),
		llm_handler = { build_item = function() return llm_item end },
	}
	for key, value in pairs(extra or {}) do ctx[key] = value end
	local actions = setmetatable({}, { __index = function() return function() end end })
	-- The observing renderer port is installed before its actual native consumer imports it.
	package.loaded["ui.menu.builder"] = nil
	local builder = require("ui.menu.builder")
	local ok, tray = pcall(builder.generate, ctx, mods, actions)
	ManifestMenu.render_rows = render_rows
	package.loaded["infra.logger"] = nil
	helpers.assert_true(ok, "Builder.generate raised: " .. tostring(tray))
	helpers.assert_true(type(provided) == "table", "the tray root must reach the renderer")
	observed.group_on = group_on
	observed.provided = provided
	return tray, ctx, observed, errors
end

--- The provider row whose label starts with the text of `key`.
--- @param rows table
--- @param key string
--- @return table|nil
local function provider_row(rows, key)
	local text = require("infra.i18n").get(key)
	for _, row in ipairs(rows or {}) do
		if type(row.label) == "string" and row.label:sub(1, #text) == text then return row end
	end
	return nil
end

--- The top-level row whose title starts with the text of `key`.
--- @param tray table
--- @param key string
--- @return table|nil
local function top_row(tray, key)
	local text = require("infra.i18n").get(key)
	for _, row in ipairs(tray or {}) do
		if type(row.title) == "string" and row.title:sub(1, #text) == text then return row end
	end
	return nil
end


helpers.describe("the real macOS tray: every category switch is reachable", CaptionFixture.scoped(function()

	for _, posture in ipairs({ true, false }) do
		helpers.it("opens each feature submenu with its switch, ticked " .. tostring(posture), function()
			local tray, _, observed, errors = build_tray(posture)
			local i18n = require("infra.i18n")
			local checked = 0
			for _, category in ipairs(CATEGORIES) do
				local parent = top_row(tray, category.title)
				helpers.assert_true(parent ~= nil, category.title .. " must be in the tray")
				local provided = provider_row(observed.provided, category.title)
				helpers.assert_true(provided ~= nil, category.title .. " must reach the renderer as a provider row")
				helpers.assert_nil(provided.action,
					category.title .. " parent must carry no action: AppKit never sends the action of a row that opens a submenu")
				helpers.assert_nil(parent.fn, category.title .. " parent must not be clickable")
				helpers.assert_eq(parent.checked == true, posture, category.title .. " parent tick follows the state")
				local first = type(parent.menu) == "table" and parent.menu[1] or nil
				helpers.assert_true(first ~= nil, category.title .. " submenu must not be empty")
				helpers.assert_eq(first.title, i18n.get(category.switch),
					category.title .. " submenu must open with its category switch")
				helpers.assert_eq(type(first.fn), "function", category.title .. " switch must be clickable")
				helpers.assert_eq(first.checked, posture, category.title .. " switch is a checkbox showing the state")
				checked = checked + 1
			end
			helpers.assert_eq(checked, #CATEGORIES, "every category must have been inspected")
			for _, line in ipairs(errors) do
				helpers.assert_true(line:find("category switch", 1, true) == nil
					and line:find("both an `action`", 1, true) == nil,
					"the renderer reported an unreachable control: " .. line)
			end
		end)
	end

	-- The key combinations left the Tap-Holds submenu for a group under
	-- Shortcuts that opens with a switch of its own, and whose title is ticked
	-- while that switch is on.
	for _, posture in ipairs({ true, false }) do
		helpers.it("opens « Combinaisons de touches » with its own switch, ticked " .. tostring(posture), function()
			local tray = build_tray(posture)
			local i18n = require("infra.i18n")
			local group = nil
			for _, row in ipairs(top_row(tray, "menu.shortcuts.title").menu or {}) do
				if row.title == i18n.get("menu.shortcuts.key_combinations") then group = row end
			end
			helpers.assert_not_nil(group, "the Shortcuts submenu holds the key-combinations group")
			helpers.assert_eq(group.checked == true, posture, "the group title shows its switch")
			local first = type(group.menu) == "table" and group.menu[1] or nil
			helpers.assert_true(first ~= nil, "the group is not empty")
			helpers.assert_eq(first.title, i18n.get("menu.shortcuts.key_combinations_enable"),
				"the group opens with its own switch")
			helpers.assert_eq(type(first.fn), "function", "the switch is clickable")
			helpers.assert_eq(first.checked, posture, "the switch is a checkbox showing the state")
		end)
	end

	helpers.it("the gestures switch runs the gestures lifecycle and persists it", function()
		local tray, ctx, observed = build_tray(true)
		local switch = top_row(tray, "menu.gestures.title").menu[1]
		switch.fn()
		helpers.assert_eq(observed.gesture_calls, { "disable" }, "switching off must stop the gestures")
		helpers.assert_eq(ctx.state.gestures, false, "and publish the posture")
		helpers.assert_true(observed.saves > 0, "and persist it")
	end)

	helpers.it("the shortcuts switch runs the bindings lifecycle and persists it", function()
		local tray, ctx, observed = build_tray(false)
		local switch = top_row(tray, "menu.shortcuts.title").menu[1]
		switch.fn()
		helpers.assert_eq(observed.shortcut_calls, { "resume" }, "switching on must resume the bindings")
		helpers.assert_eq(ctx.state.shortcuts, true, "and publish the posture")
		helpers.assert_true(observed.saves > 0, "and persist it")
	end)

	-- The switch is the typing engine's master, hotstrings.enabled, as on
	-- Windows: it used to switch every category, so its tick read « every
	-- category on » while the engine ran for the one section the wizard's
	-- recommendation imports (hotstrings-master-tick). « All sections » is the
	-- row that switches every category.
	helpers.it("the hotstrings switch stops the typing engine and keeps each category's choice", function()
		local tray, ctx, observed = build_tray(true)
		top_row(tray, "menu.hotstrings.title").menu[1].fn()
		helpers.assert_eq(observed.stops, 1, "switching off stops the engine, so nothing expands")
		helpers.assert_eq(ctx.state.keymap, false, "and publishes its switch for the save")
		helpers.assert_eq(observed.group_on, { rolls = true, autocorrection = true },
			"the categories keep their choice under the master")
		helpers.assert_true(observed.saves > 0)
	end)

	helpers.it("the hotstrings switch changes nothing when the typing engine refuses to stop", function()
		local tray, ctx, observed = build_tray(true)
		observed.stop_result = false
		top_row(tray, "menu.hotstrings.title").menu[1].fn()
		helpers.assert_eq(ctx.state.keymap, true, "an engine that may still type keeps its tick")
		helpers.assert_eq(observed.saves, 0, "a refused stop publishes nothing")
	end)

	-- « Clear » stops the typing engine (hotstrings.enabled is off by default).
	-- The switch then turned every group on and left the engine stopped: ticked,
	-- yet nothing fired, predictions went silent too, and the next start kept
	-- the engine off because its switch was never published.
	helpers.it("the hotstrings switch starts a stopped typing engine and keeps each category's choice", function()
		local tray, ctx, observed = build_tray(false)
		top_row(tray, "menu.hotstrings.title").menu[1].fn()
		helpers.assert_eq(observed.starts, 1, "the engine is started through the shared gate")
		helpers.assert_eq(ctx.state.keymap, true, "and its switch published, so the save keeps it on")
		helpers.assert_eq(observed.group_on, { rolls = false, autocorrection = false },
			"the categories keep their choice under the master")
		helpers.assert_true(observed.saves > 0)
	end)

	helpers.it("the hotstrings switch changes nothing when the typing engine refuses to start", function()
		local tray, ctx, observed = build_tray(false)
		observed.start_result = false
		top_row(tray, "menu.hotstrings.title").menu[1].fn()
		helpers.assert_eq(observed.group_on, { rolls = false, autocorrection = false })
		helpers.assert_eq(observed.saves, 0, "a refused start publishes nothing")
		helpers.assert_eq(ctx.state.keymap, false)
	end)

	-- The Hotstrings scope rows sit under the switch, like the Metrics ones,
	-- and run the scope owner; they were declared nowhere, so no driver
	-- offered « restore recommended » or « clear » for the hotstrings.
	for _, paused in ipairs({ false, true }) do
		helpers.it("draws the hotstrings restore and clear rows, routed to the scope (paused "
			.. tostring(paused) .. ")", function()
			local requests = {}
			local tray, _, _, errors = build_tray(true, { paused = paused,
				apply_preference_scope = function(scope, mode)
					requests[#requests + 1] = scope .. ":" .. mode
					return true
				end })
			local i18n = require("infra.i18n")
			local rows = top_row(tray, "menu.hotstrings.title").menu
			helpers.assert_eq(rows[2].title, i18n.get("common.restore_recommended"))
			helpers.assert_eq(rows[3].title, i18n.get("common.clear_to_system"))
			for index = 2, 3 do
				if type(rows[index].fn) == "function" then rows[index].fn() end
			end
			helpers.assert_eq(requests, paused and {} or { "hotstrings:recommended", "hotstrings:clear" },
				"a paused session never reaches the scope")
			for _, line in ipairs(errors) do
				helpers.assert_true(line:find("scope_", 1, true) == nil, "the renderer reported: " .. line)
			end
		end)
	end

end))
