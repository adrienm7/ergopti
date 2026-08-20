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

	helpers.it("restores the first snapshot when a later clipboard write is rejected", function()
		local fixture = load_fixture()
		local original = { ["public.utf8-plain-text"] = "ORIGINAL" }
		local current = original
		local payload_writes = 0
		fixture.hs.pasteboard.readAllData = function() return original end
		fixture.hs.pasteboard.writeAllData = function(saved)
			current = saved
			return true
		end
		fixture.hs.pasteboard.setContents = function(value)
			payload_writes = payload_writes + 1
			if payload_writes == 2 then return false end
			current = value
			return true
		end

		local results = emit_in_callback(fixture, two_segment_tokens())
		local gap = results[4] / 2
		fire_existing_delay(fixture.hs, gap)

		helpers.assert_true(current == original,
			"rejecting an overlapping payload must not cancel the first owner's restore")
	end)

	helpers.it("retains ownership and retries when the native restore is refused", function()
		local fixture = load_fixture()
		local original = { ["public.utf8-plain-text"] = "ORIGINAL" }
		local current = original
		local restore_attempts = 0
		fixture.hs.pasteboard.readAllData = function() return original end
		fixture.hs.pasteboard.setContents = function(value)
			current = value
			return true
		end
		fixture.hs.pasteboard.writeAllData = function(saved)
			restore_attempts = restore_attempts + 1
			if restore_attempts == 1 then return false end
			current = saved
			return true
		end

		emit_in_callback(fixture, {
			{ kind = "text", value = ("R"):rep(60) },
		})
		helpers.assert_eq(fire_existing_delay(fixture.hs, 0.15), 1)
		helpers.assert_eq(restore_attempts, 1)
		helpers.assert_eq(current, ("R"):rep(60),
			"a refused restore must keep ownership instead of pretending recovery succeeded")

		helpers.assert_eq(fire_existing_delay(fixture.hs, 0.15), 1,
			"a refused native restore must autonomously arm another retained attempt")
		helpers.assert_eq(restore_attempts, 2)
		helpers.assert_true(current == original,
			"the retained retry must restore the original all-type snapshot")
	end)

	helpers.it("acquires trailing ordering timers before the first visible paste", function()
		local fixture = load_fixture()
		fixture.hs.timer.new = function() return nil end

		fixture.synthetic.enter_callback()
		local transaction = fixture.synthetic.begin("test.preflight", "replacement")
		local ok = pcall(function()
			fixture.synthetic.with_transaction(transaction, function()
				fixture.utils.emit_tokens({
					{ kind = "text", value = ("P"):rep(60) },
					{ kind = "key", value = "return" },
				})
			end)
		end)
		if ok then fixture.synthetic.seal(transaction) else fixture.synthetic.cancel(transaction) end
		local consume, events = fixture.synthetic.leave_callback(ok)

		helpers.assert_true(not ok,
			"a refused trailing-order timer must reject the logical replacement")
		helpers.assert_eq(#fixture.pasted_values, 0,
			"all delayed capabilities must commit before the first clipboard mutation")
		helpers.assert_true(not consume)
		helpers.assert_nil(events,
			"preflight refusal must leave no partial synthetic batch to consume")
		helpers.assert_eq(fixture.synthetic.stats().pending, 0,
			"the failed preflight must release every retained transaction token")
	end)

	helpers.it("rolls back without Cmd+V when the restore timer is refused", function()
		local fixture = load_fixture()
		local original = { ["public.utf8-plain-text"] = "ORIGINAL" }
		local current = original
		fixture.hs.pasteboard.readAllData = function() return original end
		fixture.hs.pasteboard.setContents = function(value)
			current = value
			return true
		end
		fixture.hs.pasteboard.writeAllData = function(saved)
			current = saved
			return true
		end
		fixture.hs.timer.new = function() return nil end

		fixture.synthetic.enter_callback()
		local transaction = fixture.synthetic.begin("test.timer_refusal", "replacement")
		local ok = pcall(function()
			fixture.synthetic.with_transaction(transaction, function()
				fixture.utils.emit_text(("T"):rep(60))
			end)
		end)
		if ok then fixture.synthetic.seal(transaction) else fixture.synthetic.cancel(transaction) end
		local consume, events = fixture.synthetic.leave_callback(ok)

		helpers.assert_true(not ok,
			"timer allocation refusal must fail the logical replacement")
		helpers.assert_true(not consume)
		helpers.assert_nil(events,
			"Cmd+V must not be published unless exact clipboard restoration is armed")
		helpers.assert_true(current == original,
			"timer refusal must synchronously roll the clipboard back")
	end)

	helpers.it("rejects synchronous recovery dispatchers without recursive re-entry", function()
		local fixture = load_fixture()
		local original = { ["public.utf8-plain-text"] = "ORIGINAL" }
		local current = original
		local restore_attempts = 0
		local timer_calls = 0
		local defer_calls = 0
		fixture.hs.pasteboard.readAllData = function() return original end
		fixture.hs.pasteboard.setContents = function(value)
			current = value
			return true
		end
		fixture.hs.pasteboard.writeAllData = function()
			restore_attempts = restore_attempts + 1
			return false
		end
		fixture.hs.timer.new = function(_delay, callback)
			timer_calls = timer_calls + 1
			return {
				start = function(self)
					callback()
					return self
				end,
				stop = function(self) return self end,
			}
		end
		fixture.synthetic.defer_after_callback = function(_label, callback)
			defer_calls = defer_calls + 1
			callback()
			return true
		end

		fixture.synthetic.enter_callback()
		local transaction = fixture.synthetic.begin("test.sync_restore", "replacement")
		local ok = pcall(function()
			fixture.synthetic.with_transaction(transaction, function()
				fixture.utils.emit_text(("S"):rep(60))
			end)
		end)
		if ok then fixture.synthetic.seal(transaction) else fixture.synthetic.cancel(transaction) end
		local consume, events = fixture.synthetic.leave_callback(ok)

		helpers.assert_true(not ok,
			"a synchronous timer callback is allocation refusal, not a committed restore")
		helpers.assert_true(not consume)
		helpers.assert_nil(events, "Cmd+V must not escape a refused restore transaction")
		helpers.assert_eq(timer_calls, 2,
			"one initial arm and one bounded retry are allowed; recursion is not")
		helpers.assert_eq(defer_calls, 1,
			"the synchronous fallback must be rejected after one bounded attempt")
		helpers.assert_eq(restore_attempts, 1,
			"installer callbacks must not race the caller's single rollback attempt")
		helpers.assert_eq(current, ("S"):rep(60),
			"failed recovery retains ownership of the injected payload for a later retry")
	end)
end)
