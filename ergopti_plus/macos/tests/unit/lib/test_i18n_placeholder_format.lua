--- tests/unit/lib/test_i18n_placeholder_format.lua

--- ==============================================================================
--- MODULE: Regression — {n} placeholders must actually be substituted
--- DESCRIPTION:
--- The shared locale files use {1}, {2}, … The AutoHotkey driver's logger
--- understands that natively; macOS had no equivalent, and the onboarding call
--- sites reached for string.format, which looks for %s and leaves {1} alone.
--- So the privacy warning shown before enabling the keylogger displayed a
--- literal "{1}" where the metrics path belongs — on the one screen where the
--- user most needs to see where their keystrokes will be stored.
---
--- ROOT CAUSE ENCODED:
--- A formatter chosen for a different placeholder syntax than the data uses.
--- The escaping case matters as much as the substitution: the value is a
--- filesystem path, and a "%" reaching a gsub REPLACEMENT raises — the class
--- this repo has been bitten by four times.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("i18n.format: {n} placeholders are substituted, not printed", function()

	-- The REAL module, not the harness stub. load_with_stubs always injects a
	-- minimal lib.i18n, so asking it for lib.i18n hands back the stub and the
	-- test would be checking the stub's own substitution rather than the
	-- implementation this regression is about.
	local function load_i18n_with(strings)
		package.loaded["infra.i18n"] = nil
		local i18n = dofile(helpers.driver_root() .. "/infra/i18n.lua")
		i18n.get = function(key) return strings[key] end
		return i18n
	end

	helpers.it("substitutes a single placeholder", function()
		local i18n = load_i18n_with({ k = "Logs live under:\n    {1}\nEnable?" })
		local out = i18n.format("k", "/Users/x/.config/metrics")
		helpers.assert_true(out:find("/Users/x/.config/metrics", 1, true) ~= nil,
			"the value must appear in the rendered string")
		helpers.assert_true(out:find("{1}", 1, true) == nil,
			"the placeholder must be gone; string.format leaves it and the user reads '{1}'")
	end)

	helpers.it("substitutes several, in order", function()
		local i18n = load_i18n_with({ k = "{1} then {2}" })
		helpers.assert_eq(i18n.format("k", "first", "second"), "first then second")
	end)

	helpers.it("survives a percent sign in the value", function()
		local i18n = load_i18n_with({ k = "path: {1}" })
		local out = i18n.format("k", "/tmp/100%done")
		helpers.assert_true(out:find("100%done", 1, true) ~= nil,
			"a '%' in a gsub REPLACEMENT raises unless escaped, and these values are "
			.. "filesystem paths the user controls")
	end)

end)
