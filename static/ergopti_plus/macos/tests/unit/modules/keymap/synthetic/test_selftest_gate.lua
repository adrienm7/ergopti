--- tests/unit/modules/keymap/synthetic/test_selftest_gate.lua

--- ==============================================================================
--- MODULE: Keymap Selftest Gate Tests
--- DESCRIPTION:
--- A field-run selftest key is decoded as typing only when all of these hold:
--- the process is a developer runtime, the field run published its scratch
--- window, that window is the focused one, and the delivery is not a duplicate.
--- Each failing gate refuses with its own token, a read that raises refuses
--- too, and only the first refusal of a publication is logged, deferred off
--- the eventtap. The publisher rejects a second owner and a stale retraction.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"infra.logger", "adapters.synthetic_input", "infra.field_run_selftest", "modules.keymap.selftest_gate",
}

local SCRATCH_WINDOW = 4242

--- Loads a fresh gate over scripted reads and a recording logger.
--- @param world table { dev, focused } read by the gate's ports.
--- @param body function fn(Gate, Publisher, log).
local function with_gate(world, body)
	helpers.with_stub_scope(MODULES, function()
		local log = { warns = {}, deferred = {} }
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, message, ...) log.warns[#log.warns + 1] = string.format(message, ...) end
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.synthetic_input"] = {
			defer_after_callback = function(_, fn)
				log.deferred[#log.deferred + 1] = fn
				return true
			end,
		}
		package.loaded["infra.field_run_selftest"] = nil
		package.loaded["modules.keymap.selftest_gate"] = nil
		local Publisher = require("infra.field_run_selftest")
		local Gate = require("modules.keymap.selftest_gate")
		Gate._ports = {
			dev_source_active = function()
				if world.dev == "raise" then error("dev source unreadable") end
				return world.dev
			end,
			focused_own_window_id = function() return world.focused end,
		}
		body(Gate, Publisher, log)
	end)
end

--- A live selftest provenance record as the keymap receives it.
--- @param duplicate boolean|nil
--- @return table provenance
local function selftest_key(duplicate)
	return { owned = true, selftest = true, effect = "replacement", duplicate = duplicate == true }
end

helpers.describe("keymap selftest gate", function()
	helpers.it("admits a key while dev mode, the published window and the focus all hold", function()
		with_gate({ dev = true, focused = SCRATCH_WINDOW }, function(Gate, Publisher, log)
			Publisher.publish(SCRATCH_WINDOW)
			local admitted, reason = Gate.admits(selftest_key())
			helpers.assert_true(admitted)
			helpers.assert_nil(reason)
			helpers.assert_eq(#log.deferred, 0, "an admitted key logs nothing")
		end)
	end)

	helpers.it("refuses outside a developer runtime", function()
		with_gate({ dev = false, focused = SCRATCH_WINDOW }, function(Gate, Publisher)
			Publisher.publish(SCRATCH_WINDOW)
			local admitted, reason = Gate.admits(selftest_key())
			helpers.assert_true(admitted == false)
			helpers.assert_eq(reason, "no_dev_source")
		end)
	end)

	helpers.it("refuses while no typing step published its window", function()
		with_gate({ dev = true, focused = SCRATCH_WINDOW }, function(Gate, Publisher)
			local admitted, reason = Gate.admits(selftest_key())
			helpers.assert_true(admitted == false)
			helpers.assert_eq(reason, "no_active_step")
			-- A retracted window refuses exactly like one never published.
			local generation = Publisher.publish(SCRATCH_WINDOW)
			Publisher.retract(generation)
			admitted, reason = Gate.admits(selftest_key())
			helpers.assert_true(admitted == false)
			helpers.assert_eq(reason, "no_active_step")
		end)
	end)

	helpers.it("refuses while another window has the focus", function()
		with_gate({ dev = true, focused = 7 }, function(Gate, Publisher)
			Publisher.publish(SCRATCH_WINDOW)
			local admitted, reason = Gate.admits(selftest_key())
			helpers.assert_true(admitted == false)
			helpers.assert_eq(reason, "other_window")
		end)
		-- Another application in front reads as no focused window of this process.
		with_gate({ dev = true, focused = nil }, function(Gate, Publisher)
			Publisher.publish(SCRATCH_WINDOW)
			helpers.assert_eq(select(2, Gate.admits(selftest_key())), "other_window")
		end)
	end)

	helpers.it("refuses a duplicate delivery and a read that raises", function()
		with_gate({ dev = true, focused = SCRATCH_WINDOW }, function(Gate, Publisher)
			Publisher.publish(SCRATCH_WINDOW)
			helpers.assert_eq(select(2, Gate.admits(selftest_key(true))), "duplicate")
		end)
		with_gate({ dev = "raise", focused = SCRATCH_WINDOW }, function(Gate, Publisher)
			Publisher.publish(SCRATCH_WINDOW)
			local admitted, reason = Gate.admits(selftest_key())
			helpers.assert_true(admitted == false)
			helpers.assert_eq(reason, "gate_error")
		end)
	end)

	helpers.it("logs the first refusal of each publication once, off the eventtap", function()
		with_gate({ dev = true, focused = 7 }, function(Gate, Publisher, log)
			local generation = Publisher.publish(SCRATCH_WINDOW)
			Gate.admits(selftest_key())
			Gate.admits(selftest_key())
			helpers.assert_eq(#log.deferred, 1, "one refusal diagnostic per run")
			helpers.assert_eq(#log.warns, 0, "the diagnostic is deferred, never written on the tap")
			log.deferred[1]()
			helpers.assert_eq(#log.warns, 1)
			helpers.assert_contains(log.warns[1], "other_window")
			Publisher.retract(generation)
			Publisher.publish(SCRATCH_WINDOW)
			Gate.admits(selftest_key())
			helpers.assert_eq(#log.deferred, 2, "the next run logs its own first refusal")
		end)
	end)

	helpers.it("the publisher keeps one owner and refuses a stale retraction", function()
		with_gate({ dev = true, focused = SCRATCH_WINDOW }, function(_, Publisher)
			helpers.assert_throws(function() Publisher.publish(0) end)
			helpers.assert_throws(function() Publisher.publish("4242") end)
			local first = Publisher.publish(SCRATCH_WINDOW)
			helpers.assert_throws(function() Publisher.publish(SCRATCH_WINDOW + 1) end)
			helpers.assert_eq(Publisher.window_id(), SCRATCH_WINDOW)
			Publisher.retract(first)
			helpers.assert_throws(function() Publisher.retract(first) end)
			local second = Publisher.publish(SCRATCH_WINDOW + 1)
			helpers.assert_throws(function() Publisher.retract(first) end,
				"an earlier run's late callback must not close a later run's window")
			helpers.assert_eq(Publisher.window_id(), SCRATCH_WINDOW + 1)
			Publisher.retract(second)
			helpers.assert_nil(Publisher.window_id())
		end)
	end)
end)
