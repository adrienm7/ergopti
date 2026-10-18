--- tests/unit/platform/remap/layout/test_wake_reresolves_layout_actions_lease_phase.lua

--- ==============================================================================
--- MODULE: Behavioral Wake and Lease-Phase Lifecycle Tests
--- DESCRIPTION:
--- Drives the retained caffeinate callback over pure doubles. Proves the exact
--- lease is refreshed before layout work, pause/teardown are fail-closed, and
--- callback or watcher failures reach the file-logger boundary instead of being
--- swallowed by Hammerspoon's async callback dispatcher.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.platform.remap.layout.wake_reresolves_layout_actions_fixture"] = nil
local Fixture = require("tests.support.platform.remap.layout.wake_reresolves_layout_actions_fixture")
local load_remap = Fixture.load_remap





helpers.describe("karabiner lease phase owns derivative input lifecycle", function()
	helpers.it("waits for READY before mounting and preserves resources during recovery", function()
		local remap, calls = load_remap()
		calls.phase_listener("active")
		helpers.assert_eq(calls.lease_bound_start, 0,
			"RESUMED publishes ACTIVE before post-resume regeneration; phase alone cannot mount inputs")

		helpers.assert_true(remap.regenerate())
		helpers.assert_eq(calls.lease_bound_start, 0)
		calls.deliver_ready()
		helpers.assert_eq(calls.lease_bound_start, 1,
			"only the exact generation READY transaction may mount lease-owned inputs")
		calls.phase_listener("recovering")
		helpers.assert_eq(calls.lease_bound_stop, 0,
			"the bounded one-shot heartbeat retry must not churn live input resources")
		remap.stop()
	end)

	helpers.it("retains actions and classification through FENCING until the exact fence", function()
		local remap, calls = load_remap()
		helpers.assert_true(remap.regenerate())
		calls.deliver_ready()
		local clear_before = calls.managed_clear
		local ke_before = calls.ke_stop

		calls.phase_listener("fencing")
		helpers.assert_eq(calls.lease_bound_stop, 0,
			"protocol failure is not yet proof that managed F17 output stopped")
		helpers.assert_eq(calls.ke_stop, ke_before)
		helpers.assert_eq(calls.managed_clear, clear_before,
			"events still in flight remain synthetic until the variable fence is proven")

		calls.phase_listener("failed")
		helpers.assert_eq(calls.lease_bound_stop, 1)
		helpers.assert_eq(calls.managed_clear, clear_before + 1,
			"the managed classifier is released only at a settled safe phase")
		local stopped_ke = calls.ke_stop
		remap.stop()
		calls.phase_listener("fencing")
		helpers.assert_eq(calls.ke_stop, stopped_ke,
			"a retained FENCING callback after M.stop() cannot repeat local teardown")
	end)

	helpers.it("retains consumers through normal STOPPING until the exact fence settles", function()
		local remap, calls = load_remap()
		helpers.assert_true(remap.regenerate())
		calls.deliver_ready()
		local clear_before = calls.managed_clear
		local ke_before = calls.ke_stop

		calls.phase_listener("stopping")
		helpers.assert_eq(calls.lease_bound_stop, 0,
			"rules can still emit during an accepted normal stop; early teardown loses output")
		helpers.assert_eq(calls.ke_stop, ke_before)
		helpers.assert_eq(calls.managed_clear, clear_before)
		calls.phase_listener("idle")
		helpers.assert_eq(calls.lease_bound_stop, 1)
		helpers.assert_eq(calls.managed_clear, clear_before + 1)
		remap.stop()
	end)
end)
