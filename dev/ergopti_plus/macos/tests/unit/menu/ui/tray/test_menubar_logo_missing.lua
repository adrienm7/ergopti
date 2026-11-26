--- tests/unit/menu/ui/tray/test_menubar_logo_missing.lua

--- ==============================================================================
--- MODULE: Regression — a missing menu-bar logo is said, not swapped (TRAY-05)
--- DESCRIPTION:
--- update_icon drew logo_simple.png when logo_simple_disabled.png was missing,
--- so a paused driver looked running, and drew the title « 🔧 » when the logo
--- itself was missing, with nothing in the log. Each state now draws its own
--- file; a missing one is logged once, the warning sign is drawn, and the
--- tooltip says the file is missing.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["menu.ui.menubar_logo"] = nil
local MenubarLogo = require("menu.ui.menubar_logo")

local DIR = "/Applications/Ergopti/img/logo/"

--- A file probe answering from a set of present paths.
--- @param present table Paths that exist.
--- @return function
local function probe(present)
	return function(path) return present[path] == true end
end




-- ==================================
-- ==================================
-- ======= 1/ The choice ============
-- ==================================
-- ==================================

helpers.describe("menu-bar logo: each state draws its own file (tray-05)", function()

	helpers.it("draws the disabled logo while paused when it exists", function()
		local path, missing = MenubarLogo.choose(DIR, "v1", true, probe({ [DIR .. "logo_simple_disabled.png"] = true }))
		helpers.assert_eq(path, DIR .. "logo_simple_disabled.png")
		helpers.assert_eq(missing, nil)
	end)

	helpers.it("never draws the running logo for a missing disabled one", function()
		local path, missing = MenubarLogo.choose(DIR, "v1", true, probe({ [DIR .. "logo_simple.png"] = true }))
		helpers.assert_eq(path, nil, "a paused driver drawn with the running logo looks running")
		helpers.assert_eq(missing, DIR .. "logo_simple_disabled.png", "the missing file is named for the log")
	end)

	helpers.it("reports a missing logo of either variant", function()
		local _, missing_v1 = MenubarLogo.choose(DIR, "v1", false, probe({}))
		helpers.assert_eq(missing_v1, DIR .. "logo_simple.png")
		local _, missing_v2 = MenubarLogo.choose(DIR, "v2", true, probe({ [DIR .. "logo_white.png"] = true }))
		helpers.assert_eq(missing_v2, DIR .. "logo_black.png")
	end)

	helpers.it("refuses an unknown variant instead of drawing one", function()
		local ok = pcall(MenubarLogo.choose, DIR, "v9", false, probe({}))
		helpers.assert_eq(ok, false, "init.lua maps an unknown stored variant to the default before choosing")
	end)

	helpers.it("names the item with the missing file in the tooltip", function()
		helpers.assert_eq(MenubarLogo.tooltip_key(true, true), "accessibility.tray_tip_paused_icon_missing")
		helpers.assert_eq(MenubarLogo.tooltip_key(false, true), "accessibility.tray_tip_icon_missing")
		helpers.assert_eq(MenubarLogo.tooltip_key(true, false), "accessibility.tray_tip_paused")
		helpers.assert_eq(MenubarLogo.tooltip_key(false, false), "accessibility.tray_tip")
		local handle = assert(io.open(helpers.shared("core/i18n/data/locales/en.json"), "r"))
		local english = require("core.text.engine.json").decode(handle:read("a"))
		handle:close()
		for _, key in ipairs({ "accessibility.tray_tip_paused_icon_missing", "accessibility.tray_tip_icon_missing" }) do
			helpers.assert_true(type(english[key]) == "string", key .. " must be in the locale catalogue")
		end
	end)

end)




-- ==================================
-- ==================================
-- ======= 2/ The owner =============
-- ==================================
-- ==================================

helpers.describe("menu-bar logo: update_icon draws through the choice (tray-05)", function()

	helpers.it("update_icon logs a missing logo and draws the warning sign", function()
		local src = helpers.read_driver_source("local function update_icon(")
		helpers.assert_true(src ~= nil and src ~= "", "update_icon must be locatable")
		local code = src:gsub("%-%-[^\n]*", "")
		local first = code:find("local function update_icon(", 1, true)
		local body = code:sub(first, (code:find("local function reset_menubar", first, true)))
		helpers.assert_true(body:find("MenubarLogo.choose(", 1, true) ~= nil, "the logo is chosen per state")
		helpers.assert_true(body:find("MenubarLogo.tooltip_key(paused, missing_logo ~= nil)", 1, true) ~= nil,
			"the tooltip says when the file is missing")
		helpers.assert_true(body:find("Logger.error(LOG, \"Menu-bar logo '%s' is missing", 1, true) ~= nil,
			"a missing logo is logged")
		helpers.assert_true(body:find("MenubarLogo.MISSING_TITLE", 1, true) ~= nil, "the warning sign is drawn")
		helpers.assert_true(body:find("logo_simple", 1, true) == nil,
			"no file name is chosen outside the choice, where it fell back to the running logo")
		helpers.assert_true(body:find("🔧", 1, true) == nil, "the wrench said nothing about a missing file")
	end)

end)
