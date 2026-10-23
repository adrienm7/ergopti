--- tests/unit/infra/logger/test_phase_stats.lua

--- ==============================================================================
--- MODULE: phase_stats Unit Tests
--- DESCRIPTION:
--- Pins the permanent phase counters: recording keeps counts, totals and
--- maxima without building text, the flush emits one evidence line per family
--- only when INFO is enabled, a long phase is attributable to a main-thread
--- hold, and the periodic timer refuses a second start.
--- ==============================================================================

local helpers = require("tests.helpers")

local evidence = {}
local info_enabled = true
local real_logger = package.loaded["infra.logger"]
package.loaded["infra.logger"] = {
	evidence = function(tag, fmt, ...) evidence[#evidence + 1] = string.format(fmt, ...) return true end,
	is_enabled = function() return info_enabled end,
	LEVELS = { DEBUG = 1, INFO = 2, WARNING = 3, ERROR = 4 },
	error = function() end, start = function() end, done = function() end,
}
package.loaded["infra.phase_stats"] = nil
local Stats = require("infra.phase_stats")

local NS = 0
Stats.use_clock(function() return NS end)
local MS = 1e6

local function fresh()
	Stats.reset()
	evidence = {}
	info_enabled = true
end

helpers.describe("infra.phase_stats recording", function()
	helpers.it("keeps count, total and maximum per phase", function()
		fresh()
		Stats.add("keymap.match", 1 * MS)
		Stats.add("keymap.match", 3 * MS)
		local figures = Stats.figures("keymap.match")
		helpers.assert_eq(figures.n, 2)
		helpers.assert_true(math.abs(figures.total_ms - 4) < 1e-9, "total is the sum")
		helpers.assert_true(math.abs(figures.max_ms - 3) < 1e-9, "maximum is kept")
	end)

	helpers.it("stop closes a phase opened with now", function()
		fresh()
		NS = 100 * MS
		local started = Stats.now()
		NS = 107 * MS
		local elapsed = Stats.stop("menu.rebuild", started)
		helpers.assert_true(math.abs(elapsed - 7) < 1e-9, "returns milliseconds")
		helpers.assert_eq(Stats.figures("menu.rebuild").n, 1)
	end)

	helpers.it("counts plain events", function()
		fresh()
		Stats.count("menu.open_from_cache")
		Stats.count("menu.open_from_cache", 2)
		helpers.assert_eq(Stats.counter("menu.open_from_cache"), 3)
	end)
end)

helpers.describe("infra.phase_stats flush", function()
	helpers.it("emits one evidence line per family plus the memory line", function()
		fresh()
		Stats.add("keymap.match", 1 * MS)
		Stats.add("keymap.preview", 2 * MS)
		Stats.add("menu.rebuild", 90 * MS)
		Stats.count("menu.open_from_cache")
		local lines = Stats.flush(300)
		helpers.assert_eq(lines, 3, "keymap, menu and memory")
		helpers.assert_true(evidence[1]:find("[keymap]", 1, true) ~= nil, "families are sorted")
		helpers.assert_true(evidence[1]:find("preview n=1", 1, true) ~= nil, "phase figures are listed")
		helpers.assert_true(evidence[2]:find("#open_from_cache=1", 1, true) ~= nil, "counters are listed")
		helpers.assert_true(evidence[3]:find("Memory snapshot", 1, true) ~= nil)
	end)

	helpers.it("clears the counters after a flush", function()
		fresh()
		Stats.add("keymap.match", 1 * MS)
		Stats.flush(300)
		helpers.assert_eq(Stats.figures("keymap.match"), nil)
	end)

	helpers.it("formats nothing when INFO is disabled", function()
		fresh()
		info_enabled = false
		Stats.add("keymap.match", 1 * MS)
		helpers.assert_eq(Stats.flush(300), 0)
		helpers.assert_eq(#evidence, 0, "no line when the level is off")
		helpers.assert_eq(Stats.figures("keymap.match"), nil, "counters are still cleared")
	end)
end)

helpers.describe("infra.phase_stats hold attribution", function()
	helpers.it("names the long phases that ended inside the held window", function()
		fresh()
		NS = 500 * MS
		Stats.add("menu_item.hotstrings", 80 * MS)
		NS = 600 * MS
		Stats.add("toml.parse", 30 * MS)
		Stats.add("keymap.match", 0.1 * MS)
		local text = Stats.recent_since(550 * MS)
		helpers.assert_true(text:find("toml.parse=30.0 ms", 1, true) ~= nil)
		helpers.assert_true(text:find("hotstrings", 1, true) == nil, "ended before the window")
		helpers.assert_true(text:find("keymap.match", 1, true) == nil, "short phases stay out of the ring")
	end)

	helpers.it("returns nil when no long phase ran", function()
		fresh()
		helpers.assert_eq(Stats.recent_since(0), nil)
	end)
end)

helpers.describe("infra.phase_stats lifecycle", function()
	helpers.it("arms one timer, refuses a second start and stops it paired", function()
		fresh()
		local real_timer = package.loaded["adapters.timer_scheduler"]
		local armed, cancelled, tick = 0, 0, nil
		package.loaded["adapters.timer_scheduler"] = {
			every = function(_, fn) armed = armed + 1; tick = fn; return { id = armed }, true end,
			cancel = function() cancelled = cancelled + 1; return true end,
		}
		helpers.assert_eq(Stats.start(60), true)
		helpers.assert_eq(Stats.start(60), false, "duplicate initialization is rejected")
		helpers.assert_eq(armed, 1)
		Stats.add("keymap.match", 1 * MS)
		tick()
		helpers.assert_true(#evidence >= 1, "the timer tick flushes the interval")
		helpers.assert_eq(Stats.stop_reporting(), true)
		helpers.assert_eq(cancelled, 1)
		helpers.assert_eq(Stats.stop_reporting(), true, "stopping twice is harmless")
		package.loaded["adapters.timer_scheduler"] = real_timer
	end)
end)

package.loaded["infra.logger"] = real_logger
package.loaded["infra.phase_stats"] = nil
