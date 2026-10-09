--- tests/unit/platform/remap/guardian_recovery/test_bulk_edit_before_guardian_answer.lua

--- ==============================================================================
--- MODULE: Bulk Edits Still Waiting On The Guardian's First Answer
--- DESCRIPTION:
--- A bulk edit is released as saved on the guardian's first non-ready answer.
--- Before that answer (a boot registration takes up to 25 s), a controlled
--- reload was refused behind it, and a pause cancelled its retained context as
--- a failure: the saved edit was reverted with error notices, and the inverse
--- queued a fresh guardian wait during the pause that pinned the rollback
--- until Resume. The edit built nothing yet, so these boundaries now save it.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local has_log = fixture.has_log
local with_remap = fixture.with_remap

--- Boots the bundled regeneration and records one reset still waiting on the
--- guardian's first answer.
--- @param remap table Real platform.remap module.
--- @param calls table Fixture ledger.
--- @return table results Recorded reset terminals.
local function reset_before_first_answer(remap, calls)
	helpers.assert_true(remap.regenerate(function() end), "the boot regeneration is retained")
	local results = {}
	helpers.assert_true(remap.reset_to_defaults(function(ok, reason)
		results[#results + 1] = { ok = ok, reason = reason }
	end) == true, "the reset is accepted")
	helpers.assert_eq(#results, 0, "the reset waits for the guardian's first answer")
	helpers.assert_eq(calls.guardian_probe_count, 1)
	return results
end

--- Asserts the reset settled once as saved, its settings kept and never reverted.
--- @param remap table Real platform.remap module.
--- @param calls table Fixture ledger.
--- @param results table Recorded reset terminals.
--- @param reason string Expected saved terminal detail.
local function assert_saved(remap, calls, results, reason)
	helpers.assert_eq(#results, 1, "the reset must settle exactly once")
	helpers.assert_true(results[1].ok == true, tostring(results[1].reason))
	helpers.assert_eq(results[1].reason, reason)
	helpers.assert_true(remap.settings_pending() == false)
	helpers.assert_eq(remap.get_tap_action("left_shift"), "escape", "the saved edit is kept")
	helpers.assert_eq(calls.saves, 1, "no inverse is written")
	helpers.assert_true(not has_log(calls, "failed after settings commit"),
		"a saved edit must not be reverted")
end

helpers.describe("Karabiner bulk edits before the guardian's first answer", function()
	helpers.it("lets the controlled reload run and saves the edit for the next launch"
		.. " (guardian-bulk-before-answer)", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "requires_approval",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			local results = reset_before_first_answer(remap, calls)
			local revoked = {}
			helpers.assert_true(remap.revoke("hammerspoon_reload", function(ok, reason)
				revoked[#revoked + 1] = { ok = ok, reason = reason }
			end) == true, "the controlled reload must not be aborted")
			helpers.assert_eq(#revoked, 1)
			helpers.assert_true(revoked[1].ok == true, tostring(revoked[1].reason))
			assert_saved(remap, calls, results, "persisted-lifecycle-ending")
			helpers.assert_true(not has_log(calls, "bulk phase"))
			helpers.assert_true(remap.teardown_local() == true)
			helpers.assert_eq(calls.builds, 0)
		end)
	end)

	helpers.it("keeps the edit a pause cancels, without a new guardian wait"
		.. " (guardian-bulk-before-answer)", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "requires_approval",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			local results = reset_before_first_answer(remap, calls)
			local paused = {}
			helpers.assert_true(remap.pause(function(ok, reason)
				paused[#paused + 1] = { ok = ok, reason = reason }
			end) == true)
			calls.script_paused = true
			helpers.assert_true(paused[1] and paused[1].ok == true)
			assert_saved(remap, calls, results, "persisted-script-paused")
			helpers.assert_eq(calls.guardian_probe_count, 1,
				"the pause must not start another guardian observation")
			helpers.assert_eq(#calls.recovery_timers, 0, "nothing polls during the pause")

			calls.deliver_guardian_probe("ready", nil, 1)
			helpers.assert_eq(calls.builds, 0, "the cancelled wait must not deploy")
			local revoked = {}
			helpers.assert_true(remap.revoke("hammerspoon_reload", function(ok, reason)
				revoked[#revoked + 1] = { ok = ok, reason = reason }
			end) == true, "the controlled reload must run during the pause")
			helpers.assert_true(revoked[1] and revoked[1].ok == true)
		end)
	end)

	helpers.it("keeps the edit an explicit lease stop cancels (guardian-bulk-before-answer)", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "requires_approval",
			guardian_probe_deferred = true,
		}, function(remap, calls)
			local results = reset_before_first_answer(remap, calls)
			helpers.assert_true(remap.stop_lease(function() end) == true)
			assert_saved(remap, calls, results, "persisted-lease-stopped")
			helpers.assert_eq(calls.guardian_probe_count, 1)
		end)
	end)
end)
