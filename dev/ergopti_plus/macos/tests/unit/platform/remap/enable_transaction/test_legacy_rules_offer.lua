--- tests/unit/platform/remap/enable_transaction/test_legacy_rules_offer.lua

--- ==============================================================================
--- MODULE: Legacy Karabiner Rules Offer
--- DESCRIPTION:
--- A deploy refused by rules an older ErgoptiPlus left in karabiner.json used
--- to end in an ERROR line only: the user had to find and remove them by hand.
--- The remap bridge now keeps the refused rules, offers their removal through
--- the dialog the boot registered (once per launch for one set of rules, from
--- the timer scheduler after the regeneration settled, never inside it), and
--- removes them on request before a normal regeneration.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

--- The merge's structured refusal for one set of rules.
--- @param descriptions table Rule descriptions, one per conflicting rule.
--- @return table refusal
local function refusal_of(descriptions)
	local conflicts = {}
	for index, description in ipairs(descriptions) do
		conflicts[index] = { profile_index = 1, rule_index = index, description = description }
	end
	return {
		kind = "legacy_conflicts",
		count = #descriptions,
		descriptions = descriptions,
		conflicts = conflicts,
	}
end

local LEGACY = refusal_of({ "CapsWord — toggle and deactivation", "Left Shift: Escape (tap) / Shift (hold)" })

--- A deploy that the merge refuses with the given legacy rules.
--- @param refusal table Structured refusal.
--- @return function deploy
local function refused_by(refusal)
	return function()
		return false, "merge failed: 2 ambiguous legacy ErgoptiPlus rules", 1, refusal
	end
end

--- Loads the bridge with a recording cleanup presenter. The generation is
--- PREPARED, as at boot: a refused deploy then needs no exact fence, and the
--- next regeneration reaches the deploy again.
--- @param fixture table Remap transaction fixture.
--- @return table remap
--- @return table calls
--- @return table offers { count, during_regeneration, regenerate(on_done) }
local function load_with_presenter(fixture)
	local remap, calls = fixture.load_enabled_remap()
	calls.lease_phase = "prepared"
	local offers = { count = 0, during_regeneration = 0, regenerating = false }
	helpers.assert_true(remap.set_legacy_cleanup_presenter(function()
		offers.count = offers.count + 1
		if offers.regenerating then offers.during_regeneration = offers.during_regeneration + 1 end
		return true
	end))
	function offers.regenerate(on_done)
		offers.regenerating = true
		local ok, accepted = pcall(remap.regenerate, on_done)
		offers.regenerating = false
		if not ok then error(accepted, 0) end
		return accepted
	end
	return remap, calls, offers
end

helpers.describe("a deploy refused by legacy Karabiner rules (karabiner-legacy-cleanup)", function()
	helpers.it("offers the removal once, from the timer, after the regeneration settled (karabiner-legacy-cleanup)",
		function()
			with_fixture(function(fixture)
				local remap, calls, offers = load_with_presenter(fixture)
				calls.deploy_override = refused_by(LEGACY)
				local timers = #calls.first_run_timers
				local settled_ok, settled_reason = nil, nil
				offers.regenerate(function(ok, reason) settled_ok, settled_reason = ok, reason end)
				helpers.assert_eq(calls.deploy, 1, "the reproduction must reach the deploy")
				helpers.assert_eq(settled_ok, false)
				helpers.assert_eq(settled_reason, "deploy-failed", "the regeneration fails as before")
				helpers.assert_eq(offers.count, 0, "no dialog runs inside the regeneration transaction")

				local pending = remap.legacy_rule_conflicts()
				helpers.assert_type(pending, "table", "the refused rules stay pending")
				helpers.assert_eq(pending.count, 2)
				helpers.assert_eq(pending.descriptions[1], "CapsWord — toggle and deactivation")

				helpers.assert_eq(#calls.first_run_timers, timers + 1, "the offer goes to the timer scheduler")
				helpers.assert_eq(calls.first_run_timers[#calls.first_run_timers].delay, 0)
				helpers.assert_true(calls.fire_first_run_timer())
				helpers.assert_eq(offers.count, 1, "the timer shows the dialog")
				helpers.assert_eq(offers.during_regeneration, 0)

				-- Every settings change regenerates: the same rules are not offered again.
				offers.regenerate()
				offers.regenerate()
				helpers.assert_eq(#calls.first_run_timers, timers + 1,
					"one offer per launch for one set of rules")
				helpers.assert_eq(offers.count, 1)
				helpers.assert_type(remap.legacy_rule_conflicts(), "table", "the menu row keeps the removal")

				-- Other rules are another question.
				calls.deploy_override = refused_by(refusal_of({ "Script control: physical rcmd + escape" }))
				offers.regenerate()
				helpers.assert_eq(#calls.first_run_timers, timers + 2)
				helpers.assert_true(calls.fire_first_run_timer())
				helpers.assert_eq(offers.count, 2)
			end)
		end)

	helpers.it("a deploy that succeeds clears the pending rules (karabiner-legacy-cleanup)", function()
		with_fixture(function(fixture)
			local remap, calls, offers = load_with_presenter(fixture)
			calls.deploy_override = refused_by(LEGACY)
			offers.regenerate()
			helpers.assert_type(remap.legacy_rule_conflicts(), "table")
			calls.deploy_override = nil
			offers.regenerate()
			helpers.assert_nil(remap.legacy_rule_conflicts(), "nothing blocks the deploy any more")
			helpers.assert_true(calls.fire_first_run_timer())
			helpers.assert_eq(offers.count, 0, "a resolved set is not offered")
		end)
	end)

	helpers.it("other deploy failures offer nothing (karabiner-legacy-cleanup)", function()
		with_fixture(function(fixture)
			local remap, calls, offers = load_with_presenter(fixture)
			local timers = #calls.first_run_timers
			calls.fail_deploy = true
			offers.regenerate()
			helpers.assert_eq(calls.deploy, 1)
			helpers.assert_nil(remap.legacy_rule_conflicts())
			helpers.assert_eq(#calls.first_run_timers, timers)
		end)
	end)

	helpers.it("confirming removes the rules with the refused merge's context, then regenerates (karabiner-legacy-cleanup)",
		function()
			with_fixture(function(fixture)
				local remap, calls, offers = load_with_presenter(fixture)
				calls.deploy_override = refused_by(LEGACY)
				offers.regenerate()
				calls.deploy_override = nil
				local deploys = calls.deploy

				local done_ok, done_result = nil, nil
				helpers.assert_true(remap.remove_legacy_rules(function(ok, result)
					done_ok, done_result = ok, result
				end))
				helpers.assert_eq(#calls.legacy_removals, 1)
				helpers.assert_true(rawequal(calls.legacy_removals[1].legacy_context, calls.legacy_context),
					"the removal classifies with the context the refused merge used")
				helpers.assert_type(calls.legacy_removals[1].path, "string")
				helpers.assert_eq(calls.deploy, deploys + 1, "a normal regeneration follows the removal")
				helpers.assert_nil(done_ok, "the outcome waits for the generation to become ready")
				calls.deliver_ready()
				calls.deliver_resumed()
				helpers.assert_eq(done_ok, true)
				helpers.assert_eq(done_result.stage, "regeneration")
				helpers.assert_eq(done_result.removed_count, 2)
				helpers.assert_eq(done_result.backup_path, "/backup/karabiner.json.bak")
				helpers.assert_nil(remap.legacy_rule_conflicts())
			end)
		end)

	helpers.it("a refused removal reports it and regenerates nothing (karabiner-legacy-cleanup)", function()
		with_fixture(function(fixture)
			local remap, calls, offers = load_with_presenter(fixture)
			calls.deploy_override = refused_by(LEGACY)
			offers.regenerate()
			calls.legacy_removal_result = { false, "karabiner.json publication refused: source changed", 0, nil }
			local deploys = calls.deploy
			local done_ok, done_result = nil, nil
			helpers.assert_eq(remap.remove_legacy_rules(function(ok, result)
				done_ok, done_result = ok, result
			end), false)
			helpers.assert_eq(done_ok, false)
			helpers.assert_eq(done_result.stage, "removal")
			helpers.assert_eq(done_result.reason, "karabiner.json publication refused: source changed")
			helpers.assert_eq(calls.deploy, deploys, "nothing is regenerated over a refused removal")
			helpers.assert_type(remap.legacy_rule_conflicts(), "table", "the rules stay pending")
		end)
	end)

	helpers.it("with nothing pending, the removal is refused and touches nothing (karabiner-legacy-cleanup)", function()
		with_fixture(function(fixture)
			local remap, calls = load_with_presenter(fixture)
			local done_ok, done_result = nil, nil
			helpers.assert_eq(remap.remove_legacy_rules(function(ok, result)
				done_ok, done_result = ok, result
			end), false)
			helpers.assert_eq(done_ok, false)
			helpers.assert_eq(done_result.reason, "no-legacy-rules-pending")
			helpers.assert_eq(#calls.legacy_removals, 0)
			helpers.assert_eq(calls.deploy, 0)
		end)
	end)

	helpers.it("registers one presenter and fails fast on a non-function (karabiner-legacy-cleanup)", function()
		with_fixture(function(fixture)
			local remap = load_with_presenter(fixture)
			helpers.assert_eq(remap.set_legacy_cleanup_presenter(function() return true end), false,
				"the first presenter is kept")
			helpers.assert_true(not pcall(remap.set_legacy_cleanup_presenter, "dialog"))
		end)
	end)
end)
