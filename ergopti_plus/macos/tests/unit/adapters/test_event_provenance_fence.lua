--- tests/unit/adapters/test_event_provenance_fence.lua

--- ==============================================================================
--- MODULE: Event Provenance Physical Fence Regression Tests
--- DESCRIPTION:
--- Exercises the fenced provenance entry point against controlled Quartz reads,
--- ownership claims, physical ordering fences, and deferred diagnostics. These
--- are behavioral assertions: no source spelling can satisfy them vacuously.
--- ==============================================================================

local helpers = require("tests.helpers")

local USER_DATA_PROPERTY = 301
local SOURCE_PID_PROPERTY = 302
local CURRENT_PID         = 7001
local OWNED_TAG           = 9001


--- Builds a fresh provenance adapter with observable native boundaries.
--- @param options table|nil Fixture options.
--- @return table fixture
local function make_fixture(options)
	options = options or {}
	local fixture = {
		fence_calls   = 0,
		property_reads = 0,
		timer_calls   = 0,
		pending_timers = {},
		logs          = {},
	}

	local synthetic = {}
	function synthetic.claim_tag(tag)
		if tag ~= OWNED_TAG then return nil, false end
		return { owned = true, owner = "unit.event-provenance" }, false
	end
	function synthetic.claim_physical_fence()
		fixture.fence_calls = fixture.fence_calls + 1
		if options.fence_throws then error("physical fence exploded") end
		return { fence_index = fixture.fence_calls }
	end

	local logger = helpers.make_logger_stub()
	logger.error = function(log_name, format, ...)
		fixture.logs[#fixture.logs + 1] = {
			log_name = log_name,
			message = string.format(format, ...),
		}
	end

	local timer = {}
	function timer.doAfter(delay, callback)
		fixture.timer_calls = fixture.timer_calls + 1
		if options.first_timer_throws and fixture.timer_calls == 1 then
			error("diagnostic timer unavailable")
		end
		local entry = { delay = delay, callback = callback }
		fixture.pending_timers[#fixture.pending_timers + 1] = entry
		return { stop = function() end }
	end

	package.loaded["infra.logger"] = logger
	package.loaded["adapters.synthetic_input"] = synthetic
	package.loaded["adapters.event_provenance"] = nil
	fixture.provenance = helpers.load_with_stubs("adapters.event_provenance", {
		eventtap = {
			event = {
				properties = {
					eventSourceUserData      = USER_DATA_PROPERTY,
					eventSourceUnixProcessID = SOURCE_PID_PROPERTY,
				},
			},
		},
		processInfo = { processID = CURRENT_PID },
		timer = timer,
	})

	function fixture.event(tag, unreadable)
		return {
			getProperty = function(_self, property)
				fixture.property_reads = fixture.property_reads + 1
				if unreadable then error("Quartz property read exploded") end
				if property == USER_DATA_PROPERTY then return tag end
				if property == SOURCE_PID_PROPERTY then return CURRENT_PID end
				return nil
			end,
		}
	end

	function fixture.fire_next_timer()
		local entry = table.remove(fixture.pending_timers, 1)
		helpers.assert_not_nil(entry, "expected a deferred provenance diagnostic")
		entry.callback()
	end

	return fixture
end





-- ================================================
-- ================================================
-- ======= 1/ Classification Fence Contract =======
-- ================================================
-- ================================================

helpers.describe("event provenance: classify_with_fence ordering contract", function()
	helpers.it("returns an owned event without taking a physical fence", function()
		local fixture = make_fixture()
		local metadata, status, fence = fixture.provenance.classify_with_fence(
			fixture.event(OWNED_TAG), "keymap")

		helpers.assert_true(metadata and metadata.owned)
		helpers.assert_eq(status, fixture.provenance.STATUS_OWNED)
		helpers.assert_nil(fence)
		helpers.assert_eq(fixture.fence_calls, 0,
			"owned loopback must not overtake itself through the physical fence")
	end)

	helpers.it("takes exactly one physical fence for foreign and unreadable events", function()
		local fixture = make_fixture()

		local foreign, foreign_status, foreign_fence = fixture.provenance.classify_with_fence(
			fixture.event(0), "keylogger")
		helpers.assert_nil(foreign)
		helpers.assert_eq(foreign_status, fixture.provenance.STATUS_FOREIGN)
		helpers.assert_eq(foreign_fence.fence_index, 1)
		helpers.assert_eq(fixture.fence_calls, 1,
			"one foreign event must claim one and only one physical fence")

		local unreadable, unreadable_status, unreadable_fence = fixture.provenance.classify_with_fence(
			fixture.event(nil, true), "keylogger")
		helpers.assert_nil(unreadable)
		helpers.assert_eq(unreadable_status, fixture.provenance.STATUS_UNREADABLE)
		helpers.assert_eq(unreadable_fence.fence_index, 2)
		helpers.assert_eq(fixture.fence_calls, 2,
			"one unreadable event must add exactly one physical fence")
	end)

	helpers.it("contains a throwing physical fence and downgrades the result", function()
		local fixture = make_fixture({ fence_throws = true })
		local ok, metadata, status, fence = pcall(
			fixture.provenance.classify_with_fence,
			fixture.event(0), "script-control")

		helpers.assert_true(ok, "a fence failure must never escape an eventtap callback")
		helpers.assert_nil(metadata)
		helpers.assert_eq(status, fixture.provenance.STATUS_UNREADABLE)
		helpers.assert_nil(fence)
		helpers.assert_eq(fixture.fence_calls, 1)
	end)

	helpers.it("rejects invalid consumer IDs before reading Quartz or fencing", function()
		local fixture = make_fixture()
		local event = fixture.event(0)

		helpers.assert_throws(function()
			fixture.provenance.classify_with_fence(event, nil)
		end)
		for _, invalid in ipairs({ false, 0, {}, "" }) do
			helpers.assert_throws(function()
				fixture.provenance.classify_with_fence(event, invalid)
			end)
		end

		helpers.assert_eq(fixture.property_reads, 0,
			"the programmer contract must fail before any native property access")
		helpers.assert_eq(fixture.fence_calls, 0,
			"an invalid consumer must not mutate physical ordering state")
	end)

	helpers.it("retries a diagnostic after its first deferral throws", function()
		local fixture = make_fixture({ first_timer_throws = true })

		local first_ok = pcall(fixture.provenance.classify_with_fence,
			fixture.event(nil, true), "keymap")
		if not first_ok then
			error("diagnostic scheduling failure escaped the eventtap", 0)
		end
		helpers.assert_eq(fixture.timer_calls, 1)
		helpers.assert_eq(#fixture.pending_timers, 0,
			"the failed deferral must not leave a phantom timer handle")

		local second_ok = pcall(fixture.provenance.classify_with_fence,
			fixture.event(nil, true), "keymap")
		if not second_ok then error("diagnostic retry escaped the eventtap", 0) end
		helpers.assert_eq(fixture.timer_calls, 2,
			"a failed deferral must release its latch so the next failure can report")
		helpers.assert_eq(#fixture.pending_timers, 1)

		fixture.fire_next_timer()
		helpers.assert_eq(#fixture.logs, 1,
			"the recovered diagnostic path must eventually emit the deferred error")
		helpers.assert_contains(fixture.logs[1].message, "user-data")
	end)
end)
