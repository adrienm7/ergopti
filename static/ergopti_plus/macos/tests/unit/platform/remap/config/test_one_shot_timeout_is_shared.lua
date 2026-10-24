--- tests/unit/platform/remap/config/test_one_shot_timeout_is_shared.lua

--- ==============================================================================
--- MODULE: One-shot Shift timeout default (macOS)
--- DESCRIPTION:
--- Windows and Linux cancel an armed one-shot Shift after the timing registry's
--- tap_hold.one_shot_shift_timeout_ms (2000 ms). macOS declared its own
--- sticky_timeout_ms = 3000 beside it in [hs_timeouts], so the same one-shot
--- Shift lasted 50 % longer there, with no reason stated (PAR-15). The default
--- must be the registry's value, read through the shared timings reader.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("remap defaults: the one-shot timeout is the shared registry's (one-shot-timeout-shared)", function()
	helpers.it("takes the cross-driver registry value, not a macOS-only one (one-shot-timeout-shared)", function()
		package.loaded["platform.remap.defaults"] = nil
		local Timings = require("infra.timings")
		local Defaults = require("platform.remap.defaults")
		helpers.assert_eq(Defaults.sticky_timeout_ms, Timings.ms("tap_hold", "one_shot_shift_timeout_ms"),
			"the macOS one-shot default is the value Windows and Linux read")
		helpers.assert_eq(Defaults.sticky_timeout_ms, 2000)
	end)
end)
