--- tests/unit/platform/remap/enable_transaction/test_rule_removal.lua

--- ==============================================================================
--- MODULE: Karabiner Switch Rule Removal
--- DESCRIPTION:
--- « Ergopti uses Karabiner » off leaves no ErgoptiPlus rule in karabiner.json:
--- at boot the removal runs without any lease being prepared, and a disable
--- removes the rules only after the exact lease reported STOPPED and the
--- switch was persisted. « Remove Ergopti from Karabiner » reuses both paths.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("the Karabiner switch honoured at boot", function()
	helpers.it("removes Ergopti's rules without preparing any lease when off", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ initially_enabled = false })
			helpers.assert_eq(calls.init_result, true)
			helpers.assert_eq(remap.get_enabled(), false)
			helpers.assert_eq(calls.init_rule_removals, 1,
				"an off switch must clean karabiner.json at boot")
			helpers.assert_nil(calls.token_requests,
				"an off switch must not allocate a lease generation token")
			helpers.assert_eq(calls.start + calls.start_paused, 0)
			helpers.assert_eq(calls.lease_bound_starts, 0)
		end)
	end)

	helpers.it("leaves karabiner.json to the generator when on", function()
		with_fixture(function(fixture)
			local _, calls = fixture.load_enabled_remap()
			helpers.assert_eq(calls.init_result, true)
			helpers.assert_eq(calls.init_rule_removals, 0)
		end)
	end)
end)

helpers.describe("the Karabiner switch turned off", function()
	helpers.it("removes the rules only after STOPPED and the persisted off", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local result, reason = nil, nil
			helpers.assert_true(remap.set_enabled(false, function(ok, detail)
				result, reason = ok, detail
			end))
			helpers.assert_eq(#calls.rule_removals, 0,
				"live rules stay until the exact generation is fenced")
			calls.finish_stop(true, "stopped")
			helpers.assert_eq(#calls.rule_removals, 1)
			helpers.assert_eq(calls.saved_enabled[#calls.saved_enabled], false,
				"the off decision is persisted before the rules are removed")
			helpers.assert_eq(result, true)
			helpers.assert_eq(reason, "stopped")
			helpers.assert_eq(remap.get_enabled(), false)
		end)
	end)

	helpers.it("reports rules it could not remove while keeping the switch off", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ rule_removal_succeeds = false })
			local result, reason = nil, nil
			remap.set_enabled(false, function(ok, detail) result, reason = ok, detail end)
			calls.finish_stop(true, "stopped")
			helpers.assert_eq(#calls.rule_removals, 1)
			helpers.assert_eq(result, false, "a retained rule must not be reported as removed")
			helpers.assert_true(tostring(reason):find("rules-not-removed", 1, true) ~= nil,
				"the refusal names the retained rules: " .. tostring(reason))
			helpers.assert_eq(remap.get_enabled(), false,
				"the lease is fenced and the off decision persisted: the switch stays off")
		end)
	end)

	helpers.it("never touches karabiner.json when STOPPED is not proven", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			remap.set_enabled(false)
			calls.finish_stop(false, "stop-failed")
			helpers.assert_eq(#calls.rule_removals, 0)
		end)
	end)
end)

helpers.describe("Remove Ergopti from Karabiner", function()
	helpers.it("turns an enabled integration off through the exact lease", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local result = nil
			helpers.assert_true(remap.remove_from_karabiner(function(ok) result = ok end))
			helpers.assert_eq(calls.stop, 1)
			helpers.assert_eq(#calls.rule_removals, 0)
			calls.finish_stop(true, "stopped")
			helpers.assert_eq(#calls.rule_removals, 1)
			helpers.assert_eq(result, true)
			helpers.assert_eq(remap.get_enabled(), false)
		end)
	end)

	helpers.it("joins exact retirement and guardian removal before cleanup when already off", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ initially_enabled = false })
			local result, reason = nil, nil
			helpers.assert_true(remap.remove_from_karabiner(function(ok, detail)
				result, reason = ok, detail
			end))
			helpers.assert_eq(calls.stop, 1, "removal joins every retained generation before unregistering")
			helpers.assert_eq(#calls.rule_removals, 0, "no cleanup precedes the retirement receipt")
			helpers.assert_nil(result)
			calls.finish_stop(true, "stopped")
			helpers.assert_eq(calls.unregister_guardian, 1)
			helpers.assert_eq(#calls.rule_removals, 1)
			helpers.assert_eq(result, true)
			helpers.assert_eq(reason, "removed")
		end)
	end)

	helpers.it("reports a refused cleanup when the switch is already off", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({
				initially_enabled = false, rule_removal_succeeds = false,
			})
			local result = nil
			helpers.assert_true(remap.remove_from_karabiner(function(ok) result = ok end))
			helpers.assert_nil(result, "accepted retirement has not acknowledged cleanup")
			calls.finish_stop(true, "stopped")
			helpers.assert_eq(calls.unregister_guardian, 1)
			helpers.assert_eq(#calls.rule_removals, 1)
			helpers.assert_eq(result, false)
		end)
	end)
end)

helpers.describe("Tap-Hold settings edited while the switch is off", function()
	-- Every bulk command the Tap-Holds submenu and the global restore reach.
	local BULK_EDITS = {
		{ name = "reset_to_defaults", run = function(remap, done) return remap.reset_to_defaults(done) end },
		{ name = "clear_all_bindings", run = function(remap, done) return remap.clear_all_bindings(done) end },
		{ name = "copy_tap_actions_to_combos",
			run = function(remap, done) return remap.copy_tap_actions_to_combos(done) end },
		{ name = "restore_settings", run = function(remap, done)
			return remap.restore_settings(remap.snapshot_settings(), done)
		end },
	}

	for _, edit in ipairs(BULK_EDITS) do
		helpers.it(edit.name .. " persists without a deploy and leaves the switch usable", function()
			with_fixture(function(fixture)
				local remap, calls = fixture.load_enabled_remap({ initially_enabled = false })
				local result, reason = nil, nil
				helpers.assert_true(edit.run(remap, function(ok, detail) result, reason = ok, detail end),
					"an edit with the switch off is a settings change, not a refused deploy")
				helpers.assert_eq(result, true, "reason: " .. tostring(reason))
				helpers.assert_eq(reason, "persisted-integration-off")
				helpers.assert_true(calls.save >= 1, "the edit must reach config_karabiner.toml")
				helpers.assert_eq(calls.saved_enabled[#calls.saved_enabled], false,
					"a settings edit must not decide the switch")
				helpers.assert_eq(calls.build, 0,
					"nothing may be deployed while Ergopti does not use Karabiner")
				helpers.assert_eq(calls.start + calls.start_paused, 0)

				helpers.assert_true(remap.set_enabled(true),
					"no retained bulk owner may lock the switch after an edit made while it was off")
			end)
		end)
	end
end)
