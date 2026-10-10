--- tests/unit/ui/test_menu_pause_greys_features.lua

--- ==============================================================================
--- MODULE: A Paused Script Greys The Feature Rows (Linux tray)
--- DESCRIPTION:
--- The menu builder never read the pause state: while paused every feature row
--- stayed live, and the title row was a disabled label with no action, so the
--- tray offered no way back. It now greys and strips every row the manifest
--- marks `greyed_when_paused` (the features), keeps the tail (configuration,
--- language, about, reload, quit, debug) live, and the title row resumes the
--- script, as on macOS.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A hotstrings config double with one category.
--- @return table
local function fake_config()
	return {
		get_groups = function() return { "rolls" } end,
		is_group_enabled = function() return true end,
		toggle_group = function() end,
		enable_all = function() end,
		disable_all = function() end,
		is_section_enabled = function() return true end,
		get_category = function() return nil end,
		get_categories = function() return {} end,
		language_packs = function() return {} end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_global_delay = function() return 0.75 end,
		has_global_delay_override = function() return false end,
	}
end

--- The top-level row whose title starts with the translation of `key`.
--- @param items table
--- @param key string
--- @return table|nil
local function row_for(items, key)
	local label = require("infra.i18n").get(key)
	for _, item in ipairs(items) do
		if type(item.title) == "string" and item.title:find(label, 1, true) then return item end
	end
	return nil
end

--- Builds the tray for a paused or running script.
--- @param paused boolean
--- @param resumed table|nil Receives a `count` of resume calls.
--- @return table items
local function build(paused, resumed)
	local mb = helpers.load_module("ui.menu.menu_builder")
	return mb.build({
		-- This fixture tests pause policy with the genuine present native owner.
		-- No engine initialization, bootstrap or network action runs here.
		llm = require("modules.llm.prediction_engine"),
		config = fake_config(),
		_version = "0.0.0-dev.12",
		paused = paused,
		on_toggle_pause = function() if resumed then resumed.count = resumed.count + 1 end end,
		on_quit = function() end,
	})
end

-- The features a pause switches off, by their title key.
local FEATURE_KEYS = {
	"menu.hotstrings.title",
	"menu.llm.title",
	"menu.metrics.title",
	"menu.shortcuts.title",
	"menu.gestures.title",
}

-- The rows that must stay usable while paused.
local LIVE_KEYS = {
	"menu.configuration.title",
	"menu.debug.title",
}

helpers.describe("tray (linux): a pause greys every feature row", function()
	helpers.it("greys and strips every feature row while paused", function()
		local items = build(true)
		for _, key in ipairs(FEATURE_KEYS) do
			local row = row_for(items, key)
			helpers.assert_true(row ~= nil, "row " .. key .. " must still be drawn while paused")
			helpers.assert_eq(row.disabled, true, key .. " must be greyed while paused")
			helpers.assert_nil(row.menu, key .. " must not open a submenu while paused")
			helpers.assert_nil(row.fn, key .. " must not act while paused")
		end
	end)

	helpers.it("keeps the global actions and the debug submenu live while paused", function()
		local items = build(true)
		for _, key in ipairs(LIVE_KEYS) do
			local row = row_for(items, key)
			helpers.assert_true(row ~= nil, key .. " must be drawn")
			helpers.assert_true(row.disabled ~= true, key .. " must stay enabled while paused")
			helpers.assert_true(type(row.menu) == "table" and #row.menu > 0, key .. " keeps its submenu")
		end
	end)

	helpers.it("turns the title row into a resume action while paused", function()
		local resumed = { count = 0 }
		local items = build(true, resumed)
		local title = items[1]
		local paused_label = require("infra.i18n").get("menu.builder.title_paused")
		helpers.assert_true(title.title:find(paused_label, 1, true) ~= nil, "title says paused: " .. title.title)
		helpers.assert_true(title.title:find("v0.0.0-dev.12", 1, true) ~= nil, "title keeps the version")
		helpers.assert_true(title.disabled ~= true, "the paused title row must be clickable")
		helpers.assert_eq(type(title.fn), "function", "the paused title row must act")
		title.fn()
		helpers.assert_eq(resumed.count, 1, "clicking the paused title resumes the script")
	end)

	helpers.it("leaves every row live and the title a label while running", function()
		local items = build(false)
		helpers.assert_eq(items[1].disabled, true, "the running title row is a label")
		for _, key in ipairs(FEATURE_KEYS) do
			local row = row_for(items, key)
			helpers.assert_true(row ~= nil and row.disabled ~= true, key .. " must be live while running")
		end
	end)

	helpers.it("greys exactly the rows the manifest marks, wherever they sit", function()
		-- The mark moves from Metrics to Language. A driver that keeps its own
		-- list of the feature ids keeps greying Metrics and leaves Language live,
		-- so it fails even while that list matches the shipped manifest.
		local ManifestMenu = require("infra.manifest_menu")
		local shipped = ManifestMenu.get_array("top_level")
		local marked = 0
		local moved = {}
		for index, row in ipairs(shipped) do
			moved[index] = { row = row, greyed_when_paused = row.greyed_when_paused }
			if row.greyed_when_paused == true then marked = marked + 1 end
		end
		helpers.assert_true(marked >= 7,
			"the manifest must mark the feature rows a pause greys, got " .. marked)
		for _, entry in ipairs(moved) do
			if entry.row.id == "metrics" then entry.row.greyed_when_paused = nil end
			if entry.row.id == "language" then entry.row.greyed_when_paused = true end
		end
		local ok, items = pcall(build, true)
		for _, entry in ipairs(moved) do entry.row.greyed_when_paused = entry.greyed_when_paused end
		helpers.assert_true(ok, "the tray must build: " .. tostring(items))
		local metrics = row_for(items, "menu.metrics.title")
		local language = row_for(items, "menu.global.language")
		helpers.assert_true(metrics ~= nil and language ~= nil, "both rows must be drawn")
		helpers.assert_true(metrics.disabled ~= true, "a row the manifest does not mark stays live while paused")
		helpers.assert_eq(language.disabled, true, "a row the manifest marks is greyed while paused")
	end)

	helpers.it("shows a source run's version without a stray v", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local items = mb.build({ config = fake_config(), _version = "local", on_quit = function() end })
		helpers.assert_eq(items[1].title, "Ergopti — local")
	end)
end)


-- The real registered pause host also owns the shared header's publication.
local function with_shared_header(options, body)
	local ManifestMenu = require("infra.manifest_menu")
	local I18n = require("infra.i18n")
	local old_builder = package.loaded["ui.menu.menu_builder"]
	local old_facade = package.loaded["infra.manifest_menu"]
	local old_template, old_command, old_get = ManifestMenu.template_rows, ManifestMenu.command_row, I18n.get
	local root = ManifestMenu.get_root()
	local saved = {}
	for _, key in ipairs({ "linux_tray_active_header", "linux_tray_paused_header" }) do
		local rows = root[key]
		local record = type(rows) == "table" and rows[1]
		local fields = {}; if type(record) == "table" then for name, value in next, record do fields[name] = value end end
		saved[key] = { rows = rows, record = record, fields = fields }
	end
	local fixture = { resumes = 0, observers = 0 }
	local ok, failure = xpcall(function()
		local Json = require("json")
		local path = helpers.driver_root() .. "/../_shared/tests/corpus/menus/linux_tray_header_original.json"
		local file = assert(io.open(path, "rb")); local raw = assert(file:read("*a")); file:close()
		local oracle = assert(Json.decode(raw))
		local caption = assert(oracle.locales[options.locale or "en"])
		I18n.get = function(key)
			if key == "menu.builder.active_brand" then return oracle.active_brand end
			if key == "menu.builder.title_paused" then return caption.paused_caption end
			return old_get(key)
		end
		fixture.oracle = oracle
		if options.source == "caption" then root[options.key][1].i18n = "menu.builder.title_paused"
		elseif options.source == "missing" then root[options.key] = nil
		elseif options.source == "empty" then root[options.key] = {}
		elseif options.source == "extra" then root[options.key][2] = { type = "---" }
		elseif options.source == "kind" then root[options.key][1].type = "check"
		elseif options.source == "getter" then root[options.key][1].caption_getter = "unowned_version"
		elseif options.source == "platform" then root[options.key][1].platforms = { "hs" }
		elseif options.source == "metatable" then
			root[options.key] = setmetatable({}, { __index = function() fixture.observers = fixture.observers + 1; return saved[options.key].record end })
		end
		local projected
		ManifestMenu.template_rows = function(key, commands, getters, children)
			local rows = old_template(key, commands, getters, children)
			if key == "linux_tray_active_header" or key == "linux_tray_paused_header" then
				if options.during == "source" then root[key] = {}
				elseif options.during == "template" then ManifestMenu.template_rows = function() fixture.observers = fixture.observers + 1; return rows end
				elseif options.during == "command" then ManifestMenu.command_row = function() fixture.observers = fixture.observers + 1; return rows and rows[1] end
				elseif options.during == "facade" then package.loaded["infra.manifest_menu"] = {} end
				if type(rows) == "table" and type(rows[1]) == "table" then
					if options.output == "action" then rows[1].action = function() fixture.observers = fixture.observers + 1 end
					elseif options.output == "checked" then rows[1].checked = false
					elseif options.output == "label" then rows[1].label = false
					elseif options.output == "extra" then rows[2] = rows[1]
					elseif options.output == "metatable" then rows[1] = setmetatable({}, { __index = function() fixture.observers = fixture.observers + 1; return "foreign" end }) end
				end
				projected = rows and rows[1]
			elseif options.during == "later_child" and projected then
				projected.label = "foreign after header admission"
			end
			return rows
		end
		package.loaded["ui.menu.menu_builder"] = nil
		local builder = require("ui.menu.menu_builder")
		if options.before == "template" then ManifestMenu.template_rows = nil
		elseif options.before == "command" then ManifestMenu.command_row = nil end
		local context = { llm = require("modules.llm.prediction_engine"), config = fake_config(),
			_version = options.version or "local", paused = options.paused == true,
			on_toggle_pause = function() fixture.resumes = fixture.resumes + 1 end,
			on_quit = function() end }
		-- An actual version read may withdraw the source before the template runs.
		if options.during == "version" then
			context._version = nil
			setmetatable(context, { __index = function(_, key)
				if key == "_version" then root[options.key] = {}; return "local" end
			end })
		end
		if options.missing_callback then context.on_toggle_pause = nil end
		local items = builder.build(context)
		body(items, fixture)
	end, debug.traceback)
	ManifestMenu.template_rows, ManifestMenu.command_row, I18n.get = old_template, old_command, old_get
	for key, snapshot in next, saved do
		root[key] = snapshot.rows
		if type(snapshot.rows) == "table" then
			for index in next, snapshot.rows do snapshot.rows[index] = nil end
			if snapshot.record ~= nil then snapshot.rows[1] = snapshot.record end
		end
		if type(snapshot.record) == "table" then
			for name in next, snapshot.record do snapshot.record[name] = nil end
			for name, value in next, snapshot.fields do snapshot.record[name] = value end
		end
	end
	package.loaded["infra.manifest_menu"], package.loaded["ui.menu.menu_builder"] = old_facade, old_builder
	if not ok then error(failure, 0) end
end

helpers.describe("tray (linux): original shared header family", function()
	local locales = { "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }
	for _, locale in ipairs(locales) do
		helpers.it("keeps the original paused caption and callback in " .. locale, function()
			with_shared_header({ locale = locale, paused = true, version = "0.0.0-dev.12" }, function(items, fixture)
				helpers.assert_eq(items[1].title, fixture.oracle.locales[locale].paused_caption .. " — v0.0.0-dev.12")
				helpers.assert_nil(items[1].checked)
				helpers.assert_true(items[1].disabled ~= true)
				helpers.assert_eq(type(items[1].fn), "function")
				items[1].fn(); helpers.assert_eq(fixture.resumes, 1)
			end)
		end)
	end
	for _, version in ipairs({ "0.0.0-dev.12", "local", "unknown", "v1.2", "", "%s 50%" }) do
		helpers.it("keeps the original active brand and version " .. version, function()
			with_shared_header({ version = version }, function(items, fixture)
				local expected
				for _, row in ipairs(fixture.oracle.versions) do
					if row.input == version then
						expected = row.active_title
						helpers.assert_eq(items[1].title,
							fixture.oracle.active_brand .. fixture.oracle.joiner .. row.formatted,
							"the actual shared header preserves the original formatted version")
					end
				end
				helpers.assert_eq(items[1].title, assert(expected))
				helpers.assert_eq(items[1].disabled, true)
				helpers.assert_nil(items[1].fn)
				helpers.assert_nil(items[1].checked)
			end)
		end)
	end
	helpers.it("consumes the actual current canonical active caption source", function()
		with_shared_header({ key = "linux_tray_active_header", source = "caption" }, function(items, fixture)
			helpers.assert_eq(items[1].title, fixture.oracle.locales.en.paused_caption .. " — local")
			helpers.assert_eq(items[1].disabled, true)
			helpers.assert_nil(items[1].fn)
		end)
	end)
	helpers.it("keeps missing resume context inert when clicked", function()
		with_shared_header({ paused = true, missing_callback = true }, function(items, fixture)
			helpers.assert_eq(type(items[1].fn), "function")
			items[1].fn(); helpers.assert_eq(fixture.resumes, 0)
		end)
	end)
	for _, key in ipairs({ "linux_tray_active_header", "linux_tray_paused_header" }) do
		for _, source in ipairs({ "missing", "empty", "extra", "kind", "getter", "platform", "metatable" }) do
			helpers.it("refuses the whole root for " .. source .. " " .. key, function()
				with_shared_header({ key = key, source = source }, function(items, fixture)
					helpers.assert_eq(items, {})
					helpers.assert_eq(fixture.resumes, 0)
					helpers.assert_eq(fixture.observers, 0)
				end)
			end)
		end
	end
	for _, before in ipairs({ "template", "command" }) do
		helpers.it("refuses captured " .. before .. " withdrawal", function()
			with_shared_header({ before = before }, function(items, fixture)
				helpers.assert_eq(items, {}); helpers.assert_eq(fixture.observers, 0)
			end)
		end)
	end
	for _, during in ipairs({ "source", "template", "command", "facade", "version", "later_child" }) do
		helpers.it("refuses " .. during .. " withdrawal before final root publication", function()
			with_shared_header({ during = during, key = "linux_tray_active_header" }, function(items, fixture)
				helpers.assert_eq(items, {}); helpers.assert_eq(fixture.resumes, 0)
				helpers.assert_eq(fixture.observers, 0)
			end)
		end)
	end
	for _, output in ipairs({ "action", "checked", "label", "extra", "metatable" }) do
		helpers.it("refuses foreign active header " .. output .. " output", function()
			with_shared_header({ output = output }, function(items, fixture)
				helpers.assert_eq(items, {}); helpers.assert_eq(fixture.observers, 0)
			end)
		end)
	end
end)
