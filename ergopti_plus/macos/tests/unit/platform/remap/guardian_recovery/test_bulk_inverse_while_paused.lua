--- tests/unit/platform/remap/guardian_recovery/test_bulk_inverse_while_paused.lua

--- ==============================================================================
--- MODULE: Bulk Inverses Refused By A Paused Script
--- DESCRIPTION:
--- A bulk candidate that failed after its deploy (its lease start was lost
--- while a pause was pending) persisted its inverse, then asked for an inverse
--- redeploy. Once the pause committed, every retry of that redeploy was refused
--- with script-paused: the transaction stayed in 'rollback-regeneration' for
--- the whole pause, every bulk command was busy, setters were refused and the
--- controlled reload aborted. Resume rebuilds from the persisted settings, so
--- a paused refusal now leaves the inverse saved until then.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local has_log = fixture.has_log
local with_remap = fixture.with_remap

--- Runs one reset-to-defaults and records its terminals.
--- @param remap table Real platform.remap module.
--- @return boolean accepted
--- @return table results Recorded { ok, reason } pairs.
local function reset(remap)
	local results = {}
	local accepted = remap.reset_to_defaults(function(ok, reason)
		results[#results + 1] = { ok = ok, reason = reason }
	end)
	return accepted, results
end

--- Deploys a reset, pauses while its lease start is pending, then loses that
--- start: the inverse is persisted but its redeploy is refused.
--- @param remap table Real platform.remap module.
--- @param calls table Fixture ledger.
--- @return table results Recorded reset terminals.
local function fail_reset_while_pausing(remap, calls)
	local _, results = reset(remap)
	helpers.assert_eq(calls.builds, 1, "the candidate deploys")
	helpers.assert_true(remap.pause(function() end) == true)
	helpers.assert_true(calls.pause_intent_pending == true, "the pause waits on the lease start")
	calls.fail_start("worker-lost")
	helpers.assert_eq(#results, 1)
	helpers.assert_true(results[1].ok == false)
	helpers.assert_eq(results[1].reason, "worker-lost")
	helpers.assert_eq(remap.get_tap_action("left_shift"), "none", "the inverse is persisted")
	-- script_control commits the pause once the lease settled.
	calls.script_paused = true
	return results
end

helpers.describe("Karabiner bulk inverses refused by a paused script", function()
	helpers.it("lets the controlled reload run during the pause (bulk-inverse-paused)", function()
		with_remap({ initial_phase = "idle" }, function(remap, calls)
			local results = fail_reset_while_pausing(remap, calls)
			local revoked = {}
			helpers.assert_true(remap.revoke("hammerspoon_reload", function(ok, reason)
				revoked[#revoked + 1] = { ok = ok, reason = reason }
			end) == true, "the controlled reload must not be aborted")
			helpers.assert_true(revoked[1] and revoked[1].ok == true)
			helpers.assert_true(remap.settings_pending() == false)
			helpers.assert_eq(#results, 1, "the failed reset must not settle twice")
			helpers.assert_true(has_log(calls, "inverse persisted; it deploys when the script resumes"))
		end)
	end)

	helpers.it("admits the next bulk command and setter during the pause (bulk-inverse-paused)", function()
		with_remap({ initial_phase = "idle" }, function(remap, calls)
			fail_reset_while_pausing(remap, calls)
			local _, second = reset(remap)
			helpers.assert_eq(#second, 1)
			helpers.assert_true(second[1].reason ~= "bulk-settings-busy",
				"the next bulk command must be admitted: " .. tostring(second[1].reason))
			helpers.assert_true(remap.set_tap_action("left_shift", "escape") == true,
				"a setter must be admitted during the pause")
			helpers.assert_true(not has_log(calls, "refused while another bulk settings transaction"))
		end)
	end)

	helpers.it("deploys the restored settings on Resume (bulk-inverse-paused)", function()
		with_remap({ initial_phase = "idle" }, function(remap, calls)
			fail_reset_while_pausing(remap, calls)
			helpers.assert_true(remap.retry_settings_recovery() == true)
			calls.script_paused = false
			calls.pause_intent_pending = false
			local builds = calls.builds
			helpers.assert_true(remap.resume(function() end) == true)
			helpers.assert_eq(calls.builds, builds + 1, "Resume rebuilds from the restored settings")
			helpers.assert_eq(remap.get_tap_action("left_shift"), "none")
		end)
	end)
end)
