--- tests/unit/infra/field_check/test_field_check_event_taps.lua

--- ==============================================================================
--- MODULE: Field Run Event Taps Probe
--- DESCRIPTION:
--- The field run's event tap check over scripted ports:
--- 1. every keymap tap is its own step, so a tap macOS disabled fails by name
---    while the others pass, and a stopped watchdog or keymap fails;
--- 2. the run loop is probed several times and the worst lateness decides, so
---    one late timer among punctual ones still fails the step;
--- 3. the session's holds, late keys and Lua heap are information only.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

--- Builds scripted ports.
--- @return table ports, table world
local function make_ports()
	local world = {
		states = {
			started = true,
			watchdog = true,
			taps = {
				{ name = "keyDown", state = "enabled" },
				{ name = "loopbackKeyUp", state = "enabled" },
				{ name = "flagsChanged", state = "enabled" },
				{ name = "mouse", state = "enabled" },
			},
		},
		lateness = { 3, 5, 2, 8, 4 },
		probes = 0,
	}
	local ports = {
		tap_states = function() return world.states end,
		health_counts = function() return { late_downs = 2, late_ups = 1, stale_passed = 0 } end,
		hold_counts = function() return { over_250ms = 4, over_1000ms = 1 } end,
		lua_heap_kb = function() return 45 * 1024 + 300 end,
		timer_probe = function(seconds, callback)
			world.probes = world.probes + 1
			world.seconds = seconds
			callback(world.lateness[world.probes] or 0)
		end,
	}
	return ports, world
end

--- Runs the check and returns its steps keyed by id.
--- @param ports table Ports.
--- @return table steps, table result
local function run(ports)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["infra.field_check_probes"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run("event_taps", ports, function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("event taps probe", function()
	helpers.it("passes with every tap enabled, the watchdog running and a punctual run loop", function()
		local ports, world = make_ports()
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.tap_keyDown.value, "enabled")
		helpers.assert_eq(steps.tap_mouse.state, "pass")
		helpers.assert_eq(steps.tap_watchdog.value, "running")
		helpers.assert_eq(steps.runloop_late_ms.value, "8")
		helpers.assert_eq(world.probes, 5)
		helpers.assert_eq(steps.key_late.value, "3")
		helpers.assert_eq(steps.holds_over_250ms.value, "4")
		helpers.assert_eq(steps.holds_over_1000ms.state, "info")
		helpers.assert_eq(steps.lua_heap_mb.value, "45")
	end)

	helpers.it("names the one tap macOS disabled", function()
		local ports, world = make_ports()
		world.states.taps[2].state = "disabled"
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.tap_loopbackKeyUp.state, "fail")
		helpers.assert_eq(steps.tap_loopbackKeyUp.value, "disabled")
		helpers.assert_eq(steps.tap_keyDown.state, "pass")
	end)

	helpers.it("fails a stopped watchdog, a stopped keymap and an absent keymap", function()
		local ports, world = make_ports()
		world.states.watchdog = false
		helpers.assert_eq(run(ports).tap_watchdog.state, "fail")
		world.states.watchdog = true
		world.states.started = false
		helpers.assert_eq(run(ports).keymap_started.value, "no")
		world.states = nil
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.keymap_started.value, "not_loaded")
		helpers.assert_nil(steps.tap_keyDown)
	end)

	helpers.it("fails the run loop when one probe of five comes late", function()
		local ports, world = make_ports()
		world.lateness = { 3, 5, 612.4, 8, 4 }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.runloop_late_ms.state, "fail")
		helpers.assert_eq(steps.runloop_late_ms.value, "612")
	end)
end)
