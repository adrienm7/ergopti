--- tests/meta/test_menu_top_level_drift_gate.lua

--- ==============================================================================
--- MODULE: Menu Top-Level Drift Gate (macOS)
--- DESCRIPTION:
--- Renders the tray root through Builder.generate and compares the rows it
--- draws, separators included, with the manifest's `top_level` array projected
--- for the "hs" platform.
---
--- WHY IT RENDERS INSTEAD OF COMPARING TWO LISTS.
--- This gate used to pin the manifest against a hand-typed list of ids, which
--- alarms on a manifest edit and says nothing about the driver. The driver was
--- where the drift lived: the feature rows were a fixed sequence of calls in
--- Builder.generate and only the rows from `global_actions` onward were read
--- from the manifest, so a reordered top level, a separator among the feature
--- rows or a renamed anchor left this tray in its old order, or emptied its
--- tail altogether.
---
--- The second scenario renders a manifest whose top level is shuffled, with a
--- separator inside the former head. A driver that places any row itself fails
--- it even when the shipped manifest happens to match its fixed order.
---
--- The AHK half lives in windows/tests/meta/test_menu_top_level_drift_gate.ahk,
--- and tools/test/test-menu-top-level-parity.cjs holds the three builder tables
--- to the same projection.
--- ==============================================================================

local helpers = require("tests.helpers")
local ManifestFixture = require("tests.support.manifest_menu_fixture")

-- The title key each top-level row draws, so a rendered row can be named by the
-- manifest id it stands for. An id the manifest declares for macOS and this
-- table does not know fails the gate: it has to be named here to be compared.
local TITLE_KEYS = {
	keyboard_layout = "menu.layout.title",
	hotstrings      = "menu.hotstrings.title",
	llm             = "menu.llm.title",
	agent           = "menu.agent.title",
	metrics         = "menu.metrics.title",
	shortcuts       = "menu.shortcuts.title",
	tap_holds       = "menu.tapholds.title",
	gestures        = "menu.gestures.title",
	apps            = "menu.apps.title",
	configuration   = "menu.configuration.title",
	language        = "menu.global.language",
	about           = "menu.about.title",
	reload          = "menu.global.reload_macos",
	quit            = "menu.global.quit_macos",
	debug           = "menu.debug.title",
}

local SEPARATOR = "---"
local MANIFEST_RELATIVE = "modules/menu/menu_manifest.json"




-- =============================================
-- =============================================
-- ======= 1/ The manifest's projection ========
-- =============================================
-- =============================================

--- Reads the shipped menu manifest as text.
--- @return string raw JSON text.
local function read_manifest_text()
	local fh = io.open(helpers.shared(MANIFEST_RELATIVE), "r")
	helpers.assert_true(fh ~= nil, "Cannot open menu_manifest.json")
	local raw = fh:read("*a")
	fh:close()
	return raw
end

--- Projects a top_level array for macOS: the rows it may see, in order, with a
--- separator kept only between two rows, as every tray draws it.
--- @param top_level table Decoded top_level array.
--- @return table ids Ordered ids, separators as "---".
local function project_for_hs(top_level)
	local out = {}
	for _, row in ipairs(top_level) do
		local visible = type(row.platforms) ~= "table"
		for _, platform in ipairs(type(row.platforms) == "table" and row.platforms or {}) do
			if platform == "hs" then visible = true end
		end
		if visible then
			if row.id == SEPARATOR then
				if #out > 0 and out[#out] ~= SEPARATOR then out[#out + 1] = SEPARATOR end
			else
				out[#out + 1] = row.id
			end
		end
	end
	while out[#out] == SEPARATOR do out[#out] = nil end
	return out
end

--- Replaces the top_level array of a manifest text, leaving every other menu
--- byte for byte as shipped.
--- @param raw string Manifest JSON text.
--- @param rows table Replacement top_level rows.
--- @return string Manifest JSON text.
local function with_top_level(raw, rows)
	local key_at = raw:find('"top_level"', 1, true)
	helpers.assert_true(key_at ~= nil, "the manifest must carry a top_level array")
	local open_at = raw:find("[", key_at, true)
	local depth, close_at = 0, nil
	for index = open_at, #raw do
		local char = raw:sub(index, index)
		if char == "[" then depth = depth + 1 end
		if char == "]" then
			depth = depth - 1
			if depth == 0 then close_at = index; break end
		end
	end
	helpers.assert_true(close_at ~= nil, "the top_level array must be closed")
	local encoded = {}
	for index, row in ipairs(rows) do encoded[index] = hs.json.encode(row) end
	return raw:sub(1, open_at) .. table.concat(encoded, ",") .. raw:sub(close_at)
end




-- =============================================
-- =============================================
-- ======= 2/ Rendering the tray root ==========
-- =============================================
-- =============================================

--- A logger that runs builders for real and records every WARNING and ERROR.
--- @param lines table Receives the recorded lines.
--- @return table logger
local function recording_logger(lines)
	local logger = helpers.make_logger_stub()
	for _, level in ipairs({ "warn", "error" }) do
		logger[level] = function(module_name, fmt, ...)
			local ok, text = pcall(string.format, fmt, ...)
			lines[#lines + 1] = tostring(module_name) .. ": " .. (ok and text or tostring(fmt))
		end
	end
	logger.build = function(_, _, fn, arg)
		local ok, result = pcall(fn, arg)
		return ok and result or nil
	end
	-- The Debug submenu's log-level picker reads the level table and the level
	-- in force.
	logger.LEVELS = { DEBUG = 1, INFO = 2, WARNING = 3, ERROR = 4 }
	logger.current_level = logger.LEVELS.WARNING
	return logger
end

--- One feature row, as a menu module hands it to the builder.
--- @param key string Title key.
--- @return table row
local function stub_row(key)
	return {
		label = require("infra.i18n").get(key),
		submenu = { { title = "row", fn = function() end } },
	}
end

--- Captures the genuine native locale provider before the manifest fixture redirects Paths.
--- Its real module closes the generated catalogue, active locale and original setter callbacks.
--- @return function The actual initialized language-row provider.
local function native_language_provider()
	return helpers.with_stub_scope({
		"infra.i18n", "infra.locale", "locale.core", "menu.labels", "_generated.locale_table",
		"adapters.storage", "adapters.timer_scheduler",
	}, function()
		helpers.load_with_stubs("infra.i18n")
		rawset(package.loaded, "infra.i18n", nil)
		local native = require("infra.i18n")
		native.init()
		assert(type(native.build_language_menu_items) == "function", "actual native locale provider exists")
		assert(#native.get_sorted_locales() == 21, "actual generated locale catalogue is complete")
		return native.build_language_menu_items
	end)
end

--- Renders the tray root over the manifest text given.
--- @param manifest_text string Manifest JSON text.
--- @param paused boolean|nil Whether the script is paused.
--- @return table rows Rendered top-level rows, the title badge removed.
--- @return table lines Recorded warnings and errors.
local function render_root(manifest_text, paused, command_actions)
	local language_provider = native_language_provider()
	local lines = {}
	local rendered = ManifestFixture.with_manifest(manifest_text, recording_logger(lines), function()
		local builder = helpers.load_with_stubs("ui.menu.builder")
		require("infra.i18n").build_language_menu_items = language_provider
		local build = function(key) return { build = function() return stub_row(key) end } end
		local mods = {
			keyboard_layout = build("menu.layout.title"),
			hotstrings      = {},
			keylogger       = build("menu.metrics.title"),
			shortcuts       = build("menu.shortcuts.title"),
			tap_holds       = build("menu.tapholds.title"),
			gestures        = build("menu.gestures.title"),
			apps            = build("menu.apps.title"),
			about           = build("menu.about.title"),
		}
		local ctx = {
			paused         = paused == true,
			config         = { log_level = 2 },
			hotfiles       = {},
			state          = { hotstrings = {} },
			save_prefs     = function() return true end,
			updateMenu     = function() end,
			notify_feature = function() end,
			llm_handler    = {
				build_item = function() return stub_row("menu.llm.title") end,
				build_agent_item = function() return stub_row("menu.agent.title") end,
			},
		}
		local actions = command_actions or setmetatable({}, { __index = function() return function() end end })
		return builder.generate(ctx, mods, actions)
	end)
	helpers.assert_true(type(rendered) == "table" and #rendered > 2, "Builder.generate drew no tray")
	-- The title badge is an image row prepended after the render, with its own
	-- separator; it is no manifest row.
	helpers.assert_eq(rendered[1].title, "", "the tray must open with its title badge")
	helpers.assert_eq(rendered[2].title, "-", "a separator must follow the title badge")
	local rows = {}
	for index = 3, #rendered do rows[#rows + 1] = rendered[index] end
	return rows, lines
end

--- Strips a leading symbol token (emoji, arrow) and its spaces from a label.
--- Reload and Quit replace the catalogue's emoji with a menubar-safe symbol, so
--- the words are what identifies the row.
--- @param text string Label.
--- @return string Label without its leading symbol.
local function without_symbol(text)
	return (text:gsub("^[\128-\255]+%s+", ""))
end

--- Names a rendered row by the manifest id whose title it draws. The stubbed
--- catalogue the builder renders with echoes keys, and a real one translates
--- them, so both spellings of a title name its row.
--- @param row table Rendered row.
--- @return string id, or "?<title>" when no title key matches.
local function id_of(row)
	if row.title == "-" then return SEPARATOR end
	local title = without_symbol(tostring(row.title))
	local i18n = require("infra.i18n")
	for id, key in pairs(TITLE_KEYS) do
		for _, expected in ipairs({ key, without_symbol(i18n.get(key)) }) do
			-- The Hotstrings title carries its live count: « ⚡ Hotstrings (123) ».
			if title == expected or title:sub(1, #expected + 2) == expected .. " (" then return id end
			if id == "agent" and row.disabled == true and row.fn == nil and row.menu == nil then
				for _, reason in ipairs({ "menu.agent.not_ready", i18n.get("menu.agent.not_ready") }) do
					if title == expected .. " — " .. reason then return id end
				end
			end
		end
	end
	return "?" .. tostring(row.title)
end

--- Asserts that the rendered root draws exactly the projected sequence.
--- @param rows table Rendered rows.
--- @param expected table Projected ids.
--- @param scenario string Scenario name for the message.
local function assert_same_order(rows, expected, scenario)
	local drawn = {}
	for index, row in ipairs(rows) do drawn[index] = id_of(row) end
	helpers.assert_eq(table.concat(drawn, ", "), table.concat(expected, ", "),
		scenario .. ": the tray root must draw the manifest's top level, separators included")
end




-- ======================================
-- ======================================
-- ======= 3/ Scenarios =================
-- ======================================
-- ======================================

helpers.describe("menu drift gate (macOS): the tray root is the manifest's top level", function()
	local raw = read_manifest_text()
	local top_level = hs.json.decode(raw).top_level

	helpers.it("every top-level row declared for macOS has a title this gate can name", function()
		local expected = project_for_hs(top_level)
		local rows = 0
		local unnamed = {}
		for _, id in ipairs(expected) do
			if id ~= SEPARATOR then
				rows = rows + 1
				if TITLE_KEYS[id] == nil then unnamed[#unnamed + 1] = id end
			end
		end
		-- Floors the projection: a parse that read nothing would pass every
		-- comparison below vacuously.
		helpers.assert_true(rows >= 10, "the manifest must declare at least ten rows for macOS, got " .. rows)
		helpers.assert_eq(#unnamed, 0, "add a title key for: " .. table.concat(unnamed, ", "))
	end)

	helpers.it("the shipped manifest renders in its declared order", function()
		local rows, lines = render_root(raw)
		assert_same_order(rows, project_for_hs(top_level), "shipped manifest")
		local missing = {}
		for _, line in ipairs(lines) do
			if line:find("No builder for top-level row", 1, true) then missing[#missing + 1] = line end
		end
		helpers.assert_eq(#missing, 0, "rows with no builder: " .. table.concat(missing, " | "))
	end)

	helpers.it("a reordered manifest reorders the tray, separators included", function()
		-- Reversed, then a separator added right after the first row, so rows
		-- that were the fixed head now sit after the former tail and a
		-- separator lands where no fixed sequence would put one.
		local shuffled = {}
		for index = #top_level, 1, -1 do shuffled[#shuffled + 1] = top_level[index] end
		table.insert(shuffled, 2, { id = SEPARATOR })
		local expected = project_for_hs(shuffled)
		helpers.assert_true(expected[1] ~= project_for_hs(top_level)[1],
			"the shuffled top level must start with a different row")
		local rows = render_root(with_top_level(raw, shuffled))
		assert_same_order(rows, expected, "shuffled manifest")
	end)

	helpers.it("a pause greys exactly the rows the manifest marks, wherever they sit", function()
		-- The mark moves from Metrics to Language here. A driver that keeps its
		-- own list of the feature ids keeps greying Metrics and leaves Language
		-- live, so it fails even while its list matches the shipped manifest.
		local marked = 0
		local moved = {}
		for index, row in ipairs(top_level) do
			local copy = {}
			for key, value in pairs(row) do copy[key] = value end
			if copy.greyed_when_paused == true then marked = marked + 1 end
			if copy.id == "metrics" then copy.greyed_when_paused = nil end
			if copy.id == "language" then copy.greyed_when_paused = true end
			moved[index] = copy
		end
		helpers.assert_true(marked >= 7,
			"the manifest must mark the feature rows a pause greys, got " .. marked)
		local expected = {}
		for _, id in ipairs(project_for_hs(moved)) do
			for _, row in ipairs(moved) do
				if row.id == id and row.greyed_when_paused == true then expected[#expected + 1] = id end
			end
		end
		local rows = render_root(with_top_level(raw, moved), true)
		local greyed = {}
		for _, row in ipairs(rows) do
			if row.title ~= "-" and row.disabled == true then greyed[#greyed + 1] = id_of(row) end
		end
		helpers.assert_eq(table.concat(greyed, ", "), table.concat(expected, ", "),
			"a pause must grey the rows the manifest marks, and only those")
	end)
end)

--- Gives the two native lifecycle owners independently declared presentation.
local function lifecycle_manifest(mutator)
	local raw = read_manifest_text()
	local rows = hs.json.decode(raw).top_level
	for _, row in ipairs(rows) do
		if row.id == "reload" or row.id == "quit" then
			row.type = "command"
			row.i18n = row.id == "reload" and "button.cancel" or "button.ok"
			-- The canonical declaration now owns the original icon decoration too.
			row.label_prefix = row.id == "reload" and "↺ " or "✕ "
			if mutator then mutator(row) end
		end
	end
	return with_top_level(raw, rows)
end

local function lifecycle_row(rows, glyph, key)
	local expected = glyph .. " " .. key
	for _, row in ipairs(rows) do
		if row.title == expected then return row end
	end
end

helpers.describe("shared lifecycle commands (macOS)", function()
	helpers.it("uses declared labels while paused and preserves the native owners (shared-lifecycle)", function()
		local calls = {}
		local rows = render_root(lifecycle_manifest(), true, {
			reload = function() calls[#calls + 1] = "reload"; return false end,
			quit = function() calls[#calls + 1] = "quit"; return true end,
		})
		local reload = lifecycle_row(rows, "↺", "button.cancel")
		local quit = lifecycle_row(rows, "✕", "button.ok")
		helpers.assert_not_nil(reload, "the shared reload declaration owns the translated label")
		helpers.assert_not_nil(quit, "the shared quit declaration owns the translated label")
		helpers.assert_true(reload.disabled ~= true and quit.disabled ~= true, "lifecycle remains available during pause")
		helpers.assert_eq(reload.fn(), false, "native refusal remains refusal")
		helpers.assert_eq(quit.fn(), true, "native acknowledgement is forwarded")
		helpers.assert_eq(table.concat(calls, ","), "reload,quit")
	end)

	helpers.it("does not draw commands without their callable owners (shared-lifecycle)", function()
		local rows = render_root(lifecycle_manifest(), false, { reload = false, quit = {} })
		helpers.assert_nil(lifecycle_row(rows, "↺", "button.cancel"))
		helpers.assert_nil(lifecycle_row(rows, "✕", "button.ok"))
		for _, row in ipairs(rows) do
			helpers.assert_true(row.title:sub(1, #"↺ ") ~= "↺ " and row.title:sub(1, #"✕ ") ~= "✕ ",
				"missing owners cannot leave a relabelled or original native lifecycle row")
		end
	end)

	helpers.it("rechecks an unregistered declared readiness predicate on held delivery (shared-lifecycle)", function()
		local calls = 0
		local rows = render_root(lifecycle_manifest(function(row)
			row.i18n = "menu.global." .. row.id
			row.disabled_when = { "unregistered_lifecycle_owner" }
		end), false, { reload = function() calls = calls + 1 end, quit = function() calls = calls + 1 end })
		local reload = lifecycle_row(rows, "↺", "menu.global.reload")
		local quit = lifecycle_row(rows, "✕", "menu.global.quit")
		helpers.assert_not_nil(reload, "the shared reload row is present before readiness is inspected")
		helpers.assert_not_nil(quit, "the shared quit row is present before readiness is inspected")
		helpers.assert_true(reload.disabled == true and quit.disabled == true)
		helpers.assert_eq(reload.fn(), false)
		helpers.assert_eq(quit.fn(), false)
		helpers.assert_eq(calls, 0, "disabled presentation cannot conceal a callable native bypass")
	end)
end)

helpers.describe("topology fixture owns genuine native Language data", function()
	helpers.it("retains all original native locale rows and restores its private reader cohort", function()
		local names = { "infra.i18n", "infra.locale", "locale.core", "menu.labels", "_generated.locale_table",
			"adapters.storage", "adapters.timer_scheduler", "infra.paths", "infra.logger" }
		local saved, old_hs = {}, rawget(_G, "hs")
		for _, name in ipairs(names) do saved[name] = rawget(package.loaded, name) end
		local provider = native_language_provider()
		for _, name in ipairs(names) do
			helpers.assert_true(rawequal(rawget(package.loaded, name), saved[name]), name .. " exact entry restored")
		end
		helpers.assert_true(rawequal(rawget(_G, "hs"), old_hs), "native fixture globals restored")
		local file = assert(io.open(helpers.shared("tests/corpus/menus/language_parent.json"), "rb"))
		local raw = assert(file:read("*a")); assert(file:close())
		local corpus = assert(require("adapters.json_codec").decode(raw))
		local rows = provider()
		helpers.assert_eq(#rows, #corpus.locales, "a genuine complete catalogue is not an empty stand-in")
		for index, expected in ipairs(corpus.locales) do
			helpers.assert_eq(rows[index].label, expected.mac, "original independently handwritten caption/order")
			helpers.assert_type(rows[index].action, "function", "the genuine setter callback is retained uncalled")
		end
		local drawn = render_root(read_manifest_text())
		local parent
		for _, row in ipairs(drawn) do if id_of(row) == "language" then parent = row; break end end
		helpers.assert_not_nil(parent, "actual topology rendering consumes the supplied native provider")
		helpers.assert_eq(#parent.menu, #corpus.locales, "the actual tray receives all real children")
		for index, expected in ipairs(corpus.locales) do
			helpers.assert_eq(parent.menu[index].title, expected.mac, "actual completed native caption/order")
			helpers.assert_type(parent.menu[index].fn, "function", "original native setter closure survives rendering")
		end
	end)
end)

helpers.describe("Agent-only disabled macOS root composition", function()
	helpers.it("does not build Agent actions and preserves neighboring provider model and prediction rows", function()
		local source, detail = helpers.read_driver_unit("function M.generate(ctx, menu_mods, actions)")
		helpers.assert_true(source ~= nil, "actual root source must exist: " .. tostring(detail))
		local root = assert(require("json").decode(read_manifest_text()))
		require("test.agent_menu_root").assert_disabled_root(helpers, "hs", source, root.top_level)
	end)
end)
