--- tests/unit/infra/test_hotpath_segments_declared.lua

--- ==============================================================================
--- MODULE: Hot-path Segment Inventory Test (Linux driver)
--- DESCRIPTION:
--- Holds the Linux driver to the shared segment inventory: every span of the
--- typing path (key event, tap-hold, character callback, hotstring match,
--- expansion, uinput write, keystats ingest) is declared with its reason, and a
--- new Perf.span either joins the inventory or is named below as timed-only.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Spans that are timed for the interval summary but are not hot-path segments:
-- the idle wait is long by design, the periodic tick, the tray, the keystats
-- flush, a layout switch and a catalogue reload run off the keystroke, and a
-- key's age from its kernel stamp includes the loop's queueing by design.
local TIMED_ONLY = {
	["loop.idle"] = true, ["loop.periodic"] = true,
	["keystats.flush"] = true, ["tray.build"] = true, ["tray.open"] = true, ["tray.fill"] = true,
	["input.latency"] = true, ["layout.switch"] = true, ["config.reload"] = true,
}

require("tests.lua.core.hotpath_segments_contract").register(helpers, {
	driver = "linux",
	directory = require("core.fs.engine.native_directory"),
	root = helpers.driver_root(),
	call_patterns = { 'Perf%.span%(%s*"([^"]+)"', 'Perf%.done%(%s*"([^"]+)"', 'Perf%.record_age%(%s*"([^"]+)"' },
	timed_only = TIMED_ONLY,
	default_slow_ms = require("infra.timings").ms("logger", "hotpath_slow_ms"),
})

helpers.describe("hot-path segment inventory: linux spans", function()
	helpers.it("declares every inventory segment as a perf span", function()
		local spans = helpers.load_module("infra.perf_counters").snapshot().spans
		for name in pairs(require("metrics.engine.perf.hotpath_segments").for_driver("linux")) do
			helpers.assert_true(spans[name] ~= nil, "'" .. name .. "' is in the inventory but is not a perf span")
		end
	end)
end)
