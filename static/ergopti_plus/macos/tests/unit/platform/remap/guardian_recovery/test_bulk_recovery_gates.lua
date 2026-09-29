--- tests/unit/platform/remap/guardian_recovery/test_bulk_recovery_gates.lua

--- ==============================================================================
--- MODULE: Bulk Settings Recovery Gates
--- DESCRIPTION:
--- A bulk edit whose regeneration was refused before any deploy (script
--- paused, lease transition...) persisted its inverse, then asked for an
--- inverse redeploy that the same reason refused too: the transaction stayed
--- in 'rollback-regeneration' and refused every later edit. And when the gate's
--- own retry did settle a retained recovery, the gate still refused the click
--- and logged the stale phase.
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

--- Refuses the second remap settings save: a bulk edit's inverse, right after
--- its candidate was saved.
--- @return function restore Puts the fixture's save back.
local function refuse_inverse_save()
	local config = package.loaded["platform.remap.config"]
	local original = config.save_user_config
	local saves_seen = 0
	config.save_user_config = function(...)
		saves_seen = saves_seen + 1
		if saves_seen == 2 then return false end
		return original(...)
	end
	return function() config.save_user_config = original end
end

helpers.describe("Karabiner bulk settings recovery gates", function()
	helpers.it("settles a candidate refused while the script is paused without an inverse deploy"
		.. " (bulk-refused-before-deploy)", function()
		with_remap({ initial_phase = "idle", paused = true }, function(remap, calls)
			local accepted, results = reset(remap)
			helpers.assert_true(accepted == false, "a paused script refuses the regeneration")
			helpers.assert_eq(#results, 1)
			helpers.assert_true(results[1].ok == false)
			helpers.assert_true(remap.settings_pending() == false,
				"a candidate that never deployed leaves no inverse deploy owed")
			helpers.assert_eq(results[1].reason, "script-paused",
				"the caller must learn the real refusal reason")
			helpers.assert_eq(remap.get_tap_action("left_shift"), "none",
				"the prior settings are persisted again")
			helpers.assert_eq(calls.saves, 2, "the candidate, then its inverse")
			helpers.assert_eq(calls.builds, 0)
			helpers.assert_true(not has_log(calls, "inverse regeneration remains pending"))

			local _, second = reset(remap)
			helpers.assert_eq(#second, 1)
			helpers.assert_true(second[1].reason ~= "bulk-settings-busy",
				"the next bulk command must be admitted")
			helpers.assert_true(remap.set_tap_action("left_shift", "escape") == true)
			helpers.assert_true(not has_log(calls, "refused while another bulk settings transaction"))
		end)
	end)

	helpers.it("admits the click whose retry settles the retained recovery"
		.. " (bulk-gate-after-retry)", function()
		with_remap({ initial_phase = "idle", paused = true }, function(remap, calls)
			local restore = refuse_inverse_save()
			local _, retained = reset(remap)
			restore()
			helpers.assert_eq(#retained, 1)
			helpers.assert_true(retained[1].ok == false)
			helpers.assert_true(remap.settings_pending() == true,
				"a failed inverse save keeps the recovery owned")

			local _, admitted = reset(remap)
			helpers.assert_eq(#admitted, 1)
			helpers.assert_eq(admitted[1].reason, "script-paused",
				"the retry settled the recovery, so this click runs its own edit")
			helpers.assert_true(remap.settings_pending() == false)
			helpers.assert_true(has_log(calls,
				"continues: the retained 'rollback-persistence' recovery settled on retry"))
			helpers.assert_true(not has_log(calls, "refused while another bulk settings transaction"))
		end)
	end)

	helpers.it("admits a setter whose retry settles the retained recovery"
		.. " (bulk-gate-after-retry)", function()
		with_remap({ initial_phase = "idle", paused = true }, function(remap, calls)
			local restore = refuse_inverse_save()
			reset(remap)
			restore()
			helpers.assert_true(remap.settings_pending() == true)

			helpers.assert_true(remap.set_tap_action("left_shift", "escape") == true,
				"the setter's retry settled the recovery, so the setter commits")
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			helpers.assert_true(remap.settings_pending() == false)
			helpers.assert_true(not has_log(calls, "refused during bulk phase"))
		end)
	end)

	helpers.it("redeploys the prior settings once a later build deployed the refused candidate"
		.. " (bulk-retry-after-deploy)", function()
		with_remap({ initial_phase = "idle", paused = true }, function(remap, calls)
			local generator = package.loaded["platform.remap.generator"]
			local build = generator.build_karabiner_json
			local built_taps = {}
			generator.build_karabiner_json = function(state, ...)
				built_taps[#built_taps + 1] = state.tap_hold_config.left_shift
					and state.tap_hold_config.left_shift.tap or "none"
				return build(state, ...)
			end
			local restore = refuse_inverse_save()
			reset(remap)
			restore()
			helpers.assert_true(remap.settings_pending() == true)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape",
				"the refused candidate stays published while its inverse is unsaved")

			calls.script_paused = false
			helpers.assert_true(remap.resume(function() end) == true)
			helpers.assert_true(helpers.deep_equal(built_taps, { "escape" }),
				"Resume deploys the refused candidate: " .. helpers.inspect(built_taps))

			remap.retry_settings_recovery()
			helpers.assert_eq(remap.get_tap_action("left_shift"), "none")
			helpers.assert_true(helpers.deep_equal(built_taps, { "escape", "none" }),
				"the retry must redeploy the prior settings: " .. helpers.inspect(built_taps))
		end)
	end)

	helpers.it("still refuses while the retry leaves the recovery owned, naming its current phase",
		function()
			with_remap({ initial_phase = "idle", paused = true }, function(remap, calls)
				local config = package.loaded["platform.remap.config"]
				local original = config.save_user_config
				local saves_seen = 0
				config.save_user_config = function(...)
					saves_seen = saves_seen + 1
					if saves_seen >= 2 then return false end
					return original(...)
				end
				reset(remap)
				local _, refused = reset(remap)
				config.save_user_config = original
				helpers.assert_eq(#refused, 1)
				helpers.assert_eq(refused[1].reason, "bulk-settings-busy")
				helpers.assert_true(has_log(calls,
					"refused while another bulk settings transaction is 'rollback-persistence'"))
			end)
		end)
end)
