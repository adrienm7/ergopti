--- tests/unit/modules/keylogger/test_physical_delivery.lua

--- Exercises decoded native delivery without claiming production capture coverage.
local helpers = require("tests.helpers")
local Delivery = require("modules.keylogger.physical_delivery")
local AccountingScope = require("tests.support.physical_accounting_scope")

local function fixture(overrides)
	local emitted, contexts = {}, {}
	local dependencies = {
		batch_limit = 64,
		admit = function(frame)
			-- Only this isolated fixture admits the experimental producer contract.
			helpers.assert_eq(frame.coverage, "fixture_only")
			return "test-capture"
		end,
		keycode = function(usage) return ({ [41] = 53, [44] = 49 })[usage] end,
		context = function(timestamp, device)
			contexts[#contexts + 1] = { timestamp, device }
			return { allowed = true, app = "CapturedApp", timestamp = "2026-09-12 10:00:00.000" }
		end,
		emit = function(entry) emitted[#emitted + 1] = entry end,
	}
	for key, value in pairs(overrides or {}) do dependencies[key] = value end
	return Delivery.new(dependencies), emitted, contexts
end

local function opened()
	return { version = 1, kind = "opened", incarnation = "native-epoch",
		lease = "18446744073709551615", coverage = "fixture_only" }
end

local function batch(rows)
	local frame = opened()
	frame.kind, frame.records = "batch", rows
	return frame
end

local function row(sequence, usage, value, device)
	return { sequence = tostring(sequence), device = device or "18446744073709551614",
		timestamp = "18446744073709550000", has_page = true, has_usage = true,
		page = 7, usage = usage, value = tostring(value) }
end

local function rejects(callback, fragment)
	local ok, err = pcall(callback)
	helpers.assert_eq(ok, false)
	helpers.assert_true(tostring(err):find(fragment, 1, true) ~= nil, tostring(err))
end

helpers.describe("physical delivery (hs274)", function()
	helpers.it("delivers original presses to the real aggregator independently of logical output", function()
		AccountingScope.run(function(events, state)
			local receiver = fixture({ emit = function(press)
				press.action = "physical_press"
				events.walk_system_event(press)
			end })
			receiver.open(opened())
			receiver.deliver(batch({ row(1, 41, 1), row(2, 41, 0), row(3, 44, 1), row(4, 44, 0) }))
			events.walk_typing({ timestamp = "2026-09-12 10:00:00.000", app = "CapturedApp",
				events = { { " ", 100, { s = false } }, { " ", 100, { s = false } } } })
			local counts = {}
			for _, aggregate in pairs(state.agg_batch.kc_ngram) do counts[aggregate.keycode] = aggregate.count end
			helpers.assert_eq(counts, { [53] = 1, [49] = 1 })
			helpers.assert_eq(state.agg_batch.chars_class["2026-09-12\1CapturedApp"].space, 2)
		end)
	end)

	helpers.it("retains original keys and exact capture timestamps alongside auxiliary rows", function()
		local receiver, emitted, contexts = fixture()
		receiver.open(opened())
		receiver.deliver(batch({ row(1, -1, 41), row(2, 1, 0), row(3, 41, 1),
			row(4, 41, 0), row(5, 44, 1), row(6, 44, 0) }))
		helpers.assert_eq(#emitted, 2)
		helpers.assert_eq({ emitted[1].keycode, emitted[2].keycode }, { 53, 49 })
		helpers.assert_eq(emitted[1].capture, "test-capture")
		helpers.assert_eq(emitted[1].app, "CapturedApp")
		helpers.assert_eq(contexts[1], { "18446744073709550000", "18446744073709551614" })
	end)

	helpers.it("validates a complete batch before emitting any credit", function()
		local receiver, emitted = fixture()
		receiver.open(opened())
		rejects(function() receiver.deliver(batch({ row(1, 41, 1), row(3, 44, 1) })) end, "sequence gap")
		helpers.assert_eq(#emitted, 0)
		helpers.assert_eq(receiver.active(), false)
	end)

	helpers.it("fences a replay and a stale lease without adding credits", function()
		for _, stale in ipairs({ false, true }) do
			local receiver, emitted = fixture()
			receiver.open(opened())
			receiver.deliver(batch({ row(1, 41, 1) }))
			local frame = batch({ row(stale and 2 or 1, 44, 1) })
			if stale then frame.lease = "1" end
			rejects(function() receiver.deliver(frame) end, stale and "ownership changed" or "sequence gap")
			helpers.assert_eq(#emitted, 1)
		end
	end)

	helpers.it("does not replay a partially published batch after a sink failure", function()
		local calls = 0
		local receiver = fixture({ emit = function()
			calls = calls + 1
			if calls == 2 then error("sink refused") end
		end })
		receiver.open(opened())
		local frame = batch({ row(1, 41, 1), row(2, 44, 1) })
		rejects(function() receiver.deliver(frame) end, "sink refused")
		rejects(function() receiver.deliver(frame) end, "not active")
		helpers.assert_eq(calls, 2)
	end)

	helpers.it("honors captured privacy and refuses unavailable context", function()
		local receiver, emitted = fixture({ context = function() return { allowed = false } end })
		receiver.open(opened())
		receiver.deliver(batch({ row(1, 41, 1) }))
		helpers.assert_eq(#emitted, 0)
		helpers.assert_eq(receiver.active(), true)
		local missing = fixture({ context = function() return nil end })
		missing.open(opened())
		rejects(function() missing.deliver(batch({ row(1, 41, 1) })) end, "context is unavailable")
	end)

	helpers.it("cannot reactivate a receiver revoked during admission", function()
		local receiver
		receiver = fixture({ admit = function() receiver.stop(); return "test-capture" end })
		rejects(function() receiver.open(opened()) end, "admission was revoked")
		helpers.assert_eq(receiver.active(), false)
	end)

	helpers.it("stops the remainder of a batch when its sink revokes delivery", function()
		local receiver, calls
		calls = 0
		receiver = fixture({ emit = function()
			helpers.assert_eq(receiver.active(), true)
			calls = calls + 1
			receiver.stop()
		end })
		receiver.open(opened())
		rejects(function() receiver.deliver(batch({ row(1, 41, 1), row(2, 44, 1) })) end, "delivery was revoked")
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(receiver.active(), false)
	end)

	helpers.it("refuses unadmitted coverage and active HID errors", function()
		local refused = fixture({ admit = function() return nil end })
		rejects(function() refused.open(opened()) end, "coverage was not admitted")
		local receiver, emitted = fixture()
		receiver.open(opened())
		rejects(function() receiver.deliver(batch({ row(1, 41, 1), row(2, 1, 1) })) end, "keyboard error")
		helpers.assert_eq(#emitted, 0)
	end)
end)
