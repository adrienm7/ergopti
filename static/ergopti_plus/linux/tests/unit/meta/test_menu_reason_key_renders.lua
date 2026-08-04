--- tests/unit/meta/test_menu_reason_key_renders.lua

--- ==============================================================================
--- MODULE: A Restricted Row Explains Itself
--- DESCRIPTION:
--- Covers the shared renderer's handling of `reason_key` on a row this platform
--- does not have.
---
--- WHY THIS IS A BEHAVIOUR AND NOT A STYLE CHOICE:
--- Convention S says a feature another driver has should appear here, greyed,
--- with the reason — because the difference between "not implemented on Linux"
--- and "removed from the product" is exactly what a user needs, and an absent row
--- answers neither. The manifest has carried translated reasons on five rows for
--- some time; the renderer dropped them with the row, so those explanations
--- existed in 21 locales and reached nobody. `reason_key` was a field nothing
--- read.
---
--- WHAT IS DELIBERATELY NOT DONE:
--- rendering every restricted row. A row restricted with no reason_key stays
--- hidden. A greyed row that says nothing is worse than an absent one: it takes
--- up space in the menu and answers no question. That asymmetry is the whole
--- design — the reason is what earns the row its place.
--- ==============================================================================

local helpers = require("tests.helpers")


-- Every string the fixture menu can ask for. Keyed exactly as the manifest names
-- them so a lookup miss in the renderer shows up as a miss here too.
local TRANSLATIONS = {
	["platform_reason.windows_only"] = "Réglages propres à Windows",
	["menu.test.labelled"]           = "Réglages avancés",
}


--- Writes a throwaway manifest exercising each restricted-row shape.
--- @return string Absolute path of the fixture directory.
local function write_fixture_manifest()
	local tmp_dir = os.tmpname()
	os.remove(tmp_dir)
	os.execute('mkdir "' .. tmp_dir .. '"')
	local manifest_dir = tmp_dir .. "/modules/menu"
	os.execute('mkdir "' .. tmp_dir .. '/modules" "' .. manifest_dir .. '"')

	local fh = io.open(manifest_dir .. "/menu_manifest.json", "w")
	helpers.assert_true(fh ~= nil, "could not create the fixture manifest")
	fh:write([[
{
	"test_menu": [
		{ "type": "dynamic", "id": "explained_no_label",
		  "platforms": ["ahk"], "reason_key": "platform_reason.windows_only" },
		{ "type": "dynamic", "id": "explained_with_label", "i18n": "menu.test.labelled",
		  "platforms": ["ahk"], "reason_key": "platform_reason.windows_only" },
		{ "type": "dynamic", "id": "unexplained", "platforms": ["ahk"] },
		{ "type": "dynamic", "id": "untranslated_reason",
		  "platforms": ["ahk"], "reason_key": "platform_reason.no_such_key" },
		{ "type": "action", "id": "ours", "i18n": "menu.test.labelled" }
	]
}
]])
	fh:close()
	return tmp_dir
end


--- Builds a renderer bound to the fixture, rendering for Linux.
--- @return table rows, table warnings
local function render_fixture()
	local Renderer = helpers.load_module("menu.renderer")
	local dir = write_fixture_manifest()

	local warnings = {}
	local logger = helpers.make_logger_stub()
	logger.warn = function(_, fmt, ...)
		local ok, formatted = pcall(string.format, fmt, ...)
		warnings[#warnings + 1] = ok and formatted or tostring(fmt)
	end

	local R = Renderer.new({
		platform      = "linux",
		manifest_path = function() return dir .. "/modules/menu/menu_manifest.json" end,
		json_decode   = require("json").decode,
		i18n          = {
			-- The real i18n returns the key itself when it has no translation, which
			-- is what the renderer must recognise as "no translation" rather than
			-- printing a dotted key into the menu.
			get     = function(key) return TRANSLATIONS[key] or key end,
			section = function(key) return TRANSLATIONS[key] or key end,
		},
		logger        = logger,
	})
	helpers.assert_true(R ~= nil, "the renderer must have been created")

	local rows = R.build("test_menu", "Test", {
		["ours"] = function(items)
			items[#items + 1] = { title = "Ours", fn = function() end }
		end,
	}, nil, {})
	return rows or {}, warnings
end


--- Finds a row whose title contains `needle`.
--- @param rows table
--- @param needle string
--- @return table|nil
local function row_containing(rows, needle)
	for _, row in ipairs(rows) do
		if type(row.title) == "string" and row.title:find(needle, 1, true) then return row end
	end
	return nil
end





-- ==================================================
-- ==================================================
-- ======= 1/ The reason reaches the user ===========
-- ==================================================
-- ==================================================

helpers.describe("renderer: a row with a reason_key is shown greyed, not dropped", function()

	helpers.it("renders the reason as the row when it has no label of its own", function()
		local rows = render_fixture()
		local row = row_containing(rows, "Réglages propres à Windows")
		helpers.assert_true(row ~= nil,
			"the manifest explained the absence in 21 languages and nothing ever showed it")
	end)

	helpers.it("greys the row so it cannot be clicked", function()
		local rows = render_fixture()
		local row = row_containing(rows, "Réglages propres à Windows")
		helpers.assert_true(row ~= nil and row.disabled == true,
			"an enabled row for a feature this driver does not have is a row that does nothing")
	end)

	helpers.it("keeps the row's own label when it has one", function()
		local rows = render_fixture()
		local row = row_containing(rows, "Réglages avancés — Réglages propres à Windows")
		helpers.assert_true(row ~= nil,
			"label and reason together — the label alone says nothing about why it is grey")
	end)

end)





-- ==================================================
-- ==================================================
-- ======= 2/ Silence stays silent ==================
-- ==================================================
-- ==================================================

helpers.describe("renderer: a restriction with no reason stays hidden", function()

	helpers.it("does not render a restricted row that carries no reason_key", function()
		local rows = render_fixture()
		for _, row in ipairs(rows) do
			helpers.assert_true(not (type(row.title) == "string" and row.title:find("unexplained", 1, true)),
				"a greyed row that answers nothing occupies the menu and helps no one")
		end
	end)

	helpers.it("hides the row rather than printing an unresolved key", function()
		local rows, warnings = render_fixture()
		helpers.assert_true(row_containing(rows, "platform_reason.no_such_key") == nil,
			"a raw dotted key in a menu reads to the user as a crash")

		local said = false
		for _, message in ipairs(warnings) do
			if message:find("no_such_key", 1, true) then said = true end
		end
		helpers.assert_true(said,
			"and the missing translation must be reported, or it is invisible to us too")
	end)

end)





-- ===================================================
-- ===================================================
-- ======= 3/ The rest of the menu is unharmed =======
-- ===================================================
-- ===================================================

helpers.describe("renderer: rows this platform does have still render", function()

	helpers.it("still builds the platform's own rows", function()
		local rows = render_fixture()
		helpers.assert_true(row_containing(rows, "Ours") ~= nil,
			"the explained-absence branch must not swallow the rows that belong here")
	end)

end)
