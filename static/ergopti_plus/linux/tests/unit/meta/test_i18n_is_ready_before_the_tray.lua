--- tests/unit/meta/test_i18n_is_ready_before_the_tray.lua

--- ==============================================================================
--- MODULE: The Locale Is Loaded Before The Menu Is Drawn
--- DESCRIPTION:
--- i18n.init() is what reads the locale the user chose: until it runs, every
--- lookup answers in the module default, which is French.
---
--- THE BUG (found 2026-08-07): the daemon initialised i18n in section 8.10a and
--- built the tray menu in section 8.9 — two hundred lines earlier. So the first
--- tray a Spanish, German or Japanese user ever saw was drawn entirely in French,
--- and stayed that way until something happened to rebuild the menu. Nothing
--- failed, nothing was logged, and every translation involved was present and
--- correct: they were simply asked for too early.
---
--- WHY A SOURCE-ORDER SCAN: the failure is a boot ORDER, and the whole point is
--- that both steps succeed. There is no return value to assert on and no error to
--- catch — only "which ran first", which is a property of this one file.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The daemon entry point's source.
--- @return string
local function daemon_source()
	local handle = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
	local content = handle:read("*a")
	handle:close()
	return content
end

helpers.describe("boot order: the locale is loaded before the tray is drawn", function()

	helpers.it("i18n.init() runs before the tray menu is built", function()
		local src = daemon_source()

		local init_pos = src:find("i18n_mod.init()", 1, true)
		local tray_pos = src:find("Start the tray menu if requested", 1, true)

		helpers.assert_true(init_pos ~= nil,
			"the daemon must still initialise i18n — without it every label answers in the default locale")
		helpers.assert_true(tray_pos ~= nil,
			"the tray section must still be findable, or this test compares nothing")
		helpers.assert_true(init_pos < tray_pos,
			"i18n.init() must run BEFORE the tray is built. It is what loads the locale the user chose; "
			.. "called afterwards, the first menu they see is drawn in the default language and stays "
			.. "that way until something rebuilds it")
	end)

	helpers.it("the degraded tray does not carry a hardcoded translation", function()
		local src = daemon_source()

		-- The fallback shown when the menu builder is unavailable. It listed a
		-- French label written into the source, which is a translation of exactly
		-- one of the twenty-one languages this driver speaks.
		local fallback = src:match("tray_menu%.setMenu%(%{.-%}%)")
		helpers.assert_true(fallback ~= nil, "the degraded tray must still be findable")
		helpers.assert_true(fallback:find("Quitter", 1, true) == nil,
			"the degraded tray must take its label from i18n like every other row — a French string in "
			.. "the source is a menu that ignores the user's locale by construction")
	end)
end)
