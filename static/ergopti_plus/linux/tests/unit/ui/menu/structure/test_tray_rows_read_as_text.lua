--- tests/unit/ui/menu/structure/test_tray_rows_read_as_text.lua

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
		return helpers.load_module("ui.menu.builder").build(every_category_on())
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
end)
