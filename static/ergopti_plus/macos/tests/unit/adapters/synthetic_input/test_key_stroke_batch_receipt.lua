--- tests/unit/adapters/synthetic_input/test_key_stroke_batch_receipt.lua

--- ==============================================================================
--- MODULE: Synthetic Key Stroke Batch Receipts
--- DESCRIPTION:
--- Preserves boolean admission while exposing exact batch identity to handoff owners.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_input_fixture")

--- Runs the actual broker with controlled native timing and Quartz ports.
local function with_broker(scenario)
	helpers.with_stub_scope({ "adapters.synthetic_input", "adapters.event_provenance",
		"adapters.storage", "adapters.timer_scheduler", "infra.logger", "json" }, function()
		local f = Fixture.make()
		scenario(f, f.load())
	end)
end

--- Delivers only pending native timer owners, with a strict bounded drain.
local function drain(f)
	for _ = 1, 30 do
		if #f.timers == 0 then return end
		f.fire_next_timer()
	end
	error("batch receipt timer drain exhausted")
end

helpers.describe("key stroke receipts preserve exact batch handoff", function()
	helpers.it("returns the shared callback batch without changing admission (stroke-receipt-collector)", function()
		with_broker(function(f, input)
			local tx = input.begin("unit.receipt", "replacement")
			local seen
			input.on_dispatched(tx, function(_, batch, status) seen = { batch, status } end)
			input.enter_callback()
			local accepted, batch = input.emit_key_stroke({}, "a", 0, tx)
			local second, same = input.emit_key_stroke({}, "b", 0, tx)
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(second, true)
			helpers.assert_true(rawequal(batch, same))
			helpers.assert_true(input.seal(tx))
			local consume, events = input.leave_callback(true)
			helpers.assert_true(consume)
			helpers.assert_eq(#events, 4)
			drain(f)
			helpers.assert_true(rawequal(seen[1], batch))
			helpers.assert_eq(seen[2], "dispatched")
		end)
	end)

	helpers.it("returns distinct deferred batches with their own dispatch identities (stroke-receipt-deferred)", function()
		with_broker(function(f, input)
			local tx = input.begin("unit.receipt", "action")
			local seen = {}
			input.on_dispatched(tx, function(_, batch, status) seen[batch] = status end)
			local accepted, a = input.emit_key_stroke({}, "a", 0, tx)
			local second, b = input.emit_key_stroke({}, "b", 0, tx)
			helpers.assert_true(accepted and second)
			helpers.assert_true(not rawequal(a, b))
			helpers.assert_true(input.seal(tx))
			drain(f)
			helpers.assert_eq(seen[a], "dispatched")
			helpers.assert_eq(seen[b], "dispatched")
		end)
	end)

	helpers.it("keeps a refusal receipt when dispatch scheduling fails (stroke-receipt-refusal)", function()
		with_broker(function(f, input)
			local tx = input.begin("unit.receipt", "action")
			local seen
			input.on_dispatched(tx, function(_, batch, status) seen = { batch, status } end)
			f.fail_next_do_after = true
			local accepted, batch = input.emit_key_stroke({}, "a", 0, tx)
			helpers.assert_eq(accepted, false)
			helpers.assert_not_nil(batch)
			drain(f)
			helpers.assert_not_nil(seen)
			helpers.assert_true(rawequal(seen[1], batch))
			helpers.assert_true(seen[2] == "cancelled" or seen[2] == "failed")
		end)
	end)
end)
