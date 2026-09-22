--- tests/unit/ui/menu/test_tray_every_submenu_populated.lua

--- ==============================================================================
--- MODULE: Regression — every submenu of the real macOS tray has rows
--- DESCRIPTION:
--- Builds the tray from the REAL menu modules — the ones ui/menu/init.lua loads
--- — through Builder.generate and the shared renderer, with doubles only for
--- the runtime owners behind them, and reads what hs.menubar would receive.
---
--- WHY IT EXISTS: a release shipped with the Keyboard layout, Metrics and
--- Karabiner submenus opening empty. Each builder handed the tray a tree in the
--- wrong field (`items` holding rows already materialised, or `menu` on a
--- provider row), the renderer dropped them with one log line, and every
--- existing tray test passed because it built the tray with NO menu module at
--- all. This one builds the real ones, so an empty submenu, a dialect warning
--- from the renderer, a row naming the remap engine, or a row drawn twice
--- fails here instead of on a user's menu bar.
--- ==============================================================================

local helpers = require("tests.helpers")

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

-- The top-level submenus the macOS tray must carry, by title key.
local EXPECTED_SUBMENUS = {
	"menu.layout.title", "menu.hotstrings.title", "menu.metrics.title",
	"menu.shortcuts.title", "menu.tapholds.title", "menu.gestures.title",
	"menu.apps.title", "menu.llm.title", "menu.global.title", "menu.global.language",
	"menu.about.title", "menu.debug.title",
}

-- The config folder row's text. Resolved rather than echoed: the old renderer
-- drew another platform's copy of this row as "<label> — <reason>" only when
-- the label resolved, so an echoed key hid exactly the duplicate pinned here.
local CONFIG_FOLDER = "Config folder"

-- Renderer diagnostics that mean a row or a subtree was lost.
local LOSS_MARKERS = {
	"uses `title`", "hangs its subtree on `menu`", "carries `fn`",
	"produced a row with no label", "Build error for", "missing or in error",
}

--- A platform.remap double: every getter answers, every engine call raises.
--- @return table
local function remap_double()
	return {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Special", holdable = true, tappable = true },
			{ id = "ctrl", label = "Ctrl", category = "Modifiers", holdable = true, tappable = false },
		},
		TAP_HOLD_KEYS = { { id = "left_shift", label = "Left Shift" }, { id = "return_or_enter", label = "Enter" } },
		MOD_COMBOS = { { id = "shift_pair", label = "Shift pair", group = "Shift" } },
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return true end,
		get_combo_symmetric = function() return false end,
		get_tap_action = function() return "none" end,
		get_hold_action = function() return "ctrl" end,
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

--- The gesture engine surface menu_gestures reads while building.
--- @return table
local function gestures_double()
	return {
		get_sg_names = function() return {} end,
		get_action = function() return "none" end,
		get_action_label = function() return "none" end,
		get_action_parameter = function() return nil end,
		get_mode = function() return "single" end,
		get_sensitivity = function() return 1 end,
		get_space_wrap = function() return false end,
	}
end

--- The shortcut engine surface menu_shortcuts reads while building.
--- @return table
local function shortcuts_double()
	return {
		list_shortcuts = function() return {} end,
		is_enabled = function() return true end,
		set_wrap_pairs_getter = function() end,
		is_paused = function() return false end,
	}
end

--- Builds the real tray and records every WARNING/ERROR the build logs.
--- @return table|nil menu, table lines, string|nil err
local function build_tray()
	-- The real LLM row, built by its own module over the doubles its suite uses.
	local llm_item = nil
	require("tests.support.llm_count_menu_fixture")(function(llm_menu)
		llm_item = llm_menu.build_item()
	end)

	local lines = {}
	package.loaded["infra.logger"] = nil
	local real_logger = require("infra.logger")
	local spy = setmetatable({}, { __index = real_logger })
	for _, level in ipairs({ "warn", "error" }) do
		spy[level] = function(module_name, fmt, ...)
			local ok, text = pcall(string.format, fmt, ...)
			lines[#lines + 1] = tostring(module_name) .. ": " .. (ok and text or tostring(fmt))
			return real_logger[level](module_name, fmt, ...)
		end
	end
	package.loaded["infra.logger"] = spy

	local builder = helpers.load_with_stubs("ui.menu.builder")
	local i18n = require("infra.i18n")
	-- Every key resolves to text, the way the real catalogue does: a stub that
	-- echoes keys would make the renderer hide rows a real tray shows.
	local echo = i18n.get
	i18n.get = function(key)
		if type(key) == "string" and key:find("^platform_reason%.") then return "Reason for " .. key end
		if key == "menu.global.config_folder" then return CONFIG_FOLDER end
		return echo(key)
	end
	i18n.build_language_menu_items = function()
		return { { label = "Français", checked = true, action = function() end } }
	end
	local mods = {}
	for key, name in pairs(MENU_MODULES) do
		package.loaded[name] = nil
		mods[key] = require(name)
	end
	local ctx = {
		config     = { log_level = 2 },
		base_dir   = helpers.driver_root(),
		state      = { shortcuts = true, gestures = true, hotstrings = {} },
		hotfiles   = {},
		save_prefs = function() return true end,
		updateMenu = function() end,
		do_reload  = function() end,
		notify_feature = function() end,
		applyTriggerChar = function(text) return text end,
		karabiner  = remap_double(),
		gestures   = gestures_double(),
		shortcuts  = shortcuts_double(),
		llm_handler = { build_item = function() return llm_item end },
	}
	local actions = setmetatable({}, { __index = function() return function() end end })
	local ok, menu = pcall(builder.generate, ctx, mods, actions)
	package.loaded["infra.logger"] = nil
	if not ok then return nil, lines, tostring(menu) end
	return menu, lines, nil
end

--- Walks every row, calling visit(row, path, depth).
--- @param rows table
--- @param visit function
--- @param path string|nil
--- @param depth number|nil
local function walk(rows, visit, path, depth)
	depth = depth or 1
	for index, row in ipairs(rows or {}) do
		if type(row) == "table" then
			local where = (path or "tray") .. "[" .. index .. "]"
			visit(row, where, depth)
			if type(row.menu) == "table" then walk(row.menu, visit, where .. " " .. tostring(row.title), depth + 1) end
		end
	end
end

local MENU, LINES, BUILD_ERROR = build_tray()

helpers.describe("the real macOS tray: every submenu reaches the menu bar populated", function()
	helpers.it("builds without raising", function()
		helpers.assert_nil(BUILD_ERROR, "Builder.generate raised over the real menu modules")
		helpers.assert_true(type(MENU) == "table" and #MENU > 0, "the tray must not be empty")
	end)

	helpers.it("carries every expected submenu", function()
		local top = {}
		for _, row in ipairs(MENU or {}) do
			if type(row.title) == "string" then top[row.title:gsub(" %(.*%)$", "")] = row end
		end
		for _, key in ipairs(EXPECTED_SUBMENUS) do
			local row = top[key]
			helpers.assert_true(row ~= nil, "the tray lost its '" .. key .. "' row")
			helpers.assert_true(type(row.menu) == "table",
				"'" .. key .. "' reached the tray with no submenu at all")
		end
	end)

	helpers.it("no submenu is empty, at any depth", function()
		local empty = {}
		walk(MENU, function(row, where, depth)
			-- Below its own row, the LLM tree is built over its suite's panel
			-- doubles, which answer empty; that suite owns those contents.
			local inside_llm = depth > 1 and where:find("menu.llm.title", 1, true) ~= nil
			if not inside_llm and row.menu ~= nil and (type(row.menu) ~= "table" or #row.menu == 0) then
				empty[#empty + 1] = where .. " '" .. tostring(row.title) .. "'"
			end
		end)
		helpers.assert_eq(#empty, 0, "empty submenus: " .. table.concat(empty, ", "))
	end)

	helpers.it("the renderer lost no row while building", function()
		local lost = {}
		for _, line in ipairs(LINES) do
			for _, marker in ipairs(LOSS_MARKERS) do
				if line:find(marker, 1, true) then lost[#lost + 1] = line end
			end
		end
		helpers.assert_eq(#lost, 0, "rows or subtrees were dropped: " .. table.concat(lost, " | "))
	end)

	helpers.it("has no Karabiner submenu and no row naming the remap engine", function()
		local named = {}
		walk(MENU, function(row, where)
			if type(row.title) == "string" and row.title:lower():find("karabiner", 1, true) then
				named[#named + 1] = where .. " '" .. row.title .. "'"
			end
		end)
		helpers.assert_eq(#named, 0, "the remap engine must stay invisible: " .. table.concat(named, ", "))
	end)

	helpers.it("draws the config folder row once, at the top level", function()
		local found = {}
		walk(MENU, function(row, where, depth)
			if type(row.title) == "string" and row.title:find(CONFIG_FOLDER, 1, true) then
				found[#found + 1] = { where = where, depth = depth }
			end
		end)
		helpers.assert_eq(#found, 1, "the config folder row must appear exactly once")
		helpers.assert_eq(found[1].depth, 1, "the config folder row belongs to the top level, not "
			.. found[1].where)
	end)

	helpers.it("no clickable row is duplicated across two top-level submenus", function()
		local owner = {}
		local duplicated = {}
		for _, top in ipairs(MENU or {}) do
			if type(top.menu) == "table" then
				for _, row in ipairs(top.menu) do
					if type(row.title) == "string" and row.title ~= "-" and type(row.fn) == "function" then
						local first = owner[row.title]
						if first and first ~= top.title then
							duplicated[#duplicated + 1] = row.title .. " (" .. first .. " and " .. top.title .. ")"
						end
						owner[row.title] = owner[row.title] or top.title
					end
				end
			end
		end
		helpers.assert_eq(#duplicated, 0, "rows drawn in two submenus: " .. table.concat(duplicated, ", "))
	end)
end)
