--- tests/unit/platform/remap/guardian_recovery/test_resume_without_live_lease.lua

--- ==============================================================================
--- MODULE: Resume Without A Live Lease
--- DESCRIPTION:
--- Pause commits as already-fail-closed when no generation emits. Resume must be
--- just as reachable: it once waited forever on an unapproved helper, leaving
--- the script PAUSED with no way back from the shortcut or the tray.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local TOKENS = fixture.TOKENS
local with_remap = fixture.with_remap

--- Pauses through the real bridge and records every resume terminal.
--- @param remap table Real platform.remap module.
--- @param calls table Fixture observation table.
--- @return table resume_results Recorded { ok, reason } pairs.
local function pause_then_resume(remap, calls)
	local pause_results = {}
	helpers.assert_true(remap.pause(function(ok, reason)
		pause_results[#pause_results + 1] = { ok = ok, reason = reason }
	end))
	helpers.assert_eq(#pause_results, 1)
	helpers.assert_true(pause_results[1].ok == true)
	helpers.assert_eq(pause_results[1].reason, "already-fail-closed")
	calls.script_paused = true

	local resume_results = {}
	remap.resume(function(ok, reason)
		resume_results[#resume_results + 1] = { ok = ok, reason = reason }
	end)
	return resume_results
end

helpers.describe("Karabiner resume without a live lease", function()
	for _, start in ipairs({ "idle", "failed" }) do
		helpers.it("settles Resume while the helper awaits approval (from " .. start .. ")", function()
			local options = {
				guardian_status = "requires_approval",
				guardian_probe_default_status = "requires_approval",
			}
			if start == "idle" then options.initial_phase = "idle" end
			with_remap(options, function(remap, calls)
				if start == "failed" then calls.publish_failed(TOKENS[1]) end
				local resume_results = pause_then_resume(remap, calls)
				helpers.assert_eq(#resume_results, 1,
					"Resume must settle instead of waiting for helper approval")
				helpers.assert_true(resume_results[1].ok == true)
				helpers.assert_eq(resume_results[1].reason, "no-live-lease")
				helpers.assert_eq(calls.builds, 0,
					"nothing may deploy before the helper is approved")
				calls.script_paused = false

				calls.guardian_probe_statuses[#calls.guardian_probe_statuses + 1] = "ready"
				calls.recovery_timers[#calls.recovery_timers]:fire()
				helpers.assert_eq(calls.builds, 1,
					"approval must still provision the lease retained by Resume")
				helpers.assert_eq(#resume_results, 1, "Resume settles exactly once")
			end)
		end)
	end

	helpers.it("settles Resume when the lease cannot start", function()
		with_remap({ guardian_status = "ready", initial_phase = "idle" }, function(remap, calls)
			local resume_results = pause_then_resume(remap, calls)
			helpers.assert_eq(#resume_results, 0)
			calls.fail_start("worker-lost")
			helpers.assert_eq(#resume_results, 1)
			helpers.assert_true(resume_results[1].ok == true)
			helpers.assert_eq(resume_results[1].reason, "no-live-lease")
		end)
	end)

	helpers.it("still refuses a lease-less Resume superseded by a newer Pause", function()
		with_remap({
			guardian_status = "requires_approval",
			guardian_probe_default_status = "requires_approval",
			guardian_probe_deferred = true,
			initial_phase = "idle",
		}, function(remap, calls)
			calls.script_paused = true
			local resume_results = {}
			remap.resume(function(ok, reason)
				resume_results[#resume_results + 1] = { ok = ok, reason = reason }
			end)
			-- The probe has not answered yet, so Resume is still undecided; a newer
			-- Pause must cancel it rather than turn it into a lease-less success.
			helpers.assert_eq(#resume_results, 0)
			helpers.assert_true(remap.pause())
			helpers.assert_eq(#resume_results, 1)
			helpers.assert_true(resume_results[1].ok == false)
			helpers.assert_eq(resume_results[1].reason, "script-pause-requested")
		end)
	end)
end)
