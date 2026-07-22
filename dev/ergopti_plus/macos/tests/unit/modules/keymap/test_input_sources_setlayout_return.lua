--- tests/unit/modules/keymap/test_input_sources_setlayout_return.lua

--- ==============================================================================
--- MODULE: Regression — set_input_source must read setLayout's RESULT, not pcall's
--- DESCRIPTION:
--- Audit finding G2. set_input_source drove its three-strategy cascade from
---   local ok = pcall(hs.keycodes.setLayout, localised_name)
---   if ok then ... return true end
--- but hs.keycodes.setLayout RETURNS a boolean and does NOT raise on an unknown or
--- unswitchable layout. pcall therefore yielded (true, false) and only the status
--- was bound, so `ok` was true on every call. Consequences:
---   - the kl_name retry never ran;
---   - the TIS osascript fallback never ran — even though the function's own
---     docstring says that path exists precisely for macOS Sequoia third-party
---     bundles where setLayout FAILS;
---   - the Logger.warn on total failure was unreachable, so a failed layout
---     switch was affirmatively logged as a success.
---
--- Fix: bind pcall's SECOND return at both attempts and require it to be true.
---
--- This test stubs setLayout to RETURN false WITHOUT raising — the exact shape
--- the old code misread — and proves the cascade actually advances: both
--- hs.keycodes attempts are made AND the osascript fallback is reached. Pre-fix
--- setLayout is called once, hs.execute is never called, and the function
--- returns true.
--- ==============================================================================

local helpers = require("tests.helpers")

local LOCALISED_NAME = "Ergopti+"
local KL_NAME        = "Ergopti_v2_2_2_plus"


helpers.describe("set_input_source: a setLayout that returns false must fall through", function()
	helpers.it("tries both hs.keycodes names and then reaches the TIS osascript fallback", function()
		local IS = helpers.load_with_stubs("modules.keymap.input_sources")

		-- setLayout signals failure the way the real API does: a false RETURN
		-- value, no error raised. This is what pcall's status bit hides.
		local setlayout_args = {}
		hs.keycodes.setLayout = function(name)
			table.insert(setlayout_args, name)
			return false
		end
		hs.keycodes.currentLayout = function() return "French" end

		local result = IS.set_input_source(LOCALISED_NAME, KL_NAME)

		-- Attempt 1 (localised) must not be treated as a success, so attempt 2
		-- (kl_name) must also run — it was dead code before the fix.
		helpers.assert_eq(#setlayout_args, 2,
			"both setLayout candidates must be attempted when the first RETURNS false")
		helpers.assert_eq(setlayout_args[1], LOCALISED_NAME)
		helpers.assert_eq(setlayout_args[2], KL_NAME)

		-- The load-bearing assertion: the TIS fallback actually executed.
		local osascript_cmd = nil
		for _, cmd in ipairs(hs.__exec_calls) do
			if type(cmd) == "string" and cmd:find("/usr/bin/osascript", 1, true) then
				osascript_cmd = cmd
			end
		end
		helpers.assert_not_nil(osascript_cmd,
			"the TIS osascript fallback must be reached when hs.keycodes declines both names")

		-- And a switch that never happened must not be reported as a success.
		helpers.assert_eq(result, false,
			"set_input_source must return false when no strategy actually switched the layout")

		package.loaded["modules.keymap.input_sources"] = nil
	end)

	helpers.it("still short-circuits on the first name when setLayout RETURNS true", function()
		local IS = helpers.load_with_stubs("modules.keymap.input_sources")

		local setlayout_args = {}
		hs.keycodes.setLayout = function(name)
			table.insert(setlayout_args, name)
			return true
		end
		hs.keycodes.currentLayout = function() return "French" end

		local result = IS.set_input_source(LOCALISED_NAME, KL_NAME)

		helpers.assert_eq(result, true, "a genuine switch must still report success")
		helpers.assert_eq(#setlayout_args, 1,
			"a successful first attempt must not fall through to the retry")
		for _, cmd in ipairs(hs.__exec_calls) do
			helpers.assert_true(not (type(cmd) == "string" and cmd:find("/usr/bin/osascript", 1, true)),
				"the osascript fallback must NOT run once hs.keycodes reports a real switch")
		end

		package.loaded["modules.keymap.input_sources"] = nil
	end)
end)
