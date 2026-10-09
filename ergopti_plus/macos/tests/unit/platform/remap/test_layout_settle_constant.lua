--- tests/unit/platform/remap/test_layout_settle_constant.lua

--- ==============================================================================
--- MODULE: Regression — layout-settle delay is registry-sourced (F-LOW-3)
--- DESCRIPTION:
--- The 0.5 s delay before rebuilding the Karabiner config after a layout switch
--- (it absorbs the asynchronous TIS keycode-map update; too short generates wrong
--- physical keys in karabiner.json) was a bare inline literal — every sibling
--- timing on this hot path is sourced from the Timings registry. A load-bearing
--- latency must be a named, registry-sourced constant so both drivers and the
--- test suite share one tunable value (copilot-instructions §5.1 / §5.2).
---
--- Fix: add layout_tis_settle_ms to _shared/modules/timings/constants.toml [debounce] and
--- read it via Timings.sec in karabiner/init.lua.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("karabiner: layout-settle delay is a registry constant, not a magic number (F-LOW-3)", function()
	helpers.it("init.lua sources the layout rebuild delay from Timings, not a bare 0.5", function()
		local src = helpers.read_driver_source("local KARABINER_KE_TILDE_PATH")
		helpers.assert_true(src ~= nil, "platform/remap/init.lua source must be locatable")
		if not src then return end

		helpers.assert_true(src:find('Timings.sec("debounce", "layout_tis_settle_ms")', 1, true) ~= nil,
			"the layout-settle delay must be sourced from Timings.sec(debounce, layout_tis_settle_ms)")
		helpers.assert_true(
			src:find("pending.tis_settled and 0 or LAYOUT_TIS_SETTLE_SEC", 1, true) ~= nil,
			"new events must use the registry delay while already-settled replays run next-turn")
		helpers.assert_true(src:find("_layout_rebuild_timer = hs.timer.doAfter(0.5,", 1, true) == nil,
			"the bare inline 0.5 literal for the layout rebuild must be gone")
	end)

	helpers.it("constants.toml defines layout_tis_settle_ms", function()
		local path = helpers.shared("modules/timings/constants.toml")
		local fh = io.open(path, "r"); helpers.assert_true(fh ~= nil, "cannot open constants.toml")
		local toml = fh:read("*a"); fh:close()
		helpers.assert_true(toml:find("layout_tis_settle_ms", 1, true) ~= nil,
			"_shared/modules/timings/constants.toml must define layout_tis_settle_ms")
	end)
end)
