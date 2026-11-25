--- tests/unit/menu/structure/test_tray_rows_read_as_text.lua

--- ==============================================================================
--- MODULE: The Linux Tray Reads As Text
--- DESCRIPTION:
--- Builds the tray through the real ui.menu.builder over the real French and
--- English catalogues, and fails on a row showing an id, a config path, a raw
--- key, snake_case or an unfilled placeholder (test.menu_row_text). A key no
--- catalogue holds comes back as itself here, as it does in the driver.
--- ==============================================================================

local helpers = require("tests.helpers")
local check = require("tests.lua.menu.row_text")

local SHARED_ROOT = "../_shared"
-- The whole tray holds many more; fewer means a builder gave up.
local MIN_ROWS = 100

--- A tray context with every category on: an off category greys every row of
--- its submenu and drops its submenus (category-off rule), so a walk over off
--- categories never reaches the rows it has to read.
--- @return table
local function every_category_on()
	local function noop() end
	local on = function() return true end
	return {
		_version = "9.9.9",
		log_level = "INFO",
		on_set_log_level = noop,
		llm = { is_enabled = on, toggle = noop, get_backend = function() return "ollama" end, set_backend = noop },
		config = { any_enabled = on, get_groups = function() return {} end, is_group_enabled = on,
			is_section_enabled = on, get_category = function() return nil end, get_categories = function() return {} end },
		shortcuts = { is_enabled = on, toggle = noop, is_caps_word_active = function() return false end,
			get_wrap_pairs = function() return {} end, get_wrap_pair_list = function() return {} end },
		keystats = { is_enabled = on, toggle = noop,
			get_session_stats = function() return { keystrokes = 0, words = 0, duration_ms = 0 } end },
		dyn_hotstrings = { is_enabled = on, set_enabled = noop, get_rules_count = function() return 0 end,
			active_count = function() return 0 end, rule_families = function() return {} end,
			user_code_problem = function() return nil end },
		-- An updater over the real registries, so About draws its channel and
		-- frequency rows.
		updater = (function()
			local real = require("modules.updater.manager")
			return { CHANNELS = real.CHANNELS, INTERVAL_PRESETS = real.INTERVAL_PRESETS, TIMING = real.TIMING,
				current_version = function() return "9.9.9" end, get_channel = function() return "stable" end,
				get_check_interval = function() return real.INTERVAL_PRESETS[1].seconds end,
				get_menu_label = function() return require("core.i18n.engine.i18n").get("menu.about.check_for_updates") end,
				get_state = function() return "idle" end, get_cached_release = function() return nil end,
				releases_page_url = function() return real.releases_page_url() end }
		end)(),
	}
end

--- Builds the tray with one real catalogue behind i18n.
--- @param locale string Locale code.
--- @return table Rendered rows.
local function tray(locale)
	local decode = require("core.text.engine.json").decode
	local catalogue = check.catalogue(SHARED_ROOT, locale, decode)
	local i18n = require("core.i18n.engine.i18n")
	local previous = i18n.get
	i18n.get = function(key)
		local text = catalogue[key]
		return (text == nil or text == "") and key or text
	end
	local ok, rows = pcall(function()
		return helpers.load_module("menu.ui.builder.builder").build(every_category_on())
	end)
	i18n.get = previous
	helpers.assert_true(ok, "the tray must build: " .. tostring(rows))
	return rows
end

helpers.describe("the real Linux tray reads as text", function()
	helpers.it("the walk itself refuses each shape of raw text", function()
		local rows = { { title = "Disposition", menu = {
			{ title = "on_pause" }, { title = "menu.layout.layout_on_pause" },
			{ title = "some_raw_id" }, { title = "Layout {1}" }, { title = "Disposition" },
			-- Lot CB: a key row shows the key's name, never its id or abbreviation.
			{ title = "LCtrl  :  Copier  /  Ctrl" }, { title = "Hold → lalt" },
			{ title = "Ctrl gauche  :  Copier  /  Maj" },
		} } }
		local defects = check.defects(rows, SHARED_ROOT, require("core.text.engine.json").decode)
		helpers.assert_eq(#defects, 6, "only the plain labels may pass: " .. table.concat(defects, " | "))
	end)

	helpers.it("the walk refuses a French row that glues its punctuation", function()
		helpers.assert_eq(check.french_punctuation_defect("Délai: 100"), "Délai:")
		helpers.assert_eq(check.french_punctuation_defect("Vraiment?"), "Vraiment?")
		helpers.assert_eq(check.french_punctuation_defect("Délai : 100"), nil)
		helpers.assert_eq(check.french_punctuation_defect("Voir https://ergopti.fr"), nil)
	end)

	helpers.it("reaches every French submenu row joining a label to its value", function()
		local decode = require("core.text.engine.json").decode
		local catalogue = check.catalogue(SHARED_ROOT, "fr", decode)
		helpers.assert_eq(check.missing_label_value_rows(tray("fr"), SHARED_ROOT, decode, catalogue, "linux"), {})
	end)

	for _, locale in ipairs({ "fr", "en" }) do
		helpers.it("shows no raw id in " .. locale, function()
			local defects, rows = check.defects(tray(locale), SHARED_ROOT, require("core.text.engine.json").decode, locale)
			helpers.assert_true(rows >= MIN_ROWS, "the walk stopped early at " .. rows .. " rows")
			helpers.assert_eq(defects, {}, "a row must read as text")
		end)
	end

	--- The editor row of the English tray, and the head of the unqualified cause.
	--- @return table|nil row, string head
	local function editor_row()
		local catalogue = check.catalogue(SHARED_ROOT, "en", require("core.text.engine.json").decode)
		local label = catalogue["physical_shortcuts.window_title"]
		local head = catalogue["physical_shortcuts.delivery_unqualified"]:match("^(.-):")
		local found = nil
		local function walk(rows)
			for _, row in ipairs(rows or {}) do
				if type(row.title) == "string" and row.title:sub(1, #label) == label then found = row end
				walk(row.menu)
			end
		end
		walk(tray("en"))
		return found, head
	end

	-- dbusmenu has no item tooltips: a greyed row showed only the head of its
	-- reason, « Also reorder the three edge keys — Unavailable », so the Linux
	-- tray draws the rest of it in inert rows below (greyed-reason-rows).
	helpers.it("(greyed-reason-rows) every greyed row naming a reason says all of it", function()
		local catalogue = check.catalogue(SHARED_ROOT, "en", require("core.text.engine.json").decode)
		local function trim(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end
		-- The head of every catalogue text that opens with « Head: », as a
		-- greyed label shows it after its dash.
		local heads = {}
		for _, text in pairs(catalogue) do
			local head = type(text) == "string" and text:match("^([^:\n]+):%s*%S") or nil
			if head and #head <= 40 then heads[trim(head)] = true end
		end
		local Renderer = require("menu.engine.renderer")
		local greyed, problems = 0, {}
		local function walk(rows)
			local drawn = Renderer.with_reason_rows(rows)
			-- A reason is said once per menu, below its first greyed row.
			local told = {}
			local at = 0
			for _, row in ipairs(rows) do
				at = at + 1
				while drawn[at] ~= nil and drawn[at].title ~= row.title do at = at + 1 end
				local head = row.disabled == true and type(row.title) == "string" and row.title:match(" — ([^—]+)$") or nil
				if head and heads[trim(head)] then
					greyed = greyed + 1
					if type(row.tooltip) ~= "string" then
						problems[#problems + 1] = row.title .. " carries no reason"
					else
						local rest = trim(row.tooltip):match("^[^:]*:%s*(.-)%s*$")
						local said = {}
						local index = at + 1
						while drawn[index] and drawn[index].disabled == true and drawn[index].fn == nil
							and drawn[index].title:match("^    %S") do
							said[#said + 1] = trim(drawn[index].title)
							index = index + 1
						end
						local whole = rest ~= nil and rest:gsub("%s+", " ") or nil
						if whole ~= nil and whole ~= "" and not told[whole] and table.concat(said, " ") ~= whole then
							problems[#problems + 1] = row.title .. " is drawn without « " .. rest .. " »"
						elseif whole ~= nil and told[whole] and #said > 0 then
							problems[#problems + 1] = row.title .. " says again « " .. rest .. " »"
						end
						if whole ~= nil then told[whole] = true end
					end
				end
				if type(row.menu) == "table" then walk(row.menu) end
			end
		end
		walk(tray("en"))
		helpers.assert_true(greyed > 0, "the tray draws at least one greyed row naming a reason")
		helpers.assert_eq(problems, {})
	end)

	-- Without lgi or WebKitGTK 4.1 every window-opening row only raised a notice
	-- once clicked; the red row above already says what is missing, so these
	-- rows are greyed with that reason (window-rows-unavailable).
	helpers.it("(window-rows-unavailable) greys every window row while the windows are missing", function()
		local decode = require("core.text.engine.json").decode
		local catalogue = check.catalogue(SHARED_ROOT, "en", decode)
		local handle = assert(io.open(SHARED_ROOT .. "/menu/data/menu_manifest.json", "rb"))
		local manifest = decode(handle:read("*a"))
		handle:close()
		local manager = require("core.ui.ui.webview_manager")
		local GuiStack = require("core.ui.engine.gui_stack")
		-- The label of each window command, as the manifest declares it.
		local labels = {}
		for _, rows in pairs(manifest) do
			if type(rows) == "table" then
				for _, item in ipairs(rows) do
					if type(item) == "table" and manager.TRAY_COMMAND_PAGES[item.id] and type(item.i18n) == "string" then
						local label = catalogue[item.i18n]
						if type(label) == "string" and label ~= "" and not label:find("%", 1, true) then
							labels[item.id] = label
						end
					end
				end
			end
		end
		local reason = catalogue["platform_reason.windows_need_lgi"]
		local head = reason:match("^(.-):")
		-- A row is its label, after any declared prefix, and before the reason.
		local function rows_for(tree)
			local found = {}
			local function walk(rows)
				for _, row in ipairs(rows or {}) do
					local title = type(row.title) == "string" and row.title or ""
					if title:sub(-#(" — " .. head)) == " — " .. head then title = title:sub(1, -#(" — " .. head) - 1) end
					for command, label in pairs(labels) do
						if title:sub(-#label) == label then
							found[command] = found[command] or {}
							table.insert(found[command], row)
						end
					end
					walk(row.menu)
				end
			end
			walk(tree)
			return found
		end
		local present = rows_for(tray("en"))
		require("core.ui.engine.gui_stack").record_windows_missing(GuiStack.LGI_COMPONENT)
		local ok, missing = pcall(function() return rows_for(tray("en")) end)
		require("core.ui.engine.gui_stack")._reset_recorded_windows_missing_for_test()
		if not ok then error(missing, 0) end
		local checked = 0
		for command, rows in pairs(present) do
			local greyed = missing[command] or {}
			local page = manager.TRAY_COMMAND_PAGES[command]
			for index, row in ipairs(rows) do
				local without = greyed[index]
				helpers.assert_true(without ~= nil, command .. " is still drawn without windows")
				if row.fn ~= nil and row.disabled ~= true then
					checked = checked + 1
					require("core.ui.engine.gui_stack").record_windows_missing(GuiStack.LGI_COMPONENT)
					local delivers = manager.page_unavailable_reason(page) == nil
					require("core.ui.engine.gui_stack")._reset_recorded_windows_missing_for_test()
					if delivers then
						helpers.assert_true(without.fn ~= nil, command .. " delivers " .. page .. " without a window")
					else
						helpers.assert_eq(without.disabled, true, command .. " is greyed without windows")
						helpers.assert_eq(without.fn, nil, command .. " runs nothing without windows")
						helpers.assert_eq(without.title, row.title .. " — " .. head)
						helpers.assert_eq(without.tooltip, reason, command .. " carries the whole reason")
					end
				end
			end
		end
		helpers.assert_true(checked >= 8, "the walk reached the window rows: " .. checked)
	end)

	-- Physical delivery answers true since the maintainer's decision of
	-- 2026-11-11 (LIN-004): the row no longer names an unqualified delivery
	-- (physical-delivery-available).
	helpers.it("the physical shortcut editor row no longer names an unqualified delivery", function()
		local found, head = editor_row()
		helpers.assert_true(found ~= nil, "the editor row is drawn")
		helpers.assert_true(found.title:find(head, 1, true) == nil, found.title)
	end)

	-- Should the getter answer false (the safety refusal is kept), the row says
	-- so instead of « Try reopening it ».
	helpers.it("a getter answering false makes the editor row name its real cause", function()
		local keyboard = require("modules.shortcuts.keyboard_shortcuts")
		local original = keyboard.physical_delivery_available
		keyboard.physical_delivery_available = function() return false end
		local ok, err = pcall(function()
			local found, head = editor_row()
			helpers.assert_true(found ~= nil, "the editor row is drawn")
			helpers.assert_eq(found.disabled, true)
			helpers.assert_true(found.title:find(head, 1, true) ~= nil, found.title)
			helpers.assert_true(found.title:find("reopening", 1, true) == nil, found.title)
		end)
		keyboard.physical_delivery_available = original
		if not ok then error(err, 0) end
	end)
	-- Arch field report of 2026-11-25: Hotstrings › Français › « ★ key and text
	-- expansion » listed « text_expansion (530) », « text_expansion_emojis
	-- (271) »: the section ids, where macOS and Windows show the catalogue's
	-- own description of each section.
	helpers.it("names every hotstring section by its catalogue description, never its id", function()
		local Config = helpers.load_module("hotstrings.engine.catalogue.config")
		helpers.assert_true(Config.init(helpers.load_module("hotstrings.engine.engine").new(), nil, function() end))
		helpers.assert_eq(select(2, Config.load_all(nil, true)), true, "the bundled catalogue loads")
		local ids = {}
		for _, group in ipairs(Config.get_groups()) do
			Config.enable_group(group)
			local category = Config.get_category(group)
			for name in pairs(category and category.sections or {}) do ids[name] = true end
		end
		helpers.assert_true(ids.text_expansion and ids.text_expansion_emojis, "the walk reaches the reported sections")
		local context = every_category_on()
		context.config = Config
		local rows = helpers.load_module("menu.ui.builder.builder").build(context)
		local raw, sections = {}, 0
		local function walk(items, path)
			for _, row in ipairs(items or {}) do
				local title = type(row.title) == "string" and row.title or ""
				local head = title:match("^(.-) %(%d+%)") or title
				if ids[head] then raw[#raw + 1] = path .. " > " .. title end
				if title:find("c★ = c’est", 1, true) then sections = sections + 1 end
				walk(row.menu, path .. " > " .. title)
			end
		end
		walk(rows, "")
		helpers.assert_eq(raw, {}, "a section row reads as text")
		helpers.assert_true(sections >= 1, "the text expansion section is drawn by its description")
	end)
end)
