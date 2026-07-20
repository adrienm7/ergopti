--- tests/unit/lib/test_timings.lua

--- ==============================================================================
--- MODULE: Shared Timings Reader Tests (Hammerspoon)
--- DESCRIPTION:
--- A3 — macOS now reads its timing constants from the cross-driver registry
--- `_shared/modules/timings/constants.toml` via `lib.timings` instead of hardcoding the
--- same literals in each module. These tests pin:
---   1. `M.ms` returns the raw millisecond value and fails fast on a bad
---      section/key.
---   2. `M.sec` is exactly `M.ms / 1000`.
---   3. A parity tripwire on the EXACT keys the wired modules consume
---      (keylogger/init.lua, llm/prediction_engine.lua, gestures/engine.lua) —
---      a drift in constants.toml would silently change those runtime timings,
---      so this turns red first.
--- ==============================================================================

local helpers = require("tests.helpers")

-- lib.timings logs through lib.logger; load the stub first.
package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local Timings = require("lib.timings")

-- The exact (section, key) -> value pairs each wired module is now sourced from.
-- Mirror these against constants.toml; a change there must be deliberate.
local WIRED_MS = {
	-- keylogger/init.lua
	{ "keylogger", "micro_idle_timeout_ms",  30000 },
	{ "keylogger", "session_timeout_ms",    300000 },
	{ "keylogger", "wpm_window_ms",          15000 },
	{ "keylogger", "wpm_min_duration_ms",     2000 },
	{ "keylogger", "idle_check_interval_ms",  10000 },
	{ "keylogger", "maintenance_interval_ms",  5000 },
	{ "keylogger", "system_load_poll_ms",    300000 },
	{ "keylogger", "synth_match_delay_ms",        3 },
	{ "keylogger", "auto_flush_idle_ms",     120000 },
	-- llm/prediction_engine.lua
	{ "llm", "prediction_debounce_min_ms",       50 },
	{ "llm", "prediction_debounce_max_ms",      600 },
	{ "llm", "chain_fallback_ms",               500 },
	-- gestures/engine.lua
	{ "gestures", "tap_max_ms",                 700 },
	{ "gestures", "live_rearm_ms",               80 },
	{ "gestures", "live_rearm_reverse_ms",       30 },
	{ "gestures", "finger_confirm_ms",           50 },
	{ "gestures", "finger_drop_confirm_ms",     200 },
	{ "gestures", "finger_count_stable_ms",      60 },
}





-- =====================================
-- =====================================
-- ======= 1/ ms / sec accessors =======
-- =====================================
-- =====================================

helpers.describe("timings: ms / sec accessors", function()
	helpers.it("ms returns the raw millisecond value", function()
		helpers.assert_eq(Timings.ms("keylogger", "synth_match_delay_ms"), 3, "synth_match_delay_ms")
		helpers.assert_eq(Timings.ms("gestures", "tap_max_ms"), 700, "tap_max_ms")
	end)

	helpers.it("sec is exactly ms / 1000", function()
		helpers.assert_eq(Timings.sec("llm", "prediction_debounce_max_ms"), 0.6, "debounce_max sec")
		helpers.assert_eq(Timings.sec("gestures", "finger_count_stable_ms"), 0.06, "stable sec")
	end)

	helpers.it("fails fast on an unknown section", function()
		local ok = pcall(function() return Timings.ms("nope", "whatever_ms") end)
		helpers.assert_eq(ok, false, "ms raises on an unknown section")
	end)

	helpers.it("fails fast on an unknown key", function()
		local ok = pcall(function() return Timings.ms("keylogger", "does_not_exist_ms") end)
		helpers.assert_eq(ok, false, "ms raises on an unknown key")
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 2/ Wired-module parity tripwire =======
-- ===============================================
-- ===============================================

helpers.describe("timings: wired-module parity", function()
	for _, row in ipairs(WIRED_MS) do
		local section, key, expected = row[1], row[2], row[3]
		helpers.it(string.format("ms('%s','%s') == %d", section, key, expected), function()
			helpers.assert_eq(Timings.ms(section, key), expected,
				"registry value for " .. section .. "." .. key)
		end)
	end
end)





-- =============================================================
-- =============================================================
-- ======= 3/ Registry load fails fast on an absent tree =======
-- =============================================================
-- =============================================================

--- Regression: load_registry() used to test only `type(sections) ~= "table"`.
--- TomlReader.parse NEVER returns a table without a `sections` field — both of its
--- failure exits return an empty result whose `sections` is `{}` — so that error
--- was dead code. Worse, Paths.shared() returns nil when the _shared/ tree is
--- missing, and parse(nil) short-circuits, so the path interpolated into the
--- message was itself nil. The registry silently loaded empty and boot died much
--- later, elsewhere, with a misleading "missing section [ui]".
helpers.describe("timings: registry load fail-fast", function()

	--- Reloads lib.timings with lib.paths stubbed so shared() reports the tree as
	--- unreachable, and returns whatever the module raised.
	--- @return boolean,string The pcall status and the raised message.
	local function reload_timings_without_shared_tree()
		local saved_paths   = package.loaded["lib.paths"]
		local saved_timings = package.loaded["lib.timings"]

		package.loaded["lib.paths"] = {
			shared          = function() return nil end,
			shared_root     = function() return nil end,
			shared_llm_path = function() return nil end,
			find_from_configdir = function() return nil end,
		}
		package.loaded["lib.timings"] = nil

		local ok, err = pcall(require, "lib.timings")

		-- Restore the real modules so later suites are unaffected by this probe.
		package.loaded["lib.timings"] = saved_timings
		package.loaded["lib.paths"]   = saved_paths

		return ok, tostring(err)
	end

	helpers.it("raises when the _shared/ tree is unreachable", function()
		local ok, err = reload_timings_without_shared_tree()
		helpers.assert_eq(false, ok,
			"lib.timings must fail fast at load time when the shared tree is missing")
		helpers.assert_true(err:find("_shared/", 1, true) ~= nil,
			"the error must name the unreachable _shared/ tree, got: " .. err)
	end)

	helpers.it("does not report a misleading 'missing section' for an absent tree", function()
		local _, err = reload_timings_without_shared_tree()
		helpers.assert_true(err:find("missing section", 1, true) == nil,
			"an unreachable tree must not masquerade as a missing TOML section, got: " .. err)
	end)

	helpers.it("does not raise a nil-concatenation error", function()
		local _, err = reload_timings_without_shared_tree()
		helpers.assert_true(err:find("concatenate", 1, true) == nil,
			"the guard must fire before the nil path reaches the message, got: " .. err)
	end)

end)
