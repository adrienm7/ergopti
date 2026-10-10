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
local runtime_inputs
helpers, runtime_inputs = require("tests.support.remap_menu_runtime_inputs").bind(helpers)
local CaptionFixture = require("tests.support.hotstrings_parent_caption_fixture")
local LayoutFixture = require("tests.support.layout_legacy_caption_fixture")

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

-- The Hotstrings parent uses its independent English caption; other legacy labels remain key oracles.
local EXPECTED_SUBMENUS = {
	"menu.layout.title", "⚡ Hotstrings", "menu.metrics.title",
	"menu.shortcuts.title", "menu.tapholds.title", "menu.gestures.title",
	"menu.apps.title", "menu.llm.title", "menu.configuration.title", "menu.global.language",
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
	-- A control no click can reach: an action on a row that opens a submenu, or a
	-- category shown without its switch.
	"carries both an `action`", "category switch",
}

--- A platform.remap double: every getter answers, every engine call raises.
--- @return table
local function remap_double()
	return {
		get_runtime = runtime_inputs.get_runtime,
		shared_runtime_selected = runtime_inputs.shared_runtime_selected,
		runtime_unavailable_reason = runtime_inputs.runtime_unavailable_reason,
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Special", holdable = true, tappable = true },
			{ id = "ctrl", label = "Ctrl", category = "Modifiers", holdable = true, tappable = false },
		},
		TAP_HOLD_KEYS = { { id = "left_shift", label = "Left Shift" }, { id = "return_or_enter", label = "Enter" } },
		MOD_COMBOS = { { id = "shift_pair", label = "Shift pair", group = "Shift",
			from = { simultaneous = { { key_code = "left_shift" }, { key_code = "right_shift" } } } } },
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
local function build_tray(observe_layout)
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

	helpers.load_with_stubs("ui.menu.builder")
	local i18n = require("infra.i18n")
	CaptionFixture.install(i18n)
	LayoutFixture.install(i18n)
	package.loaded["ui.menu.builder"] = nil
	local builder = require("ui.menu.builder")
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
	local cleanup = observe_layout and observe_layout(require("infra.manifest_menu"), mods, ctx)
	local ok, menu = pcall(builder.generate, ctx, mods, actions)
	if cleanup then cleanup() end
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

helpers.describe("the real macOS tray: every submenu reaches the menu bar populated", LayoutFixture.scoped(helpers.scoped_runtime_inputs(function()
	local MENU, LINES, BUILD_ERROR = build_tray()
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

	helpers.it("names Karabiner only in the two Configuration rows that own the switch", function()
		-- F2 made « Ergopti uses Karabiner » an explicit switch with its removal
		-- command; everywhere else the remap engine stays invisible.
		local i18n = require("infra.i18n")
		local allowed = {
			[i18n.get("menu.global.karabiner_integration")] = true,
			[i18n.get("menu.global.remove_from_karabiner")] = true,
		}
		local named = {}
		local allowed_seen = 0
		local runtime_caption = i18n.get("menu.global.karabiner_runtime.shared")
		local runtime_seen = 0
		walk(MENU, function(row, where, depth)
			if type(row.title) == "string" and row.title:lower():find("karabiner", 1, true) then
				local in_configuration = depth == 2
					and where:find(i18n.get("menu.configuration.title"), 1, true) ~= nil
				if row.title == runtime_caption and in_configuration then
					runtime_seen = runtime_seen + 1
					helpers.assert_eq(row.disabled, true, "shared runtime status is informational")
					helpers.assert_nil(row.fn, "shared runtime status has no callback")
					helpers.assert_nil(row.checked, "shared runtime status has no tick")
				elseif allowed[row.title] and in_configuration then
					allowed_seen = allowed_seen + 1
				else
					named[#named + 1] = where .. " '" .. row.title .. "'"
				end
			end
		end)
		helpers.assert_eq(#named, 0, "the remap engine must stay invisible: " .. table.concat(named, ", "))
		helpers.assert_eq(allowed_seen, 2, "the switch and its removal command must be drawn")
		helpers.assert_eq(runtime_seen, 1, "the exact shared runtime status appears once in Configuration")
	end)

	helpers.it("draws the config folder row once, in the Configuration submenu", function()
		local found = {}
		walk(MENU, function(row, where, depth)
			if type(row.title) == "string" and row.title:find(CONFIG_FOLDER, 1, true) then
				found[#found + 1] = { where = where, depth = depth }
			end
		end)
		helpers.assert_eq(#found, 1, "the config folder row must appear exactly once")
		helpers.assert_eq(found[1].depth, 2, "the config folder row belongs to the Configuration "
			.. "submenu, not " .. found[1].where)
		helpers.assert_true(found[1].where:find("menu.configuration.title", 1, true) ~= nil
			or found[1].where:find(require("infra.i18n").get("menu.configuration.title"), 1, true) ~= nil,
			"the config folder row must sit under Configuration, not " .. found[1].where)
	end)

	helpers.it("no clickable row is duplicated across two top-level submenus", function()
		-- Restore and clear read one shared label in every section on purpose:
		-- each row acts on its own section, and one wording is the decision.
		local i18n = require("infra.i18n")
		local shared_labels = {
			[i18n.get("common.restore_recommended")] = true,
			[i18n.get("common.clear_to_system")] = true,
		}
		local owner = {}
		local duplicated = {}
		for _, top in ipairs(MENU or {}) do
			if type(top.menu) == "table" then
				for _, row in ipairs(top.menu) do
					if type(row.title) == "string" and row.title ~= "-" and type(row.fn) == "function"
						and not shared_labels[row.title] then
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

	--- The submenu of the top-level row whose title starts with `key`'s text.
	--- @param key string i18n key of the top-level row.
	--- @return table|nil
	local function top_submenu(key)
		local text = require("infra.i18n").get(key)
		for _, row in ipairs(MENU or {}) do
			if type(row.title) == "string" and row.title:sub(1, #text) == text then return row.menu end
		end
		return nil
	end

	helpers.it("hotstrings: the language packs sit under their own header, flag first", function()
		-- The language row was a bare « Français (n) » among the neutral
		-- categories, which users read as one more category and overlooked.
		local rows = top_submenu("menu.hotstrings.title")
		helpers.assert_true(type(rows) == "table", "the tray must carry the hotstrings submenu")
		local at
		for index, row in ipairs(rows) do
			if type(row.title) == "string" and row.title:find("Français", 1, true) then at = index end
		end
		helpers.assert_true(at ~= nil, "the French language pack row must be drawn")
		helpers.assert_eq(rows[at].title:sub(1, #"🇫🇷 Français"), "🇫🇷 Français",
			"the language row starts with the locale's flag, from the shared locale table")
		helpers.assert_eq(rows[at - 1].title, require("infra.i18n").section("menu.hotstrings.header_languages"),
			"a « Hotstrings par langue » header must precede the language rows")
		helpers.assert_eq(rows[at - 2].title, "-", "and a separator must precede that header")
	end)

	helpers.it("configuration: the rows that rewrite the file come before the windows", function()
		local rows = top_submenu("menu.configuration.title")
		helpers.assert_true(type(rows) == "table", "the tray must carry the Configuration submenu")
		local i18n = require("infra.i18n")
		local drawn = {}
		for index, row in ipairs(rows) do drawn[index] = row.title end
		helpers.assert_eq(table.concat(drawn, " | "), table.concat({
			i18n.get("common.restore_recommended"),
			i18n.get("common.clear_to_system"),
			"-",
			i18n.get("menu.global.clean_unused_keys"),
			"-",
			CONFIG_FOLDER,
			i18n.get("menu.global.setup_wizard"),
			i18n.get("menu.global.karabiner_runtime.shared"),
			i18n.get("menu.global.runtime_recover_shared") .. " — " .. i18n.get("healthcheck.state.unavailable"),
			i18n.get("menu.global.karabiner_integration"),
			i18n.get("menu.global.remove_from_karabiner"),
		}, " | "))
	end)

	-- Uninstall moved from the bottom of Configuration to the bottom of the
	-- Version / Updates submenu, after a separator. On a source run, which is
	-- what the suite is unless it stubs the updater, the row stays there greyed
	-- and names why: « label — head of the reason ».
	helpers.it("about: Uninstall closes the submenu, after a separator", function()
		local rows = top_submenu("menu.about.title")
		helpers.assert_true(type(rows) == "table" and #rows >= 2, "the tray must carry the About submenu")
		local i18n = require("infra.i18n")
		local source_run = require("modules.updater").is_local_source()
		local label = i18n.get("menu.global.uninstall")
		if source_run then
			local reason = i18n.get("menu.about.source_run_reason")
			local cut = nil
			for _, mark in ipairs({ ":", "\239\188\154" }) do
				local at = reason:find(mark, 1, true)
				if at and (cut == nil or at < cut) then cut = at end
			end
			label = label .. " — " .. ((cut and reason:sub(1, cut - 1) or reason):gsub("^%s+", ""):gsub("%s+$", ""))
		end
		helpers.assert_eq(rows[#rows].title, label)
		helpers.assert_eq(rows[#rows].disabled == true, source_run, "greyed exactly on a source run")
		helpers.assert_eq(rows[#rows - 1].title, i18n.get("menu.global.start_at_login"),
			"startup immediately precedes Uninstall")
		helpers.assert_eq(rows[#rows - 2].title, "-", "a separator sets the installation group apart")
	end)
end)))


helpers.describe("actual canonical Layout parent receives its completed module (fixed-layout-parent-native)", LayoutFixture.scoped(function()
	local function layout_row(rows, title)
		for _, row in ipairs(rows or {}) do if row.title == title then return row end end
	end
	helpers.it("reads canonical parent caption and retains absent check and original child callbacks (fixed-layout-parent-native)", function()
		local completed, snapshots, count = nil, {}, 0
		local menu, _, err = build_tray(function(renderer, mods)
			local parent
			for _, row in ipairs(renderer.get_array("top_level")) do if row.id == "keyboard_layout" then parent = row end end
			assert(parent)
			local caption, original_build = parent.i18n, mods.keyboard_layout.build
			parent.i18n = "button.ok"
			mods.keyboard_layout.build = function(ctx)
				count = count + 1
				local original = original_build(ctx)
				assert(type(original) == "table" and type(original.submenu) == "table")
				completed = original.submenu
				for index, child in ipairs(completed) do
					snapshots[index] = {title = child.title, fn = child.fn, menu = child.menu,
						checked = child.checked, disabled = child.disabled}
				end
				return original
			end
			return function() parent.i18n = caption; mods.keyboard_layout.build = original_build end
		end)
		helpers.assert_nil(err); helpers.assert_eq(count, 1)
		local parent = assert(layout_row(menu, "button.ok"), "canonical receiving caption must reach the native tray")
		helpers.assert_nil(parent.checked, "the original Mac parent has no enable tick")
		helpers.assert_nil(parent.fn); helpers.assert_eq(#parent.menu, #completed)
		for index, child in ipairs(parent.menu) do
			helpers.assert_eq(child.title, snapshots[index].title)
			helpers.assert_true(rawequal(child.fn, snapshots[index].fn))
			helpers.assert_true(rawequal(child.menu, snapshots[index].menu))
			helpers.assert_eq(child.checked, snapshots[index].checked)
			helpers.assert_eq(child.disabled, snapshots[index].disabled)
		end
	end)
	helpers.it("refuses before actual module construction when canonical parent kind is withdrawn (fixed-layout-parent-native)", function()
		local calls = 0
		local menu, _, err = build_tray(function(renderer, mods)
			local parent
			for _, row in ipairs(renderer.get_array("top_level")) do if row.id == "keyboard_layout" then parent = row end end
			assert(parent)
			local kind, original_build = parent.type, mods.keyboard_layout.build
			parent.type = "command"
			mods.keyboard_layout.build = function(ctx) calls = calls + 1; return original_build(ctx) end
			return function() parent.type = kind; mods.keyboard_layout.build = original_build end
		end)
		helpers.assert_nil(err); helpers.assert_eq(calls, 0, "refusal precedes the real Layout module")
		helpers.assert_nil(layout_row(menu, "menu.layout.title"))
	end)
end))
