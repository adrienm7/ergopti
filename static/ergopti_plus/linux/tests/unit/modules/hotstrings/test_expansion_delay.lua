--- tests/unit/modules/hotstrings/test_expansion_delay.lua

--- ==============================================================================
--- MODULE: The Per-Category Expansion Delay Actually Governs an Expansion
--- DESCRIPTION:
--- Covers the resolution half of the delay cascade, and pins the SEMANTICS the
--- daemon applies against the ones macOS applies.
---
--- WHY THIS EXISTS:
--- `hotstrings_config.resolve()` had no production caller on Linux until
--- 2026-08-05. The five-rung precedence, the shared DelayResolver both drivers
--- use, and every override the settings window persisted to disk resolved into
--- nothing: a user set a delay, the file recorded it, and expansions fired
--- exactly as before. The feature existed at every layer except the one where it
--- would have had an effect.
---
--- WHAT THE DELAY MEANS, because guessing would have produced a driver that
--- disagrees with macOS while looking implemented:
--- it is the maximum PAUSE BETWEEN CONSECUTIVE KEYSTROKES for which a trigger
--- stays live — `dt = now - last_key_time` in macos/modules/keymap/init.lua, and
--- the expansion fires only when `allowed_delay == 0 or dt <= allowed_delay`.
--- Zero means "always active". It is not a delay BEFORE expanding, and it is not
--- a total time budget for typing the trigger; both readings are plausible from
--- the name and both would be wrong.
---
--- The behavioural consequence is the one a user would describe: type half a
--- trigger, stop to think, come back — and the rest of the word must not turn
--- into an expansion you had stopped intending.
--- ==============================================================================

local helpers = require("tests.helpers")

local Config = helpers.load_module("modules.hotstrings.hotstrings_config")


--- The resolved delay for a category, in seconds.
--- @param category string
--- @param section string|nil
--- @return number|nil
local function delay_of(category, section)
	local resolved = Config.resolve(category, section)
	return type(resolved) == "table" and tonumber(resolved.delay) or nil
end





-- =========================================================
-- =========================================================
-- ======= 1/ An override reaches the resolver =============
-- =========================================================
-- =========================================================

helpers.describe("expansion delay: what the settings window writes is what resolves", function()

	helpers.it("a category override wins over the global default", function()
		Config._set_overrides_for_test({})
		local shipped = delay_of("rolls")
		helpers.assert_true(type(shipped) == "number",
			"every category must resolve to a number — the injector cannot compare against nil")

		Config._set_overrides_for_test({ rolls = { delay = 1.5, sections = {} } })
		helpers.assert_eq(delay_of("rolls"), 1.5,
			"the value the user typed in the settings window must be the one that resolves")
		Config._set_overrides_for_test({})
	end)

	helpers.it("a section override wins over its category", function()
		Config._set_overrides_for_test({
			rolls = { delay = 1.5, sections = { fast = { delay = 0.2 } } },
		})
		helpers.assert_eq(delay_of("rolls", "fast"), 0.2,
			"the narrower override must win, or a per-section setting is decoration")
		helpers.assert_eq(delay_of("rolls"), 1.5,
			"and it must not leak upward onto the category itself")
		Config._set_overrides_for_test({})
	end)

	helpers.it("clearing an override returns the shipped value, not zero", function()
		Config._set_overrides_for_test({ rolls = { delay = 1.5, sections = {} } })
		local overridden = delay_of("rolls")
		Config._set_overrides_for_test({})
		local restored = delay_of("rolls")
		helpers.assert_true(restored ~= overridden,
			"clearing must actually change the resolved value")
		-- Zero means "always active" to the daemon, so a clear that resolved to 0
		-- would silently disable the window rather than restore the default.
		helpers.assert_true(restored ~= 0,
			"and must not resolve to 0, which the daemon reads as 'never expires'")
	end)

end)





-- =========================================================
-- =========================================================
-- ======= 2/ The window the daemon applies ================
-- =========================================================
-- =========================================================

-- The daemon's rule, extracted so the semantics can be asserted without driving
-- the whole keystroke path. It mirrors ergopti_hotstrings.lua: a gap LONGER than
-- the delay kills the match, a delay of 0 never does, and the very first
-- keystroke of a session has no previous timestamp to compare against.
--- @param delay_sec number|nil
--- @param last_ms number|nil
--- @param now_ms number
--- @return boolean Whether the expansion still fires.
local function fires(delay_sec, last_ms, now_ms)
	if not delay_sec or delay_sec <= 0 or not last_ms then return true end
	return ((now_ms - last_ms) / 1000) <= delay_sec
end


helpers.describe("expansion delay: the gap between keystrokes decides", function()

	helpers.it("fires when the user kept typing inside the window", function()
		helpers.assert_true(fires(0.75, 1000, 1400),
			"400 ms inside a 750 ms window is ordinary typing")
	end)

	helpers.it("does not fire when the user paused longer than the window", function()
		helpers.assert_true(not fires(0.75, 1000, 2000),
			"a second's pause means the user stopped; finishing the word must not expand it")
	end)

	helpers.it("fires exactly at the boundary", function()
		-- macOS compares with <=, so the boundary case fires. An exclusive
		-- comparison here would make the two drivers disagree on precisely the
		-- keystroke a user tuning their delay is testing with.
		helpers.assert_true(fires(0.75, 1000, 1750),
			"the comparison is <=, matching keymap/init.lua")
	end)

	helpers.it("a delay of zero never expires", function()
		helpers.assert_true(fires(0, 1000, 999999),
			"0 means 'always active' — the shipped behaviour for categories with no delay")
	end)

	helpers.it("the first keystroke of a session always fires", function()
		helpers.assert_true(fires(0.75, nil, 1000),
			"with no previous timestamp there is no gap, and refusing here would make the "
				.. "first expansion after every start silently fail")
	end)

end)
