--- tests/unit/adapters/test_modifier_injector_atomic_handoff.lua

--- ==============================================================================
--- MODULE: Modifier Injector Atomic Policy Handoff Regression
--- DESCRIPTION:
--- Proves that a one-shot modifier changes the physical key and disarms only
--- after its post-eventtap policy callback has been scheduled successfully.
--- A dispatcher failure or native setFlags exception must leave the arm intact,
--- and a callback queued before a failed mutation must remain inert.
--- ==============================================================================

local helpers = require("tests.helpers")


-- ==============================================
-- ==============================================
-- ======= 1/ Isolated Adapter Fixture ===========
-- ==============================================
-- ==============================================

--- Loads the real adapter behind controlled eventtap and dependency boundaries.
--- @param schedule_ok boolean Result returned by defer_after_callback.
--- @return table fixture
local function make_fixture(schedule_ok)
	local tap_callback = nil
	local tap_stop_count = 0
	local deferred = {}

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.event_provenance"] = {
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function()
			return nil, "foreign", nil
		end,
	}
	package.loaded["adapters.synthetic_input"] = {
		defer_after_callback = function(_label, callback)
			if not schedule_ok then return false end
			deferred[#deferred + 1] = callback
			return true
		end,
	}

	local eventtap = {
		event = { types = { keyDown = 10 } },
		new = function(_types, callback)
			tap_callback = callback
			return {
				start = function(self) return self end,
				stop = function(self)
					tap_stop_count = tap_stop_count + 1
					return self
				end,
			}
		end,
	}

	local injector = helpers.load_with_stubs("adapters.modifier_injector", {
		eventtap = eventtap,
	})

	return {
		injector = injector,
		fire = function(event) return tap_callback(event) end,
		fire_deferred = function()
			for _, callback in ipairs(deferred) do callback() end
		end,
		deferred_count = function() return #deferred end,
		stop_count = function() return tap_stop_count end,
	}
end


--- Builds one mutable physical key event.
--- @param fail_set_flags boolean Whether setFlags raises.
--- @return table event
--- @return table observed
local function physical_key(fail_set_flags)
	local observed = { set_calls = 0, flags = {} }
	local event = {
		getFlags = function() return {} end,
		setFlags = function(_, flags)
			observed.set_calls = observed.set_calls + 1
			if fail_set_flags then error("native setFlags failure") end
			observed.flags = flags
		end,
	}
	return event, observed
end


-- =====================================================
-- =====================================================
-- ======= 2/ Atomic Scheduling and Mutation ============
-- =====================================================
-- =====================================================

helpers.describe("modifier injector: atomic post-eventtap policy handoff", function()
	helpers.it("keeps the key untouched and arm live when callback scheduling fails", function()
		local fixture = make_fixture(false)
		local applied = 0
		helpers.assert_true(fixture.injector.arm({ cmd = true }, function()
			applied = applied + 1
		end))
		local event, observed = physical_key(false)

		local consume = fixture.fire(event)

		helpers.assert_true(consume == false, "the original key must pass through")
		helpers.assert_eq(observed.set_calls, 0,
			"no flag may land when the policy callback cannot be scheduled")
		helpers.assert_true(fixture.injector.is_armed(),
			"the modifier must remain armed for the next physical key")
		helpers.assert_eq(fixture.stop_count(), 0,
			"the live tap must not be torn down on scheduling failure")
		helpers.assert_eq(applied, 0)
	end)

	helpers.it("keeps a pre-scheduled callback inert when setFlags throws", function()
		local fixture = make_fixture(true)
		local applied = 0
		helpers.assert_true(fixture.injector.arm({ shift = true }, function()
			applied = applied + 1
		end))
		local event, observed = physical_key(true)

		fixture.fire(event)
		helpers.assert_eq(observed.set_calls, 1,
			"the test must reach the failing native mutation")
		helpers.assert_true(fixture.injector.is_armed(),
			"a failed mutation must keep the one-shot modifier recoverable")
		helpers.assert_eq(fixture.stop_count(), 0)
		helpers.assert_true(fixture.deferred_count() >= 1,
			"the schedule-first path must have queued its guarded callback")

		fixture.fire_deferred()
		helpers.assert_eq(applied, 0,
			"a callback queued before an uncommitted mutation must do nothing")
	end)

	helpers.it("commits flags and disarm before the deferred callback runs", function()
		local fixture = make_fixture(true)
		local applied = 0
		helpers.assert_true(fixture.injector.arm({ ctrl = true }, function()
			applied = applied + 1
		end))
		local event, observed = physical_key(false)

		fixture.fire(event)
		helpers.assert_eq(observed.set_calls, 1)
		helpers.assert_true(observed.flags.ctrl == true,
			"the requested modifier must land on the physical event")
		helpers.assert_true(not fixture.injector.is_armed(),
			"the adapter must disarm after the event mutation succeeds")
		helpers.assert_eq(fixture.stop_count(), 1)
		helpers.assert_eq(applied, 0,
			"policy code must remain outside the eventtap callback")

		fixture.fire_deferred()
		helpers.assert_eq(applied, 1,
			"the committed policy callback must run exactly once")
	end)
end)
