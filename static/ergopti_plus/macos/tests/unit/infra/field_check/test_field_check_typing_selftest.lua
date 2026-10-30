--- tests/unit/infra/field_check/test_field_check_typing_selftest.lua

--- ==============================================================================
--- MODULE: Field Run Typing Self-Test Probe
--- DESCRIPTION:
--- The automatic key accounting over scripted ports:
--- 1. the self-test types the fixed sequence into the scratch field only; a
---    field that never had the focus, a focus lost mid-sequence, a tap that
---    missed or doubled a key and a field holding other text each fail their
---    own step, and the previous app must get the focus back;
--- 2. the Karabiner path and the ledger's double count are named as needing
---    physical keys, and the keystrokes keystats gains are named;
--- 3. a typing that has not settled when the counter stops fails, never passes.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

--- Builds scripted ports.
--- @return table ports, table world
local function make_ports()
	local world = {
		typed = { focused = true, posted = 4, text = "wkjx", latency_ms = 420.7, restored = true },
		presses = 4,
		ledger = { 10, 10 },
		reads = 0,
	}
	local ports = {
		keystats_facts = function()
			world.reads = world.reads + 1
			return { ledger_drained = world.ledger[world.reads] or 0, credit_source = "legacy" }
		end,
		count_keys = function(seconds, callback)
			world.count_seconds = seconds
			world.finish_count = function() callback({ tap_running = true, presses = world.presses }) end
		end,
		scratch_typing = function(keys, callback)
			world.keys = keys
			if not world.unsettled then callback(world.typed) end
			world.finish_count()
		end,
	}
	return ports, world
end

--- Runs one check and returns its steps keyed by id.
--- @param check string Check id.
--- @param ports table Ports.
--- @return table steps, table result
local function run(check, ports)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["infra.field_check_probes"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run(check, ports, function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("typing self-test probe", function()
	helpers.it("passes when the scratch field got every key once and the focus came back", function()
		local ports, world = make_ports()
		local steps, result = run("typing_selftest", ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(table.concat(world.keys), "wkjx")
		helpers.assert_eq(steps.scratch_focus.value, "focused")
		helpers.assert_eq(steps.keys_posted.value, "4")
		helpers.assert_eq(steps.presses_seen.value, "seen_4_of_4")
		helpers.assert_eq(steps.field_text.value, "exact")
		helpers.assert_eq(steps.type_latency_ms.value, "420")
		helpers.assert_eq(steps.ledger_credits.value, "0")
		helpers.assert_eq(steps.karabiner_path.value, "physical_keys_only")
		helpers.assert_eq(steps.double_count.state, "skip")
		helpers.assert_eq(steps.keystats_effect.value, "4_keys_credited_to_ergoptiplus")
	end)

	helpers.it("fails a field that never had the focus, without typing", function()
		local ports, world = make_ports()
		world.typed = { focused = false, posted = 0, aborted = "not_frontmost", restored = true }
		world.presses = 0
		local steps, result = run("typing_selftest", ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.scratch_focus.value, "not_frontmost")
		helpers.assert_eq(steps.keys_posted.value, "posted_0_of_4:not_frontmost")
		helpers.assert_eq(steps.presses_seen.state, "fail")
		helpers.assert_eq(steps.field_text.state, "skip")
	end)

	helpers.it("names a focus lost mid-sequence, a missed or doubled key and other text", function()
		local ports, world = make_ports()
		world.typed = { focused = true, posted = 2, aborted = "focus_lost_window_unfocused", text = "wk", restored = true }
		world.presses = 2
		local steps = run("typing_selftest", ports)
		helpers.assert_eq(steps.keys_posted.value, "posted_2_of_4:focus_lost_window_unfocused")
		helpers.assert_eq(steps.field_text.value, "mismatch_2_chars")
		world.typed = { focused = true, posted = 4, text = "wkjx", restored = true }
		world.presses = 8
		world.reads = 0
		steps = run("typing_selftest", ports)
		helpers.assert_eq(steps.presses_seen.value, "seen_8_of_4")
		helpers.assert_eq(steps.presses_seen.state, "fail")
	end)

	helpers.it("fails a focus that did not come back and a typing that did not settle", function()
		local ports, world = make_ports()
		world.typed.restored = false
		local steps, result = run("typing_selftest", ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.front_restored.state, "fail")
		world.reads = 0
		world.unsettled = true
		steps, result = run("typing_selftest", ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.scratch_focus.value, "typing_unsettled")
	end)
end)

