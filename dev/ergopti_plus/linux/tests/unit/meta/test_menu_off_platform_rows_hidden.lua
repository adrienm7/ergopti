--- tests/unit/meta/test_menu_off_platform_rows_hidden.lua

--- ==============================================================================
--- MODULE: Off-Platform Rows Are Hidden
--- DESCRIPTION:
--- Covers the shared renderer's handling of a row this platform does not have.
---
--- The renderer used to show such a row greyed when the manifest carried a
--- `reason_key` for it: "… — Linux only" rows on macOS, the Windows registry
--- options under Gestures. Those explanations are long, so the tray became very
--- wide, and every one of those rows was a row the user could not use. The user
--- asked for them gone: a row this platform does not have is never rendered,
--- with or without a reason. The health check is where those reasons are read.
--- ==============================================================================

local helpers = require("tests.helpers")
local leaks   = require("test.menu_off_platform")

local PLATFORM      = "linux"
local MANIFEST_PATH = "../_shared/modules/menu/menu_manifest.json"


-- Every string the fixture menu can ask for. Keyed exactly as the manifest names
-- them so a lookup miss in the renderer shows up as a miss here too.
local TRANSLATIONS = {
	["platform_reason.windows_only"] = "Réglages propres à Windows",
	["menu.test.labelled"]           = "Réglages avancés",
	["menu.test.ours"]               = "Ours",
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
		{ "type": "---" },
		{ "type": "action", "id": "ours", "i18n": "menu.test.ours" },
		{ "type": "action", "id": "ours_too", "i18n": "menu.test.ours",
		  "platforms": ["linux", "hs"] }
	]
}
]])
	fh:close()
	return tmp_dir
end


--- Builds a renderer bound to the fixture, rendering for Linux.
--- @return table rows
local function render_fixture()
	local Renderer = helpers.load_module("menu.renderer")
	local dir = write_fixture_manifest()
	local R = Renderer.new({
		platform      = PLATFORM,
		manifest_path = function() return dir .. "/modules/menu/menu_manifest.json" end,
		json_decode   = require("json").decode,
		i18n          = {
			get     = function(key) return TRANSLATIONS[key] or key end,
			section = function(key) return TRANSLATIONS[key] or key end,
		},
		logger        = helpers.make_logger_stub(),
	})
	helpers.assert_true(R ~= nil, "the renderer must have been created")

	local append_ours = function(items)
		items[#items + 1] = { title = "Ours", fn = function() end }
	end
	local rows = R.build("test_menu", "Test", {
		["ours"] = append_ours,
		["ours_too"] = append_ours,
	}, nil, { commands = { ours = function() end, ours_too = function() end } })
	return rows or {}
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





-- =================================================
-- =================================================
-- ======= 1/ A fixture with every row shape =======
-- =================================================
-- =================================================

helpers.describe("renderer: a row this platform does not have is hidden", function()

	helpers.it("hides a restricted row whose reason is its only label", function()
		helpers.assert_true(row_containing(render_fixture(), "Réglages propres à Windows") == nil,
			"the explanation alone must not become a greyed row")
	end)

	helpers.it("hides a restricted row that has a label and a reason", function()
		helpers.assert_true(row_containing(render_fixture(), "Réglages avancés") == nil,
			"a labelled row of another platform must not appear, greyed or not")
	end)

	helpers.it("hides a restricted row that carries no reason", function()
		helpers.assert_true(row_containing(render_fixture(), "unexplained") == nil,
			"a restriction with no reason was already hidden and stays hidden")
	end)

	helpers.it("renders no disabled row at all for the restricted rows", function()
		for _, row in ipairs(render_fixture()) do
			helpers.assert_true(row.disabled ~= true,
				"no greyed stand-in may be left behind: " .. tostring(row.title))
		end
	end)

	helpers.it("still renders the rows this platform has, including a restricted one", function()
		local count = 0
		for _, row in ipairs(render_fixture()) do
			if row.title == "Ours" then count = count + 1 end
		end
		helpers.assert_eq(count, 2, "the unrestricted row and the linux-restricted row must both render")
	end)

	helpers.it("leaves no separator where the hidden rows were", function()
		local rows = render_fixture()
		helpers.assert_true(rows[1] ~= nil and rows[1].title ~= "-",
			"hidden rows at the top must not leave the manifest `---` leading the menu")
	end)

end)





-- ==============================================
-- ==============================================
-- ======= 2/ Every menu of the real tray =======
-- ==============================================
-- ==============================================

helpers.describe("menu: no off-platform explanation is rendered on linux", function()

	helpers.it("the real manifest has rows the old renderer showed greyed here", function()
		local fh = assert(io.open(MANIFEST_PATH, "r"))
		local root = require("json").decode(fh:read("*a"))
		fh:close()
		helpers.assert_true(leaks.explained_off_platform_count(root, PLATFORM) > 0,
			"without such rows the check below cannot fail and proves nothing")
	end)

	helpers.it("renders every manifest menu without a platform_reason text", function()
		package.loaded["menu.renderer"] = nil
		local found, rendered = leaks.reason_leaks(require("menu.renderer"), {
			platform      = PLATFORM,
			manifest_path = MANIFEST_PATH,
			json_decode   = require("json").decode,
			logger        = helpers.make_logger_stub(),
		})
		helpers.assert_true(rendered > 10, "every menu of the shared manifest must render, got " .. rendered)
		helpers.assert_eq(found, {}, "a row another platform has must not reach this tray")
	end)

end)
