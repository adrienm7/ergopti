--- tests/unit/platform/remap/guardian_recovery/test_bulk_edit_without_guardian.lua

--- ==============================================================================
--- MODULE: Bulk Edits While The Remap Guardian Is Not Ready
--- DESCRIPTION:
--- A bulk settings edit queued its regeneration behind the guardian readiness
--- wait, which polls without a deadline while the helper is unapproved or
--- unregistered. Its terminal never fired, so the transaction stayed pinned for
--- the whole session: every later bulk command, setter, disable and the
--- controlled reload were refused. The edit is saved and deploys once the
--- guardian is ready, from the settings persisted at that moment.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local count_logs = fixture.count_logs
local has_log = fixture.has_log
local with_remap = fixture.with_remap

-- Every public bulk entry point the menus reach.
local ENTRY_POINTS = {
	{
		id = "reset_to_defaults",
		run = function(remap, on_done) return remap.reset_to_defaults(on_done) end,
	},
	{
		id = "reset_tap_holds_to_defaults",
		run = function(remap, on_done) return remap.reset_tap_holds_to_defaults(on_done) end,
	},
	{
		id = "apply_scope",
		run = function(remap, on_done)
			return remap.apply_scope({
				scope = "tap_holds",
				mode = "recommended",
				backup_path = "tests/unit/platform/remap/no-guardian-scope.bak",
			}, on_done)
		end,
	},
}

--- Runs one bulk entry point and records its terminals.
--- @param entry table One ENTRY_POINTS row.
--- @param remap table Real platform.remap module.
--- @return boolean accepted
--- @return table results Recorded { ok, reason } pairs.
local function run_entry(entry, remap)
	local results = {}
	local accepted = entry.run(remap, function(ok, reason)
		results[#results + 1] = { ok = ok, reason = reason }
	end)
	return accepted, results
end

--- Boots the bundled regeneration the way init.lua does at boot completion.
--- @param remap table Real platform.remap module.
--- @return table results Recorded boot terminals.
local function boot_regeneration(remap)
	local results = {}
	helpers.assert_true(remap.regenerate(function(ok, reason)
		results[#results + 1] = { ok = ok, reason = reason }
	end), "the boot regeneration must be retained behind the guardian")
	return results
end

--- Asserts one bulk terminal settled as saved for a later deploy.
--- @param results table Recorded terminals.
--- @param status string Guardian status the edit waits on.
--- @param label string Diagnostic label.
local function assert_saved_for_later(results, status, label)
	helpers.assert_eq(#results, 1, label .. " must settle exactly once")
	helpers.assert_true(results[1].ok == true, label .. " must settle as saved: "
		.. tostring(results[1].reason))
	helpers.assert_eq(results[1].reason, "persisted-guardian-" .. status)
end

helpers.describe("Karabiner bulk edits while the guardian is not ready", function()
	for _, status in ipairs({ "unavailable", "requires_approval" }) do
		for _, entry in ipairs(ENTRY_POINTS) do
			helpers.it(entry.id .. " settles as saved while the guardian is " .. status
				.. " (guardian-bulk-settle)", function()
				with_remap({
					initial_phase = "idle",
					guardian_status = status,
					guardian_probe_default_status = status,
				}, function(remap, calls)
					boot_regeneration(remap)
					helpers.assert_eq(calls.builds, 0)

					local accepted, results = run_entry(entry, remap)
					helpers.assert_true(accepted == true, entry.id .. " must be accepted")
					assert_saved_for_later(results, status, entry.id)
					helpers.assert_true(remap.settings_pending() == false,
						"a saved edit must not pin the bulk owner")

					calls.recovery_timers[#calls.recovery_timers]:fire()
					helpers.assert_eq(calls.builds, 0, "nothing deploys before the guardian is ready")
					helpers.assert_eq(#results, 1, "the poll must not settle the edit twice")

					local _, second = run_entry(entry, remap)
					assert_saved_for_later(second, status, "the second " .. entry.id)
					helpers.assert_true(remap.set_tap_action("left_shift", "none") == true,
						"a setter must be admitted after a saved bulk edit")
					helpers.assert_true(not has_log(calls,
						"refused while another bulk settings transaction"),
						"no bulk command may be refused as busy")

					calls.guardian_probe_statuses[#calls.guardian_probe_statuses + 1] = "ready"
					calls.recovery_timers[#calls.recovery_timers]:fire()
					helpers.assert_eq(calls.builds, 1,
						"approval must deploy the saved settings exactly once")
					helpers.assert_eq(count_logs(calls, "warn", "duplicate"), 0,
						"a saved edit must not see its terminal twice")
				end)
			end)
		end

		helpers.it("settles a bulk edit on the first non-ready probe while the guardian is "
			.. status .. " (guardian-bulk-settle)", function()
			with_remap({
				initial_phase = "idle",
				guardian_status = status,
				guardian_probe_default_status = status,
				guardian_probe_deferred = true,
			}, function(remap, calls)
				boot_regeneration(remap)
				local accepted, results = run_entry(ENTRY_POINTS[1], remap)
				helpers.assert_true(accepted == true)
				helpers.assert_eq(#results, 0, "the edit waits for the first guardian answer")

				calls.deliver_guardian_probe(status, nil, 1)
				assert_saved_for_later(results, status, "reset_to_defaults")
				helpers.assert_true(remap.settings_pending() == false)
				helpers.assert_eq(calls.builds, 0)
			end)
		end)

		helpers.it("keeps disable and the controlled reload available after a saved edit ("
			.. status .. ") (guardian-bulk-settle)", function()
			with_remap({
				initial_phase = "idle",
				guardian_status = status,
				guardian_probe_default_status = status,
			}, function(remap, calls)
				boot_regeneration(remap)
				local _, results = run_entry(ENTRY_POINTS[1], remap)
				assert_saved_for_later(results, status, "reset_to_defaults")

				local revoke_results = {}
				helpers.assert_true(remap.revoke("hammerspoon_reload", function(ok, reason)
					revoke_results[#revoke_results + 1] = { ok = ok, reason = reason }
				end) == true, "the controlled reload must not be aborted")
				helpers.assert_eq(#revoke_results, 1)
				helpers.assert_true(revoke_results[1].ok == true, tostring(revoke_results[1].reason))
				helpers.assert_true(not has_log(calls, "bulk phase"),
					"no lifecycle boundary may wait on the saved edit")
				helpers.assert_true(remap.teardown_local() == true)
				helpers.assert_eq(#results, 1, "teardown must not settle the saved edit again")
				helpers.assert_eq(calls.builds, 0)
			end)
		end)
	end

	helpers.it("still deploys a bulk edit synchronously when the guardian is ready", function()
		with_remap({
			initial_phase = "idle",
			guardian_status = "ready",
		}, function(remap, calls)
			local accepted, results = run_entry(ENTRY_POINTS[1], remap)
			helpers.assert_true(accepted == true)
			helpers.assert_eq(calls.builds, 1)
			helpers.assert_eq(#results, 0, "a ready guardian keeps the exact deploy terminal")
			helpers.assert_true(remap.settings_pending() == true)
			calls.deliver_ready()
			calls.deliver_resumed()
			helpers.assert_eq(#results, 1)
			helpers.assert_true(results[1].ok == true)
			helpers.assert_true(remap.settings_pending() == false)
		end)
	end)
end)
