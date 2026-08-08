--- tests/unit/modules/keymap/test_emit_tokens_multi_paste.lua

--- ==============================================================================
--- MODULE: keymap.utils multi-segment paste serialisation
--- DESCRIPTION:
--- Two clipboard segments must never overwrite each other before the first
--- Cmd+V is handed off. The real SyntheticInput collector proves that inline
--- and deferred output retain one generation and monotonic event ordinals.
--- ==============================================================================

local helpers = require("tests.helpers")


local function two_segment_tokens()
	return {
		{ kind = "text", value = ("A"):rep(60) },
		{ kind = "key", value = "return" },
		{ kind = "text", value = ("B"):rep(60) },
	}
end


local function load_fixture()
	for _, name in ipairs({
		"modules.keymap.utils", "adapters.synthetic_input",
		"adapters.event_provenance", "adapters.timer_scheduler",
		"infra.logger", "infra.timings",
	}) do
		package.loaded[name] = nil
	end
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.timings"] = {
		sec = function(_, key)
			return key == "clipboard_restore_ms" and 0.15 or 0.08
		end,
	}

	local pasted_values = {}
	hs_stub.pasteboard.setContents = function(value)
		if value ~= "" then pasted_values[#pasted_values + 1] = value end
		return true
	end
	return {
		hs = hs_stub,
		synthetic = require("adapters.synthetic_input"),
		utils = require("modules.keymap.utils"),
		pasted_values = pasted_values,
	}
end


local function emit_in_callback(fixture, tokens)
	fixture.synthetic.enter_callback()
	local transaction = fixture.synthetic.begin("test.multi_paste", "replacement")
	local results = table.pack(fixture.synthetic.with_transaction(transaction, function()
		return fixture.utils.emit_tokens(tokens)
	end))
	fixture.synthetic.seal(transaction)
	local consume, events = fixture.synthetic.leave_callback(true)
	return results, consume, events, transaction
end


local function fire_existing_delay(hs_stub, delay)
	local initial_count = #hs_stub.timer.__timers
	local fired = 0
	for index = 1, initial_count do
		local timer = hs_stub.timer.__timers[index]
		if timer.running and math.abs(timer.delay - delay) < 0.000001 then
			timer:fire()
			fired = fired + 1
		end
	end
	return fired
end


local function metadata(fixture, event)
	local property = fixture.hs.eventtap.event.properties.eventSourceUserData
	return fixture.synthetic.lookup_tag(event:getProperty(property))
end


helpers.describe("KU.emit_tokens: multi-segment paste is serialised", function()
	helpers.it("writes only the first clipboard segment synchronously", function()
		local fixture = load_fixture()
		emit_in_callback(fixture, two_segment_tokens())

		helpers.assert_eq(#fixture.pasted_values, 1)
		helpers.assert_eq(fixture.pasted_values[1], ("A"):rep(60))
	end)

	helpers.it("writes the second segment only after the settle timer fires", function()
		local fixture = load_fixture()
		local results = emit_in_callback(fixture, two_segment_tokens())
		helpers.assert_eq(#fixture.pasted_values, 1)

		local gap = results[4] / 2
		helpers.assert_eq(fire_existing_delay(fixture.hs, gap), 2,
			"the intervening key and second paste must share the first settle deadline")
		helpers.assert_eq(#fixture.pasted_values, 2)
		helpers.assert_eq(fixture.pasted_values[2], ("B"):rep(60))
	end)

	helpers.it("keeps inline and deferred batches in one ordered generation", function()
		local fixture = load_fixture()
		local results, _, inline_events = emit_in_callback(fixture, two_segment_tokens())
		helpers.assert_eq(#inline_events, 2,
			"only the first Cmd+V pair belongs to the immediate callback handoff")
		local first = metadata(fixture, inline_events[1])

		local gap = results[4] / 2
		fire_existing_delay(fixture.hs, gap)
		helpers.assert_eq(fixture.synthetic.stats().pending, 2,
			"the deferred key and paste must wait in the centralized FIFO")
		local fence = fixture.synthetic.claim_physical_fence()
		helpers.assert_not_nil(fence)
		helpers.assert_eq(#fence.events, 4)
		local middle = metadata(fixture, fence.events[1])
		local last = metadata(fixture, fence.events[3])

		helpers.assert_eq(first.owner, "test.multi_paste")
		helpers.assert_eq(first.effect, "replacement")
		helpers.assert_eq(first.generation, middle.generation)
		helpers.assert_eq(first.generation, last.generation)
		helpers.assert_eq(first.ordinal, 1)
		helpers.assert_eq(middle.ordinal, 2)
		helpers.assert_eq(last.ordinal, 3)
		helpers.assert_eq(fence.events[1].key, "return")
		helpers.assert_eq(fence.events[3].key, "v")
	end)

	helpers.it("returns the complete logical size before deferred delivery", function()
		local fixture = load_fixture()
		local results = emit_in_callback(fixture, two_segment_tokens())
		helpers.assert_eq(results[1], 121)
		helpers.assert_eq(results[2], "\r")
		helpers.assert_eq(results[3], ("A"):rep(60) .. "\r" .. ("B"):rep(60))
		helpers.assert_true(results[4] > 0)
	end)

	helpers.it("keeps a single paste in the callback batch without deferred payload", function()
		local fixture = load_fixture()
		local _, _, events = emit_in_callback(fixture, {
			{ kind = "text", value = ("C"):rep(60) },
		})

		helpers.assert_eq(#fixture.pasted_values, 1)
		helpers.assert_eq(#events, 2)
		helpers.assert_eq(events[1].key, "v")
		helpers.assert_eq(fixture.synthetic.stats().pending, 0)
	end)
end)
