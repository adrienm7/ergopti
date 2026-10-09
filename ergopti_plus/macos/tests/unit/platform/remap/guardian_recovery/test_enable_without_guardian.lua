--- tests/unit/platform/remap/guardian_recovery/test_enable_without_guardian.lua

--- ==============================================================================
--- MODULE: Enabling The Remap While The Guardian Is Not Ready
--- DESCRIPTION:
--- Turning « Ergopti uses Karabiner » on queued the enable regeneration behind
--- the guardian readiness wait, which polls without a deadline while the helper
--- is unapproved or unregistered. The enable transaction never settled: the
--- switch stayed off yet could not be turned off again, every Tap-Hold edit and
--- setter was refused as an enabled-state transition, and the guardian status
--- row stayed hidden. The switch is now saved on at the first non-ready answer,
--- and its rules deploy once the guardian is ready.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local count_logs = fixture.count_logs
local with_remap = fixture.with_remap

--- Turns the integration on and records its terminals.
--- @param remap table Real platform.remap module.
--- @return boolean accepted
--- @return table results Recorded { ok, reason } pairs.
local function enable(remap)
	local results = {}
	local accepted = remap.set_enabled(true, function(ok, reason)
		results[#results + 1] = { ok = ok, reason = reason }
	end)
	return accepted, results
end

helpers.describe("Karabiner enable while the guardian is not ready", function()
	for _, status in ipairs({ "unavailable", "requires_approval" }) do
		helpers.it("saves the switch on while the guardian is " .. status
			.. " (guardian-enable-settle)", function()
			with_remap({
				enabled = false,
				initial_phase = "idle",
				guardian_status = status,
				guardian_probe_default_status = status,
			}, function(remap, calls)
				local saves_before = calls.saves
				local accepted, results = enable(remap)
				helpers.assert_true(accepted == true, "the enable must be accepted")
				helpers.assert_eq(#results, 1, "the enable must settle on the first answer")
				helpers.assert_true(results[1].ok == true, tostring(results[1].reason))
				helpers.assert_eq(results[1].reason, "persisted-guardian-" .. status)
				helpers.assert_true(remap.get_enabled() == true, "the switch must read on")
				helpers.assert_eq(calls.saves, saves_before + 1, "enabled=true is persisted")
				helpers.assert_eq(remap.guardian_state(), status,
					"the status row must see why nothing applies")
				helpers.assert_eq(calls.builds, 0, "nothing deploys before the guardian is ready")

				local bulk = {}
				helpers.assert_true(remap.reset_to_defaults(function(ok, reason)
					bulk[#bulk + 1] = { ok = ok, reason = reason }
				end) == true, "a bulk edit must be admitted after the enable")
				helpers.assert_eq(#bulk, 1)
				helpers.assert_eq(bulk[1].reason, "persisted-guardian-" .. status)
				helpers.assert_true(remap.set_tap_action("left_shift", "none") == true,
					"a setter must be admitted after the enable")

				calls.recovery_timers[#calls.recovery_timers]:fire()
				helpers.assert_eq(calls.builds, 0, "a non-ready poll deploys nothing")
				helpers.assert_eq(#results, 1, "the poll must not settle the enable twice")

				calls.guardian_probe_statuses[#calls.guardian_probe_statuses + 1] = "ready"
				calls.recovery_timers[#calls.recovery_timers]:fire()
				helpers.assert_eq(calls.builds, 1, "readiness must deploy the saved switch once")
				helpers.assert_eq(calls.starts_paused, 1, "readiness provisions the lease")
				calls.deliver_ready()
				calls.deliver_resumed()
				helpers.assert_eq(calls.phase, "active")
				helpers.assert_eq(#results, 1, "readiness must not settle the enable again")
				helpers.assert_eq(count_logs(calls, "error", "enable"), 0,
					"the saved enable must never run the failed-enable path")
			end)
		end)

		helpers.it("lets the saved switch be turned off again (" .. status
			.. ") (guardian-enable-settle)", function()
			with_remap({
				enabled = false,
				initial_phase = "idle",
				guardian_status = status,
				guardian_probe_default_status = status,
			}, function(remap, calls)
				enable(remap)
				local disabled = {}
				helpers.assert_true(remap.set_enabled(false, function(ok, reason)
					disabled[#disabled + 1] = { ok = ok, reason = reason }
				end) == true, "turning the switch off must be accepted")
				helpers.assert_eq(#disabled, 1)
				helpers.assert_true(disabled[1].ok == true, tostring(disabled[1].reason))
				helpers.assert_true(remap.get_enabled() == false)

				local probes = calls.guardian_probe_count
				helpers.assert_eq(#calls.recovery_timers, 1)
				helpers.assert_true(calls.recovery_timers[1]:fire() == false,
					"turning it off cancels the readiness poll")
				helpers.assert_eq(calls.guardian_probe_count, probes)
				helpers.assert_eq(calls.builds, 0)
			end)
		end)
	end

	helpers.it("settles the enable on the first answer, not before (guardian-enable-settle)", function()
		with_remap({
			enabled = false,
			initial_phase = "idle",
			guardian_status = "requires_approval",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			local _, results = enable(remap)
			helpers.assert_eq(#results, 0, "the enable waits for the first guardian answer")
			helpers.assert_true(remap.get_enabled() == false)

			calls.deliver_guardian_probe("requires_approval", nil, 1)
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1].reason, "persisted-guardian-requires_approval")
			helpers.assert_true(remap.get_enabled() == true)
			helpers.assert_eq(calls.builds, 0)
		end)
	end)

	helpers.it("reports an enable whose switch cannot be saved as failed", function()
		with_remap({
			enabled = false,
			initial_phase = "idle",
			guardian_status = "requires_approval",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			local _, results = enable(remap)
			local config = package.loaded["platform.remap.config"]
			local original = config.save_user_config
			config.save_user_config = function() return false end
			calls.deliver_guardian_probe("requires_approval", nil, 1)
			config.save_user_config = original
			helpers.assert_eq(#results, 1)
			helpers.assert_true(results[1].ok == false)
			helpers.assert_true(remap.get_enabled() == false)
			helpers.assert_eq(#calls.recovery_timers, 1)
			helpers.assert_true(calls.recovery_timers[1]:fire() == false,
				"a wait left with nothing to deploy must not keep polling")
		end)
	end)
end)
