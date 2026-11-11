--- tests/unit/ui/menu/tray/test_tray_every_submenu_populated.lua

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
local CaptionFixture = require("tests.support.hotstrings_parent_caption_fixture")
local LayoutFixture = require("tests.support.layout_legacy_caption_fixture")

-- The menu modules ui/menu/init.lua loads, under the keys Builder.generate reads.
local MENU_MODULES = {
	keyboard_layout = "ui.menu.menu_keyboard_layout",
	hotstrings      = "ui.menu.menu_hotstrings",
	keystats       = "ui.menu.menu_metrics",
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
		get_lone_modifier_tap_max_ms = function() return 1000 end,
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
--- @param observe_layout function|nil Layout observer.
--- @param catalogue table|nil A real locale catalogue to draw the tray from.
--- @return table|nil menu, table lines, string|nil err
local function build_tray(observe_layout, catalogue)
	-- The real LLM row, built by its own module over the doubles its suite uses.
	local llm_item = nil
	require("tests.support.llm_count_menu_fixture")(function(llm_menu)
		llm_item = llm_menu.build_item()
	end, { catalogue = catalogue, real_streaming_panel = true, real_trigger_panel = true })

	local lines = {}
	package.loaded["infra.logger"] = nil
	local real_logger = require("infra.logger")
	helpers.admit_logger_privacy(real_logger)
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
		if catalogue then
			local text = catalogue[key]
			return (text == nil or text == "") and key or text
		end
		if type(key) == "string" and key:find("^platform_reason%.") then return "Reason for " .. key end
		if key == "menu.global.config_folder" then return CONFIG_FOLDER end
		return echo(key)
	end
	if catalogue then
		-- The i18n double decorates its own echo: headers must read the catalogue too.
		i18n.section = function(key) return "— " .. i18n.get(key) .. " —" end
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
		-- Every category on, the Hotstrings master (keymap) included: an off
		-- category greys every row of its submenu (category-off rule).
		state      = { shortcuts = true, gestures = true, keymap = true, hotstrings = {} },
		hotfiles   = {},
		save_prefs = function() return true end,
		updateMenu = function() end,
		do_reload  = function() end,
		notify_feature = function() end,
		applyTriggerChar = function(text) return text end,
		karabiner  = remap_double(),
		gestures   = gestures_double(),
		shortcuts  = shortcuts_double(),
		-- The delimiter catalogue always ships, and the consumption submenu lists it.
		keymap     = {
			get_terminator_defs = function() return { { key = "space", label_key = "menu.hotstrings.consumed" } } end,
			is_terminator_enabled = function() return true end,
			is_terminator_consume = function() return false end,
		},
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

local RowText = require("test.menu_row_text")
local SHARED_ROOT = helpers.driver_root() .. "/../_shared"
-- The whole tray holds many more; fewer means a builder gave up.
local MIN_TRAY_ROWS = 100

helpers.describe("the real macOS tray reads as text", LayoutFixture.scoped(function()
	local decode = require("json").decode

	helpers.it("the walk itself refuses each shape of raw text", function()
		local rows = { { title = "Disposition", menu = {
			{ title = "on_pause" }, { title = "menu.layout.layout_on_pause" },
			{ title = "some_raw_id" }, { title = "Layout {1}" }, { title = "Disposition" },
		} } }
		local defects = RowText.defects(rows, SHARED_ROOT, decode)
		helpers.assert_eq(#defects, 4, "only the plain label may pass: " .. table.concat(defects, " | "))
	end)

	for _, locale in ipairs({ "fr", "en" }) do
		helpers.it("shows no raw id in " .. locale, function()
			local menu, _, build_error = build_tray(nil, RowText.catalogue(SHARED_ROOT, locale, decode))
			helpers.assert_nil(build_error, "the tray must build over the real catalogue")
			local defects, rows = RowText.defects(menu, SHARED_ROOT, decode, locale)
			helpers.assert_true(rows >= MIN_TRAY_ROWS, "the walk stopped early at " .. rows .. " rows")
			helpers.assert_eq(defects, {}, "a row must read as text")
		end)
	end

	helpers.it("reaches every French submenu row joining a label to its value", function()
		local catalogue = RowText.catalogue(SHARED_ROOT, "fr", decode)
		local menu = build_tray(nil, catalogue)
		helpers.assert_eq(RowText.missing_label_value_rows(menu, SHARED_ROOT, decode, catalogue, "hs"), {})
	end)
end))

helpers.describe("the real macOS tray: every submenu reaches the menu bar populated", LayoutFixture.scoped(function()
	local MENU, LINES, BUILD_ERROR = build_tray()
	helpers.it("builds without raising", function()
		helpers.assert_nil(BUILD_ERROR, "Builder.generate raised over the real menu modules")
		helpers.assert_true(type(MENU) == "table" and #MENU > 0, "the tray must not be empty")
	end)

	helpers.it("carries every expected submenu", function()
		-- The AI title carries the health dot the manifest declares; the key
		-- identity is the title without it.
		local dots = {}
		local MenuLayout = require("ui.menu.menu_llm.menu_layout")
		for _, status in ipairs({ "ready", "warming", "unreachable" }) do
			dots[#dots + 1] = MenuLayout.title_health_dot(status)
		end
		local top = {}
		for _, row in ipairs(MENU or {}) do
			if type(row.title) == "string" then
				local title = row.title
				for _, dot in ipairs(dots) do
					if title:sub(-(#dot + 1)) == " " .. dot then title = title:sub(1, -(#dot + 2)) end
				end
				top[(title:gsub(" %(.*%)$", ""))] = row
			end
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

	helpers.it("names Karabiner in no row of the tray", function()
		-- Ergopti runs its own remapping runtime (ADR 011), so the two Configuration
		-- rows that switched and removed it in the user's Karabiner-Elements are
		-- gone, and the remap engine stays invisible everywhere.
		local named = {}
		walk(MENU, function(row, where)
			if type(row.title) == "string" and row.title:lower():find("karabiner", 1, true) then
				named[#named + 1] = where .. " '" .. row.title .. "'"
			end
		end)
		helpers.assert_eq(#named, 0, "the remap engine must stay invisible: " .. table.concat(named, ", "))
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
			"-",
			i18n.get("menu.debug.proxy_override"),
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
end))


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

--- Runs checks over the real tray modules, read through the branch decorator.
--- @param run fun(builder, rows, mods, ctx, actions) The checks.
local function with_branch_rows(run)
	build_tray(function(_, mods, ctx)
		local actions = setmetatable({}, { __index = function() return function() end end })
		package.loaded["ui.menu.branch_rows"] = nil
		local rows = require("ui.menu.branch_rows").new()
		run(package.loaded["ui.menu.builder"], rows, rows.wrap(mods), ctx, actions)
	end)
end

--- Builds the tree with one branch asked to rebuild alone.
--- @return table rendered
local function branch_build(builder, rows, mods, ctx, actions, key)
	rows.request(key)
	local rendered = builder.generate(ctx, mods, actions)
	rows.settle()
	return rendered
end

--- The visible shape of a rendered tree: titles, ticks, greying, nesting.
--- @param rendered table Rendered rows.
--- @return table shape
local function shape(rendered)
	local out = {}
	for index, row in ipairs(rendered or {}) do
		out[index] = { row.title, row.checked == true, row.disabled == true, row.menu and shape(row.menu) or false }
	end
	return out
end

--- Counts the calls of the original menu modules' build behind the decorator.
--- @param originals table Original menu modules.
--- @param keys table Module keys.
--- @return table counts, function restore
local function count_builds(originals, keys)
	local counts, builds = {}, {}
	for _, key in ipairs(keys) do
		counts[key], builds[key] = 0, originals[key].build
		originals[key].build = function(...) counts[key] = counts[key] + 1; return builds[key](...) end
	end
	return counts, function() for key, build in pairs(builds) do originals[key].build = build end end
end

helpers.describe("the real macOS tray: a toggle rebuilds its own branch alone", LayoutFixture.scoped(function()
	helpers.it("(menu-branch-refresh) rebuilds only the asked branch and renders the full tree's rows", function()
		build_tray(function(_, originals, ctx)
			local counts, restore = count_builds(originals, { "tap_holds", "gestures", "shortcuts", "keystats" })
			package.loaded["ui.menu.branch_rows"] = nil
			local rows = require("ui.menu.branch_rows").new()
			local mods = rows.wrap(originals)
			local builder = package.loaded["ui.menu.builder"]
			local actions = setmetatable({}, { __index = function() return function() end end })
			local full = builder.generate(ctx, mods, actions)
			local branch = branch_build(builder, rows, mods, ctx, actions, "tap_holds")
			restore()
			helpers.assert_eq(counts, { tap_holds = 2, gestures = 1, shortcuts = 1, keystats = 1 })
			helpers.assert_eq(shape(branch), shape(full), "the reused branches render as a full rebuild does")
			full = builder.generate(ctx, mods, actions)
			helpers.assert_eq(shape(full), shape(branch), "a settled request leaves the next build full")
		end)
	end)

	helpers.it("(menu-branch-refresh) a new state in the rebuilt branch reaches the tree", function()
		build_tray(function(_, originals, ctx)
			local before = originals.gestures.build
			package.loaded["ui.menu.branch_rows"] = nil
			local rows = require("ui.menu.branch_rows").new()
			local mods = rows.wrap(originals)
			local builder = package.loaded["ui.menu.builder"]
			local actions = setmetatable({}, { __index = function() return function() end end })
			builder.generate(ctx, mods, actions)
			originals.gestures.build = function(...)
				local row = before(...)
				row.label = "Gestures, rebuilt"
				return row
			end
			mods = rows.wrap(originals)
			local branch = branch_build(builder, rows, mods, ctx, actions, "gestures")
			originals.gestures.build = before
			local seen = false
			for _, row in ipairs(branch) do seen = seen or row.title == "Gestures, rebuilt" end
			helpers.assert_true(seen, "the rebuilt branch is the one the tree shows")
		end)
	end)

	helpers.it("(menu-branch-refresh-refused) a pause flip, no earlier build or a global branch rebuilds all", function()
		build_tray(function(_, originals, ctx)
			local counts, restore = count_builds(originals, { "tap_holds", "gestures" })
			package.loaded["ui.menu.branch_rows"] = nil
			local BranchRows = require("ui.menu.branch_rows")
			local rows = BranchRows.new()
			local mods = rows.wrap(originals)
			local builder = package.loaded["ui.menu.builder"]
			local actions = setmetatable({}, { __index = function() return function() end end })
			branch_build(builder, rows, mods, ctx, actions, "tap_holds")
			helpers.assert_eq(counts.gestures, 1, "no earlier build: everything is built")
			ctx.paused = true
			branch_build(builder, rows, mods, ctx, actions, "tap_holds")
			helpers.assert_eq(counts.gestures, 2, "a pause flip greys every feature branch")
			ctx.paused = nil
			restore()
			helpers.assert_eq(pcall(rows.request, "keyboard_layout"), false, "a layout choice reaches every branch")
			helpers.assert_nil(BranchRows.BRANCH_LOCAL.llm)
		end)
	end)

	helpers.it("(menu-branch-refresh) names the branch of a top-level title, none for a global one", function()
		with_branch_rows(function(builder, rows, mods, ctx, actions)
			local menu = builder.generate(ctx, mods, actions)
			local found = {}
			for _, row in ipairs(menu) do
				if type(row.title) == "string" then found[row.title] = rows.branch_of(row.title) end
			end
			helpers.assert_eq(found["menu.tapholds.title"], "tap_holds")
			helpers.assert_eq(found["menu.gestures.title"], "gestures")
			helpers.assert_nil(found["menu.global.language"], "a language choice reaches every branch")
			helpers.assert_nil(found["menu.layout.title"], "a layout choice reaches every branch")
			helpers.assert_nil(rows.branch_of(nil))
		end)
	end)
end))
