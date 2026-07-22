--- tests/meta/test_timings_stub_isolation.lua

--- ==============================================================================
--- MODULE: Regression — a leaked partial lib.timings stub is isolated
--- DESCRIPTION:
--- test_apply_prediction_paste_ops.lua installs a minimal
--- `package.loaded["lib.timings"] = { sec = function() ... end }` stub (no
--- M.ms) and never restores it. Once modules.keylogger is not already cached,
--- the next test whose require chain reaches modules.keylogger (e.g. via
--- modules.keymap.llm_bridge, which requires modules.keylogger directly) hits
--- modules/keylogger/init.lua's module-level `Timings.ms("keylogger",
--- "micro_idle_timeout_ms")` call and crashes with "attempt to call a nil
--- value (field 'ms')" — exactly the same order/GC-dependent contamination
--- class as F-T1 (lib.i18n) and F-HIGH-23 (modules.keymap.registry*). Fix:
--- load_with_stubs always drops the cached lib.timings entry so any later
--- test's require chain gets the real module (or a deliberately fresh stub)
--- instead of inheriting a partial one from an earlier test file.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("load_with_stubs isolates modules.keylogger from a leaked lib.timings stub", function()
	helpers.it("clears a cached partial lib.timings stub so the real module reloads with M.ms", function()
		-- Simulate the polluting predecessor: a lib.timings stub missing M.ms,
		-- exactly what test_apply_prediction_paste_ops.lua installs.
		package.loaded["lib.timings"] = { sec = function() return 0.1 end }

		-- Any load_with_stubs call must drop the cached partial stub.
		helpers.load_with_stubs("lib.logger")
		helpers.assert_nil(package.loaded["lib.timings"], "load_with_stubs must clear a cached lib.timings entry")

		-- The next require must load the real module, whose M.ms is callable
		-- and returns a real registry value (not nil, not an error).
		local Timings = require("lib.timings")
		helpers.assert_eq(type(Timings.ms), "function", "the real lib.timings must expose M.ms")
		helpers.assert_eq(type(Timings.ms("keylogger", "micro_idle_timeout_ms")), "number",
			"Timings.ms(\"keylogger\", \"micro_idle_timeout_ms\") must resolve to a real registry value")
	end)

	helpers.it("modules.keylogger loads cleanly after a leaked partial lib.timings stub", function()
		package.loaded["lib.timings"]       = { sec = function() return 0.1 end }
		package.loaded["modules.keylogger"] = nil

		helpers.load_with_stubs("lib.logger")

		local ok, err = pcall(require, "modules.keylogger")
		helpers.assert_true(ok, "modules.keylogger must load without error after a leaked partial lib.timings stub: " .. tostring(err))
	end)
end)
