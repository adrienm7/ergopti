--- tests/unit/ui/menu/test_tray_paused_greys_features.lua

--- ==============================================================================
--- MODULE: Regression — pause greys every feature row of the real macOS tray
--- DESCRIPTION:
--- Builds the tray from the REAL menu modules while the script is paused and
--- checks what hs.menubar would receive at the top level.
---
--- WHY IT EXISTS: each feature builder decided its own pause gating, so only
--- Shortcuts and Gestures greyed out; Hotstrings, AI, Metrics and Tap-Holds
--- stayed live during « pause = tout éteint », and Metrics could even be toggled.
--- The meta rows and the title row that resumes the script must stay usable.
--- ==============================================================================

local helpers = require("tests.helpers")

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

local FEATURE_ROWS = {
	"menu.layout.title", "menu.hotstrings.title", "menu.llm.title", "menu.metrics.title",
	"menu.shortcuts.title", "menu.tapholds.title", "menu.gestures.title", "menu.apps.title",
}

local META_ROWS = {
	"menu.global.title", "menu.global.language", "menu.global.setup_wizard",
	"menu.about.title", "menu.global.reload", "menu.global.quit", "menu.debug.title",
}





-- ===============================
-- ===============================
-- ======= 1/ Tray Doubles =======
-- ===============================
-- ===============================

--- Remap bridge double exposing only what the tap-hold builder reads.
--- @return table remap
local function remap_double()
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

--- Builds the real tray with the requested pause state.
--- @param paused boolean Published script pause state.
--- @return table|nil menu
--- @return string|nil build_error
local function build_tray(paused)
	local llm_item = nil
	require("tests.support.llm_count_menu_fixture")(function(llm_menu)
		llm_item = llm_menu.build_item()
	end)
	local builder = helpers.load_with_stubs("ui.menu.builder")
	local i18n = require("infra.i18n")
	i18n.build_language_menu_items = function()
		return { { label = "Français", checked = true, action = function() end } }
	end
	local mods = {}
	for key, name in pairs(MENU_MODULES) do
		package.loaded[name] = nil
		mods[key] = require(name)
	end
	local ctx = {
		paused     = paused,
		config     = { log_level = 2 },
		base_dir   = helpers.driver_root(),
		state      = { shortcuts = true, gestures = true, keylogger_enabled = true, hotstrings = {} },
		hotfiles   = {},
		save_prefs = function() return true end,
		updateMenu = function() end,
		do_reload  = function() end,
		notify_feature = function() end,
		applyTriggerChar = function(text) return text end,
		karabiner  = remap_double(),
		gestures   = {
			get_sg_names = function() return {} end,
			get_action = function() return "none" end,
			get_action_label = function() return "none" end,
			get_action_parameter = function() return nil end,
			get_mode = function() return "single" end,
			get_sensitivity = function() return 1 end,
			get_space_wrap = function() return false end,
		},
		shortcuts  = {
			list_shortcuts = function() return {} end,
			is_enabled = function() return true end,
			set_wrap_pairs_getter = function() end,
			is_paused = function() return paused end,
		},
		script_control = { toggle = function() return true end },
		llm_handler = { build_item = function() return llm_item end },
	}
	local actions = setmetatable({}, { __index = function() return function() end end })
	local ok, menu = pcall(builder.generate, ctx, mods, actions)
	if not ok then return nil, tostring(menu) end
	return menu, nil
end

--- Indexes top-level rows by the i18n key their title starts with.
--- @param menu table Rendered tray rows.
--- @param keys string[] i18n keys to find.
--- @return table rows Key → row.
local function index_rows(menu, keys)
	local i18n = require("infra.i18n")
	local rows = {}
	for _, key in ipairs(keys) do
		local text = i18n.get(key):gsub("^%S+ ", "")
		for _, row in ipairs(menu or {}) do
			if type(row.title) == "string" and row.title:find(text, 1, true) then
				rows[key] = row
				break
			end
		end
	end
	return rows
end





-- ============================
-- ============================
-- ======= 2/ Scenarios =======
-- ============================
-- ============================

helpers.describe("the real macOS tray while paused", function()
	local menu, build_error = build_tray(true)

	helpers.it("greys every feature row and strips its handler while paused", function()
		helpers.assert_nil(build_error, "Builder.generate raised while paused")
		local rows = index_rows(menu, FEATURE_ROWS)
		for _, key in ipairs(FEATURE_ROWS) do
			local row = rows[key]
			helpers.assert_true(row ~= nil, "the paused tray lost its '" .. key .. "' row")
			helpers.assert_true(row.disabled == true, "'" .. key .. "' must be greyed while paused")
			helpers.assert_nil(row.fn, "'" .. key .. "' must not stay clickable while paused")
		end
	end)

	helpers.it("keeps the meta rows and the resume title row usable while paused", function()
		local rows = index_rows(menu, META_ROWS)
		for _, key in ipairs(META_ROWS) do
			local row = rows[key]
			helpers.assert_true(row ~= nil, "the paused tray lost its '" .. key .. "' row")
			helpers.assert_true(row.disabled ~= true, "'" .. key .. "' must stay enabled while paused")
		end
		helpers.assert_true(type(menu[1].fn) == "function",
			"the title row must stay clickable so the script can be resumed")
		helpers.assert_true(menu[1].disabled ~= true, "the title row must not be greyed")
	end)

	helpers.it("leaves feature rows enabled when the script runs", function()
		local running = build_tray(false)
		local rows = index_rows(running, FEATURE_ROWS)
		for _, key in ipairs(FEATURE_ROWS) do
			helpers.assert_true(rows[key] ~= nil and rows[key].disabled ~= true,
				"'" .. key .. "' must be enabled while running")
		end
	end)
end)
