--- tests/unit/platform/remap/guardian_recovery/test_driver_owned_registration.lua

--- ==============================================================================
--- MODULE: Guardian Registration Follows The Karabiner Switch
--- DESCRIPTION:
--- The launcher no longer registers the remap guardian at startup. The remap
--- owner registers it itself, on the first native guardian observation of a
--- lifecycle, which it only reaches after reading « Ergopti uses Karabiner » =
--- on. Later observations only probe. An off switch never registers anything.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local with_remap = fixture.with_remap

helpers.describe("guardian registration is owned by the switch-aware remap owner", function()
	helpers.it("registers on the first preflight of an enabled lifecycle, then only probes", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "not_requested",
			guardian_registration_due = true,
		}, function(remap, calls)
			helpers.assert_true(remap.regenerate(function() end))
			helpers.assert_eq(calls.guardian_registrations, 1,
				"the first observation must register the bundle's own guardian")
			helpers.assert_eq(calls.guardian_probes[1].kind, "register")
			helpers.assert_eq(#calls.build_tokens, 1, "a ready registration admits the build")

			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_true(remap.regenerate(function() end))
			helpers.assert_eq(calls.guardian_registrations, 1,
				"a settled registration is never repeated in the same lifecycle")
			helpers.assert_eq(calls.guardian_probes[#calls.guardian_probes].kind, "probe")
		end)
	end)

	helpers.it("gives a slow registration its own bounded timeout", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "not_requested",
			guardian_registration_due = true,
			guardian_probe_deferred = true,
		}, function(remap, calls)
			helpers.assert_true(remap.regenerate(function() end))
			helpers.assert_eq(calls.guardian_registrations, 1)
			local timeout = calls.recovery_timers[#calls.recovery_timers]
			helpers.assert_true(type(timeout) == "table" and timeout.delay > 2.0,
				"registration may run several bounded launchctl steps: "
					.. tostring(timeout and timeout.delay))
		end)
	end)

	helpers.it("never registers while Ergopti does not use Karabiner", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "not_requested",
			guardian_registration_due = true,
			enabled = false,
		}, function(remap, calls)
			helpers.assert_eq(remap.get_enabled(), false)
			local result, reason = nil, nil
			remap.regenerate(function(ok, detail) result, reason = ok, detail end)
			helpers.assert_eq(result, false)
			helpers.assert_eq(reason, "integration-disabled")
			helpers.assert_eq(calls.guardian_registrations, 0,
				"the switch is read before any guardian registration")
			helpers.assert_eq(calls.guardian_probe_count, 0)
			helpers.assert_eq(#calls.build_tokens, 0)
		end)
	end)

	helpers.it("reports the guardian state for diagnostics without observing anything", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "not_requested",
			guardian_registration_due = true,
			guardian_probe_deferred = true,
		}, function(remap, calls)
			helpers.assert_eq(remap.guardian_state(), "unknown",
				"nothing was observed yet in this lifecycle")
			helpers.assert_true(remap.regenerate(function() end))
			calls.deliver_guardian_probe("unavailable", nil, 1)
			local probes_before = calls.guardian_probe_count
			helpers.assert_eq(remap.guardian_state(), "unavailable")
			helpers.assert_eq(calls.guardian_probe_count, probes_before,
				"reading the state must not start an observation by itself")
			calls.recovery_timers[#calls.recovery_timers]:fire()
			calls.deliver_guardian_probe("requires_approval", nil)
			helpers.assert_eq(remap.guardian_state(), "requires_approval")
		end)
	end)

	helpers.it("reports « not used » while Ergopti does not use Karabiner", function()
		with_remap({ initial_phase = "idle", guardian_status = "ready", enabled = false }, function(remap, calls)
			calls.guardian_cached_status = "ready"
			helpers.assert_eq(remap.guardian_state(), "not_used",
				"a guardian registered by an earlier session is not this session's concern")
			helpers.assert_eq(calls.guardian_probe_count, 0)
		end)
	end)

	helpers.it("registers when the switch is turned on during the session", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "not_requested",
			guardian_registration_due = true,
			enabled = false,
		}, function(remap, calls)
			helpers.assert_true(remap.set_enabled(true, function() end))
			helpers.assert_eq(calls.guardian_registrations, 1,
				"turning the switch on is what makes the registration due")
		end)
	end)
end)
