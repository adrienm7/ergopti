--- tests/unit/platform/remap/enable_transaction/test_bulk_owner.lua

--- ==============================================================================
--- MODULE: Remap Transaction Regression
--- DESCRIPTION:
--- Preserves exact lifecycle and persistence guarantees inside one fixture scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("karabiner bulk settings use one exact reversible transaction", function()
	local function seed_bindings(remap, calls)
		helpers.assert_true(remap.set_tap_action("left_shift", "escape"))
		helpers.assert_true(remap.set_hold_action("left_shift", "layer"))
		helpers.assert_true(remap.set_combo_tap_action(
			"left_shift+right_shift", "escape"))
		helpers.assert_true(remap.set_combo_hold_action(
			"left_shift+right_shift", "layer"))
		helpers.assert_true(remap.set_combo_combo_action(
			"left_shift+right_shift", "layer"))
		calls.save = 0
		calls.saved_enabled = {}
		calls.saved_payloads = {}
	end

	local function install_immediate_regeneration(remap, observations)
		remap.regenerate = function(on_done)
			observations.regenerations = observations.regenerations + 1
			if on_done then on_done(true, "ready") end
			return true
		end
	end

	--- Returns every synchronous persisted-settings mutation surface.
	--- @param remap table Initialized remap facade.
	--- @return table mutations Zero-argument mutation callbacks.
	local function synchronous_setting_mutations(remap)
		return {
			function() return remap.set_tap_action("left_shift", "caps_word") end,
			function() return remap.set_hold_action("left_shift", "caps_word") end,
			function() return remap.set_tap_timeout("left_shift", 321) end,
			function()
				return remap.set_combo_tap_action("left_shift+right_shift", "caps_word")
			end,
			function()
				return remap.set_combo_hold_action("left_shift+right_shift", "caps_word")
			end,
			function()
				return remap.set_combo_combo_action("left_shift+right_shift", "caps_word")
			end,
			function() return remap.set_tap_hold_timeout(321) end,
			function() return remap.set_sticky_timeout(4321) end,
			function() return remap.set_simultaneous_threshold(87) end,
			function() return remap.set_combo_symmetric(true) end,
		}
	end

	--- Returns every bulk persisted-settings mutation surface.
	--- @param remap table Initialized remap facade.
	--- @return table mutations Functions accepting one terminal callback.
	local function bulk_setting_mutations(remap)
		return {
			function(callback) return remap.clear_tap_hold_binding("left_shift", callback) end,
			function(callback)
				return remap.clear_combo_binding("left_shift+right_shift", callback)
			end,
			function(callback) return remap.clear_all_bindings(callback) end,
			function(callback) return remap.reset_to_defaults(callback) end,
			function(callback) return remap.copy_tap_actions_to_combos(callback) end,
		}
	end

	--- Proves the complete settings surface is inert at one lifecycle boundary.
	--- @param remap table Initialized remap facade.
	--- @param calls table Observable persistence calls.
	--- @param stage string Failure-message stage label.
	local function assert_settings_surface_refused(remap, calls, stage)
		local save_count = calls.save
		for index, mutate in ipairs(synchronous_setting_mutations(remap)) do
			helpers.assert_eq(mutate(), false,
				stage .. " synchronous setting " .. index .. " must be refused")
		end
		for index, mutate in ipairs(bulk_setting_mutations(remap)) do
			local callback_count = 0
			local callback_result = nil
			helpers.assert_eq(mutate(function(ok)
				callback_count = callback_count + 1
				callback_result = ok
			end), false, stage .. " bulk setting " .. index .. " must be refused")
			helpers.assert_eq(callback_count, 1)
			helpers.assert_true(callback_result == false)
		end
		helpers.assert_eq(calls.save, save_count,
			stage .. " must publish no settings payload")
	end

	helpers.it("HS-019 commits each manifest bulk operation with one persistence write", function()
		with_fixture(function(fixture)
			local clear_remap, clear_calls = fixture.load_enabled_remap()
			seed_bindings(clear_remap, clear_calls)
			local clear = { regenerations = 0, outcome = nil, changed = nil }
			install_immediate_regeneration(clear_remap, clear)
			helpers.assert_true(clear_remap.clear_all_bindings(function(ok, _, changed)
				clear.outcome = ok
				clear.changed = changed
			end))
			helpers.assert_true(clear.outcome == true)
			helpers.assert_eq(clear.changed, 2)
			helpers.assert_eq(clear_calls.save, 1,
				"Clear All must persist one complete candidate, never one commit per setter")
			helpers.assert_eq(clear.regenerations, 1)
			helpers.assert_eq(clear_remap.get_tap_action("left_shift"), "none")
			helpers.assert_eq(clear_remap.get_hold_action("left_shift"), "none")
			helpers.assert_eq(clear_remap.get_combo_tap_action("left_shift+right_shift"), "none")
			helpers.assert_eq(clear_remap.get_combo_hold_action("left_shift+right_shift"), "none")
			helpers.assert_eq(clear_remap.get_combo_combo_action("left_shift+right_shift"), "none")

			local reset_remap, reset_calls = fixture.load_enabled_remap()
			seed_bindings(reset_remap, reset_calls)
			helpers.assert_true(reset_remap.set_tap_hold_timeout(321))
			reset_calls.save = 0
			local reset = { regenerations = 0, outcome = nil }
			install_immediate_regeneration(reset_remap, reset)
			helpers.assert_true(reset_remap.reset_to_defaults(function(ok) reset.outcome = ok end))
			helpers.assert_true(reset.outcome == true)
			helpers.assert_eq(reset_calls.save, 1)
			helpers.assert_eq(reset.regenerations, 1)
			helpers.assert_eq(reset_calls.saved_payloads[1].tap_holds_enabled, true)
			helpers.assert_eq(reset_remap.get_tap_action("left_shift"), "none")
			helpers.assert_eq(reset_remap.get_tap_hold_timeout(), 200)

			local copy_remap, copy_calls = fixture.load_enabled_remap()
			helpers.assert_true(copy_remap.set_combo_tap_action(
				"left_shift+right_shift", "escape"))
			helpers.assert_true(copy_remap.set_combo_combo_action(
				"left_shift+right_shift", "layer"))
			copy_calls.save = 0
			local copy = { regenerations = 0, outcome = nil, changed = nil }
			install_immediate_regeneration(copy_remap, copy)
			helpers.assert_true(copy_remap.copy_tap_actions_to_combos(function(ok, _, changed)
				copy.outcome = ok
				copy.changed = changed
			end))
			helpers.assert_true(copy.outcome == true)
			helpers.assert_eq(copy.changed, 1)
			helpers.assert_eq(copy_calls.save, 1)
			helpers.assert_eq(copy.regenerations, 1)
			helpers.assert_eq(copy_remap.get_combo_combo_action(
				"left_shift+right_shift"), "escape")
		end)
	end)

	helpers.it("HS-019 clears each local row with one persistence write", function()
		with_fixture(function(fixture)
			local tap_remap, tap_calls = fixture.load_enabled_remap()
			seed_bindings(tap_remap, tap_calls)
			local tap = { regenerations = 0, outcome = nil, changed = nil }
			install_immediate_regeneration(tap_remap, tap)
			helpers.assert_true(tap_remap.clear_tap_hold_binding("left_shift",
				function(ok, _, changed)
					tap.outcome = ok
					tap.changed = changed
				end))
			helpers.assert_true(tap.outcome == true)
			helpers.assert_eq(tap.changed, 1)
			helpers.assert_eq(tap_calls.save, 1,
				"one row clear must persist tap and hold in one detached payload")
			helpers.assert_eq(tap.regenerations, 1)
			helpers.assert_eq(tap_remap.get_tap_action("left_shift"), "none")
			helpers.assert_eq(tap_remap.get_hold_action("left_shift"), "none")
			helpers.assert_eq(tap_remap.get_combo_combo_action(
				"left_shift+right_shift"), "layer",
				"a tap/hold row clear must preserve sibling combo slots")

			local combo_remap, combo_calls = fixture.load_enabled_remap()
			seed_bindings(combo_remap, combo_calls)
			local combo = { regenerations = 0, outcome = nil, changed = nil }
			install_immediate_regeneration(combo_remap, combo)
			helpers.assert_true(combo_remap.clear_combo_binding(
				"left_shift+right_shift", function(ok, _, changed)
					combo.outcome = ok
					combo.changed = changed
				end))
			helpers.assert_true(combo.outcome == true)
			helpers.assert_eq(combo.changed, 1)
			helpers.assert_eq(combo_calls.save, 1,
				"one combo clear must persist all three slots in one detached payload")
			helpers.assert_eq(combo.regenerations, 1)
			helpers.assert_eq(combo_remap.get_combo_tap_action(
				"left_shift+right_shift"), "none")
			helpers.assert_eq(combo_remap.get_combo_hold_action(
				"left_shift+right_shift"), "none")
			helpers.assert_eq(combo_remap.get_combo_combo_action(
				"left_shift+right_shift"), "none")
			helpers.assert_eq(combo_remap.get_tap_action("left_shift"), "escape",
				"a combo row clear must preserve sibling tap/hold slots")
		end)
	end)

	helpers.it("HS-019 deploys the exact published candidate and inverse payload", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			seed_bindings(remap, calls)
			local terminals = {}
			local deployed = {}
			local callback_count = 0
			local outcome = nil
			remap.regenerate = function(on_done)
				deployed[#deployed + 1] = {
					enabled = remap.get_enabled(),
					tap = remap.get_tap_action("left_shift"),
					hold = remap.get_hold_action("left_shift"),
					combo_tap = remap.get_combo_tap_action("left_shift+right_shift"),
					combo_hold = remap.get_combo_hold_action("left_shift+right_shift"),
					combo = remap.get_combo_combo_action("left_shift+right_shift"),
				}
				terminals[#terminals + 1] = on_done
				return true
			end

			helpers.assert_true(remap.clear_all_bindings(function(ok)
				callback_count = callback_count + 1
				outcome = ok
			end))
			helpers.assert_eq(#calls.saved_payloads, 1)
			helpers.assert_true(calls.saved_payloads[1].enabled == true)
			helpers.assert_eq(calls.saved_payloads[1].tap_hold_config.left_shift.tap, "none")
			helpers.assert_eq(calls.saved_payloads[1].tap_hold_config.left_shift.hold, "none")
			helpers.assert_eq(
				calls.saved_payloads[1].mod_combos_config["left_shift+right_shift"].combo,
				"none")
			helpers.assert_true(helpers.deep_equal(deployed[1], {
				enabled = true,
				tap = "none",
				hold = "none",
				combo_tap = "none",
				combo_hold = "none",
				combo = "none",
			}), "regeneration must observe the same complete candidate that was saved")

			terminals[1](false, "candidate-failed")
			helpers.assert_eq(#calls.saved_payloads, 2)
			helpers.assert_true(calls.saved_payloads[2].enabled == true)
			helpers.assert_eq(calls.saved_payloads[2].tap_hold_config.left_shift.tap, "escape")
			helpers.assert_eq(calls.saved_payloads[2].tap_hold_config.left_shift.hold, "layer")
			helpers.assert_eq(
				calls.saved_payloads[2].mod_combos_config["left_shift+right_shift"].combo,
				"layer")
			helpers.assert_true(helpers.deep_equal(deployed[2], {
				enabled = true,
				tap = "escape",
				hold = "layer",
				combo_tap = "escape",
				combo_hold = "layer",
				combo = "layer",
			}), "inverse regeneration must observe the exact saved snapshot")
			helpers.assert_nil(outcome)

			terminals[2](true, "inverse-ready")
			helpers.assert_true(outcome == false)
			helpers.assert_eq(callback_count, 1)
			terminals[1](true, "late-candidate-duplicate")
			terminals[2](false, "late-inverse-duplicate")
			helpers.assert_eq(callback_count, 1,
				"candidate and inverse duplicate terminals must remain inert")
			helpers.assert_eq(#calls.saved_payloads, 2)
		end)
	end)

	helpers.it("HS-019 publishes no success before the exact regeneration terminal", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			seed_bindings(remap, calls)
			local terminal = nil
			local outcome = nil
			remap.regenerate = function(on_done)
				terminal = on_done
				return true
			end

			helpers.assert_true(remap.clear_all_bindings(function(ok) outcome = ok end))
			helpers.assert_nil(outcome,
				"request acceptance is not the exact READY terminal")
			helpers.assert_type(terminal, "function")
			helpers.assert_eq(calls.save, 1)
			terminal(true, "ready")
			helpers.assert_true(outcome == true)
		end)
	end)

	helpers.it("HS-019 treats false, nil, and throw request results as failures and restores", function()
		with_fixture(function(fixture)
			for _, mode in ipairs({ "false", "nil", "throw" }) do
				local remap, calls = fixture.load_enabled_remap()
				seed_bindings(remap, calls)
				local regeneration_calls = 0
				local outcome = nil
				remap.regenerate = function(on_done)
					regeneration_calls = regeneration_calls + 1
					if regeneration_calls == 1 then
						if mode == "throw" then error("synthetic regeneration dispatch failure") end
						if mode == "nil" then return nil end
						return false
					end
					on_done(true, "inverse-ready")
					return true
				end

				helpers.assert_eq(remap.clear_all_bindings(function(ok) outcome = ok end), false,
					mode .. " request result must not be accepted")
				helpers.assert_true(outcome == false)
				helpers.assert_eq(calls.save, 2,
					mode .. " request failure must persist candidate then exact inverse")
				helpers.assert_eq(regeneration_calls, 2)
				helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
				helpers.assert_eq(remap.get_combo_combo_action(
					"left_shift+right_shift"), "layer")
			end
		end)
	end)

	helpers.it("HS-019 rejects a synchronous success callback followed by false, nil, or throw", function()
		with_fixture(function(fixture)
			for _, mode in ipairs({ "false", "nil", "throw" }) do
				local remap, calls = fixture.load_enabled_remap()
				seed_bindings(remap, calls)
				local regeneration_calls = 0
				local callback_count = 0
				local outcome = nil
				remap.regenerate = function(on_done)
					regeneration_calls = regeneration_calls + 1
					on_done(true, "synchronous-ready")
					if regeneration_calls == 1 then
						if mode == "throw" then error("synthetic post-callback failure") end
						if mode == "nil" then return nil end
						return false
					end
					return true
				end

				helpers.assert_eq(remap.clear_all_bindings(function(ok)
					callback_count = callback_count + 1
					outcome = ok
				end), false, mode .. " must override the uncommitted synchronous callback")
				helpers.assert_true(outcome == false)
				helpers.assert_eq(callback_count, 1)
				helpers.assert_eq(calls.save, 2)
				helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
				helpers.assert_true(calls.saved_payloads[1].enabled == true)
				helpers.assert_true(calls.saved_payloads[2].enabled == true)
			end
		end)
	end)

	helpers.it("HS-019 waits for inverse regeneration after a negative terminal", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			seed_bindings(remap, calls)
			local terminals = {}
			local outcome = nil
			remap.regenerate = function(on_done)
				terminals[#terminals + 1] = on_done
				return true
			end

			helpers.assert_true(remap.clear_all_bindings(function(ok) outcome = ok end))
			terminals[1](false, "activation-failed")
			helpers.assert_nil(outcome,
				"the caller must wait until the exact inverse has its own terminal")
			helpers.assert_eq(calls.save, 2)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			helpers.assert_eq(#terminals, 2)
			terminals[2](true, "inverse-ready")
			helpers.assert_true(outcome == false,
				"a successful inverse restores state but cannot turn the rejected action green")
		end)
	end)

	helpers.it("HS-019 retains failed inverse persistence and gates sibling setters", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			seed_bindings(remap, calls)
			local terminals = {}
			local outcome = nil
			remap.regenerate = function(on_done)
				terminals[#terminals + 1] = on_done
				return true
			end

			helpers.assert_true(remap.clear_all_bindings(function(ok) outcome = ok end))
			calls.set_save_succeeds(false)
			terminals[1](false, "candidate-failed")
			helpers.assert_true(outcome == false)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "none",
				"a refused inverse save must not publish an unpersisted snapshot")

			calls.set_save_succeeds(true)
			helpers.assert_eq(remap.set_tap_action("left_shift", "caps_word"), false,
				"the click that retries retained recovery must not also commit a sibling mutation")
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			helpers.assert_eq(#terminals, 2)
			terminals[2](true, "inverse-ready")
			helpers.assert_true(remap.set_tap_action("left_shift", "caps_word"))
			helpers.assert_eq(remap.get_tap_action("left_shift"), "caps_word")
		end)
	end)

	helpers.it("HS-019 keeps bulk compensation owned across revoke and teardown", function()
		with_fixture(function(fixture)
			for _, inverse_mode in ipairs({ "false", "nil", "throw", "pending" }) do
				local remap, calls = fixture.load_enabled_remap()
				seed_bindings(remap, calls)
				if inverse_mode == "pending" then
					calls.set_save_results({ "true", "true" })
				else
					-- Candidate save succeeds; the first inverse save and the first
					-- lifecycle retry both refuse in the requested exact mode.
					calls.set_save_results({ "true", inverse_mode, inverse_mode })
				end

				local terminals = {}
				local bulk_callback_count = 0
				local bulk_outcome = nil
				remap.regenerate = function(on_done)
					terminals[#terminals + 1] = on_done
					return true
				end

				helpers.assert_true(remap.clear_all_bindings(function(ok)
					bulk_callback_count = bulk_callback_count + 1
					bulk_outcome = ok
				end), "candidate regeneration must be accepted: " .. inverse_mode)
				helpers.assert_eq(#terminals, 1)
				terminals[1](false, "candidate-failed")
				terminals[1](true, "late-candidate-duplicate")

				if inverse_mode == "pending" then
					helpers.assert_nil(bulk_outcome,
						"the bulk owner must wait for pending inverse regeneration")
					helpers.assert_eq(#terminals, 2)
				else
					helpers.assert_true(bulk_outcome == false)
					helpers.assert_eq(bulk_callback_count, 1)
					helpers.assert_eq(#terminals, 1,
						"refused inverse persistence must retain its snapshot before regeneration")
					helpers.assert_eq(remap.get_tap_action("left_shift"), "none",
						"an unpersisted inverse must not be published live")
				end

				local first_revoke_count = 0
				local first_revoke_outcome = nil
				helpers.assert_eq(remap.revoke("HS-019-bulk-debt-first", function(ok)
					first_revoke_count = first_revoke_count + 1
					first_revoke_outcome = ok
				end), false, "revoke must refuse retained compensation: " .. inverse_mode)
				helpers.assert_eq(first_revoke_count, 1)
				helpers.assert_true(first_revoke_outcome == false)
				helpers.assert_eq(calls.stop, 0,
					"native STOP must remain below the exact bulk owner")
				helpers.assert_eq(calls.onboarding_stop_attempts, 0,
					"onboarding teardown must remain below the exact bulk owner")

				if inverse_mode ~= "pending" then
					calls.set_save_results({ "true" })
				end
				local second_revoke_count = 0
				local second_revoke_outcome = nil
				helpers.assert_eq(remap.revoke("HS-019-bulk-debt-retry", function(ok)
					second_revoke_count = second_revoke_count + 1
					second_revoke_outcome = ok
				end), false, "an accepted inverse retry is still pending: " .. inverse_mode)
				helpers.assert_eq(second_revoke_count, 1)
				helpers.assert_true(second_revoke_outcome == false)
				helpers.assert_eq(#terminals, 2,
					"exactly one inverse regeneration owner must survive lifecycle retries")
				helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
				helpers.assert_eq(remap.get_hold_action("left_shift"), "layer")
				helpers.assert_eq(remap.get_combo_tap_action(
					"left_shift+right_shift"), "escape")
				helpers.assert_eq(remap.get_combo_hold_action(
					"left_shift+right_shift"), "layer")
				helpers.assert_eq(remap.get_combo_combo_action(
					"left_shift+right_shift"), "layer")
				local restored_payload = calls.saved_payloads[#calls.saved_payloads]
				helpers.assert_true(restored_payload.enabled == true,
					"bulk lifecycle recovery must preserve enabled intent")
				helpers.assert_eq(restored_payload.tap_hold_config.left_shift.tap, "escape")
				helpers.assert_eq(restored_payload.tap_hold_config.left_shift.hold, "layer")
				helpers.assert_eq(
					restored_payload.mod_combos_config["left_shift+right_shift"].combo,
					"layer")

				helpers.assert_eq(remap.stop(), false,
					"public stop must remain refused while inverse regeneration is pending")
				calls.lease_phase = "idle"
				helpers.assert_eq(remap.teardown_local(), false,
					"even an IDLE observation cannot erase a pending bulk owner")
				helpers.assert_eq(calls.lifecycle_stop_attempts, 0,
					"refused local teardown must publish no local lifecycle stop")
				calls.lease_phase = "active"

				terminals[2](true, "inverse-ready")
				terminals[2](false, "late-inverse-duplicate")
				helpers.assert_eq(bulk_callback_count, 1,
					"candidate and inverse duplicates must not resettle the bulk caller")
				helpers.assert_true(bulk_outcome == false)
				helpers.assert_eq(first_revoke_count, 1,
					"late compensation must not resettle a refused revoke caller")
				helpers.assert_eq(second_revoke_count, 1)

				local shutdown_count = 0
				local shutdown_outcome = nil
				helpers.assert_true(remap.shutdown("HS-019-bulk-debt-settled", function(ok)
					shutdown_count = shutdown_count + 1
					shutdown_outcome = ok
				end), "a retry may stop only after the exact bulk owner settles")
				helpers.assert_nil(shutdown_outcome)
				helpers.assert_eq(calls.stop, 1)
				local exact_stop_callback = calls.stop_callback
				calls.finish_stop(true, "stopped")
				helpers.assert_eq(shutdown_count, 1)
				helpers.assert_true(shutdown_outcome == true)
				exact_stop_callback(true, "late-stop-duplicate")
				helpers.assert_eq(shutdown_count, 1,
					"duplicate native STOP terminals must not resettle shutdown")
				helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
				helpers.assert_eq(remap.get_combo_combo_action(
					"left_shift+right_shift"), "layer")
			end
		end)
	end)

	helpers.it("HS-019 retains failed inverse regeneration and retries it before siblings", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			seed_bindings(remap, calls)
			local terminals = {}
			local outcome = nil
			remap.regenerate = function(on_done)
				terminals[#terminals + 1] = on_done
				return true
			end

			helpers.assert_true(remap.clear_all_bindings(function(ok) outcome = ok end))
			terminals[1](false, "candidate-failed")
			terminals[2](false, "inverse-failed")
			helpers.assert_true(outcome == false)
			helpers.assert_eq(remap.set_hold_action("left_shift", "caps_word"), false)
			helpers.assert_eq(#terminals, 3,
				"the first sibling click must retry the retained inverse, not mutate settings")
			terminals[3](true, "inverse-ready")
			helpers.assert_true(remap.set_hold_action("left_shift", "caps_word"))
			helpers.assert_eq(remap.get_hold_action("left_shift"), "caps_word")
		end)
	end)

	helpers.it("HS-019 retains inverse false, nil, and throw results for exact retry", function()
		with_fixture(function(fixture)
			for _, mode in ipairs({ "false", "nil", "throw" }) do
				local remap, calls = fixture.load_enabled_remap()
				seed_bindings(remap, calls)
				local regeneration_calls = 0
				local outcome = nil
				local retry_mode = false
				remap.regenerate = function(on_done)
					regeneration_calls = regeneration_calls + 1
					if regeneration_calls == 1 then
						on_done(false, "candidate-failed")
						return true
					end
					if not retry_mode then
						if mode == "throw" then error("synthetic inverse request failure") end
						if mode == "nil" then return nil end
						return false
					end
					on_done(true, "inverse-ready")
					return true
				end

				helpers.assert_true(remap.clear_all_bindings(function(ok) outcome = ok end),
					"the candidate request was accepted before inverse refusal: " .. mode)
				helpers.assert_true(outcome == false)
				helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
				helpers.assert_eq(calls.save, 2)
				helpers.assert_true(calls.saved_payloads[2].enabled == true)

				-- The click retries the retained inverse first and mutates only once
				-- that retry has settled every debt; refusing it anyway made the
				-- user click twice and logged a phase that no longer existed.
				retry_mode = true
				helpers.assert_true(remap.set_tap_action("left_shift", "caps_word"),
					"the click whose retry settles the inverse debt must commit: " .. mode)
				helpers.assert_eq(regeneration_calls, 3,
					"the click must retry the retained inverse before mutating: " .. mode)
				helpers.assert_true(remap.settings_pending() == false)
				helpers.assert_eq(calls.save, 3, "candidate, inverse, then the click's own save")
				helpers.assert_eq(remap.get_tap_action("left_shift"), "caps_word")
			end
		end)
	end)

	helpers.it("HS-019 gates every settings sibling while a terminal is pending", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			seed_bindings(remap, calls)
			local terminal = nil
			local outcome = nil
			remap.regenerate = function(on_done)
				terminal = on_done
				return true
			end

			helpers.assert_true(remap.clear_all_bindings(function(ok) outcome = ok end))
			helpers.assert_nil(outcome)
			local save_count = calls.save
			local synchronous_cases = {
				function() return remap.set_tap_action("left_shift", "caps_word") end,
				function() return remap.set_hold_action("left_shift", "caps_word") end,
				function() return remap.set_tap_timeout("left_shift", 321) end,
				function()
					return remap.set_combo_tap_action("left_shift+right_shift", "caps_word")
				end,
				function()
					return remap.set_combo_hold_action("left_shift+right_shift", "caps_word")
				end,
				function()
					return remap.set_combo_combo_action("left_shift+right_shift", "caps_word")
				end,
				function() return remap.set_tap_hold_timeout(321) end,
				function() return remap.set_sticky_timeout(4321) end,
				function() return remap.set_simultaneous_threshold(87) end,
				function() return remap.set_combo_symmetric(true) end,
			}
			for index, mutate in ipairs(synchronous_cases) do
				helpers.assert_eq(mutate(), false,
					"synchronous settings sibling " .. index .. " must be gated")
			end

			local bulk_cases = {
				function(callback) return remap.clear_tap_hold_binding("left_shift", callback) end,
				function(callback)
					return remap.clear_combo_binding("left_shift+right_shift", callback)
				end,
				function(callback) return remap.clear_all_bindings(callback) end,
				function(callback) return remap.reset_to_defaults(callback) end,
				function(callback) return remap.copy_tap_actions_to_combos(callback) end,
			}
			for index, mutate in ipairs(bulk_cases) do
				local callback_count = 0
				local callback_result = nil
				helpers.assert_eq(mutate(function(ok)
					callback_count = callback_count + 1
					callback_result = ok
				end), false, "bulk settings sibling " .. index .. " must be gated")
				helpers.assert_eq(callback_count, 1)
				helpers.assert_true(callback_result == false)
			end

			for _, target in ipairs({ true, false }) do
				local callback_count = 0
				local callback_result = nil
				helpers.assert_eq(remap.set_enabled(target, function(ok)
					callback_count = callback_count + 1
					callback_result = ok
				end), false, "enabled-state intent must not overlap a pending bulk owner")
				helpers.assert_eq(callback_count, 1)
				helpers.assert_true(callback_result == false)
			end
			helpers.assert_eq(calls.onboarding_stop_attempts, 0,
				"a gated disable must not begin onboarding teardown")
			helpers.assert_eq(calls.stop, 0,
				"a gated disable must not begin exact lease teardown")
			helpers.assert_eq(calls.save, save_count,
				"no gated sibling may publish a second durable payload")
			helpers.assert_true(remap.get_enabled())
			helpers.assert_true(calls.saved_payloads[1].enabled == true)

			terminal(true, "ready")
			helpers.assert_true(outcome == true)
		end)
	end)

	helpers.it("HS-019 gates every settings mutation during enabled-state settlement", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			seed_bindings(remap, calls)
			helpers.assert_true(remap.set_enabled(false))
			helpers.assert_eq(calls.stop, 1)
			helpers.assert_eq(calls.save, 0,
				"STOP request acceptance must not publish enabled=false")

			local synchronous_cases = {
				function() return remap.set_tap_action("left_shift", "caps_word") end,
				function() return remap.set_hold_action("left_shift", "caps_word") end,
				function() return remap.set_tap_timeout("left_shift", 321) end,
				function()
					return remap.set_combo_tap_action("left_shift+right_shift", "caps_word")
				end,
				function()
					return remap.set_combo_hold_action("left_shift+right_shift", "caps_word")
				end,
				function()
					return remap.set_combo_combo_action("left_shift+right_shift", "caps_word")
				end,
				function() return remap.set_tap_hold_timeout(321) end,
				function() return remap.set_sticky_timeout(4321) end,
				function() return remap.set_simultaneous_threshold(87) end,
				function() return remap.set_combo_symmetric(true) end,
			}
			for index, mutate in ipairs(synchronous_cases) do
				helpers.assert_eq(mutate(), false,
					"synchronous setting " .. index .. " must wait for enabled-state settlement")
			end

			local bulk_cases = {
				function(callback) return remap.clear_tap_hold_binding("left_shift", callback) end,
				function(callback)
					return remap.clear_combo_binding("left_shift+right_shift", callback)
				end,
				function(callback) return remap.clear_all_bindings(callback) end,
				function(callback) return remap.reset_to_defaults(callback) end,
				function(callback) return remap.copy_tap_actions_to_combos(callback) end,
			}
			for index, mutate in ipairs(bulk_cases) do
				local callback_count = 0
				local callback_result = nil
				helpers.assert_eq(mutate(function(ok)
					callback_count = callback_count + 1
					callback_result = ok
				end), false, "bulk setting " .. index .. " must wait for enabled-state settlement")
				helpers.assert_eq(callback_count, 1)
				helpers.assert_true(callback_result == false)
			end
			helpers.assert_eq(calls.save, 0)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			helpers.assert_true(remap.get_enabled())

			calls.finish_stop(true, "stopped")
			helpers.assert_eq(remap.get_enabled(), false)
			helpers.assert_eq(calls.save, 1)
			helpers.assert_true(calls.saved_payloads[1].enabled == false)
		end)
	end)

	helpers.it("HS-019 owns real async onboarding preflight before every settings mutation", function()
		with_fixture(function(fixture)
			local remap, calls, installer = fixture.load_remap_with_real_onboarding()
			seed_bindings(remap, calls)
			local disable_count = 0
			local disable_outcome = nil
			helpers.assert_true(remap.set_enabled(false, function(ok)
				disable_count = disable_count + 1
				disable_outcome = ok
			end))
			helpers.assert_nil(disable_outcome)
			helpers.assert_eq(installer.task.terminate_calls, 1,
				"the fixture must be waiting on one real native installer task")
			helpers.assert_eq(calls.stop, 0,
				"lease revocation must remain below the unsettled onboarding fence")

			local synchronous_cases = {
				function() return remap.set_tap_action("left_shift", "caps_word") end,
				function() return remap.set_hold_action("left_shift", "caps_word") end,
				function() return remap.set_tap_timeout("left_shift", 321) end,
				function()
					return remap.set_combo_tap_action("left_shift+right_shift", "caps_word")
				end,
				function()
					return remap.set_combo_hold_action("left_shift+right_shift", "caps_word")
				end,
				function()
					return remap.set_combo_combo_action("left_shift+right_shift", "caps_word")
				end,
				function() return remap.set_tap_hold_timeout(321) end,
				function() return remap.set_sticky_timeout(4321) end,
				function() return remap.set_simultaneous_threshold(87) end,
				function() return remap.set_combo_symmetric(true) end,
			}
			for index, mutate in ipairs(synchronous_cases) do
				helpers.assert_eq(mutate(), false,
					"synchronous setting " .. index .. " must wait below onboarding settlement")
			end

			local bulk_cases = {
				function(callback) return remap.clear_tap_hold_binding("left_shift", callback) end,
				function(callback)
					return remap.clear_combo_binding("left_shift+right_shift", callback)
				end,
				function(callback) return remap.clear_all_bindings(callback) end,
				function(callback) return remap.reset_to_defaults(callback) end,
				function(callback) return remap.copy_tap_actions_to_combos(callback) end,
			}
			for index, mutate in ipairs(bulk_cases) do
				local callback_count = 0
				local callback_result = nil
				helpers.assert_eq(mutate(function(ok)
					callback_count = callback_count + 1
					callback_result = ok
				end), false, "bulk setting " .. index .. " must wait below onboarding settlement")
				helpers.assert_eq(callback_count, 1)
				helpers.assert_true(callback_result == false)
			end
			helpers.assert_eq(calls.save, 0,
				"no setting may publish while accepted disable intent owns onboarding preflight")
			helpers.assert_eq(calls.build, 0)
			helpers.assert_eq(calls.deploy, 0)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			helpers.assert_true(remap.get_enabled())

			local joined_count = 0
			local joined_outcome = nil
			helpers.assert_true(remap.set_enabled(false, function(ok)
				joined_count = joined_count + 1
				joined_outcome = ok
			end), "same-target disable must join the owned onboarding preflight")
			helpers.assert_nil(joined_outcome)
			helpers.assert_eq(installer.task.terminate_calls, 1,
				"joined disable must not request duplicate native task termination")

			local opposite_count = 0
			local opposite_outcome = nil
			helpers.assert_eq(remap.set_enabled(true, function(ok)
				opposite_count = opposite_count + 1
				opposite_outcome = ok
			end), false, "opposite intent must not overtake accepted disable preflight")
			helpers.assert_eq(opposite_count, 1)
			helpers.assert_true(opposite_outcome == false)

			installer.task:complete(1, "", "cancelled")
			helpers.assert_eq(calls.stop, 1,
				"the retained disable continuation must start after onboarding settles")
			helpers.assert_nil(disable_outcome)
			helpers.assert_nil(joined_outcome)
			calls.finish_stop(true, "stopped")
			helpers.assert_eq(disable_count, 1)
			helpers.assert_true(disable_outcome == true)
			helpers.assert_eq(joined_count, 1)
			helpers.assert_true(joined_outcome == true)
			helpers.assert_true(not remap.get_enabled())
			helpers.assert_eq(calls.save, 1)
			helpers.assert_true(calls.saved_payloads[1].enabled == false)
		end)
	end)

	helpers.it("HS-019 latches synchronous onboarding completion behind exact acceptance", function()
		with_fixture(function(fixture)
			for _, mode in ipairs({ "false", "nil", "throw", "true" }) do
				local native_callback = nil
				local onboarding = {
					run_first_run_wizard = function() return true end,
					stop = function(on_done)
						native_callback = on_done
						on_done(true, "synchronous-stopped")
						on_done(true, "synchronous-duplicate")
						if mode == "throw" then error("synthetic post-callback stop failure") end
						if mode == "nil" then return nil end
						return mode == "true"
					end,
				}
				local remap, calls = fixture.load_enabled_remap({ onboarding_module = onboarding })
				local callback_count = 0
				local callback_result = nil
				local accepted = remap.set_enabled(false, function(ok)
					callback_count = callback_count + 1
					callback_result = ok
				end)

				if mode == "true" then
					helpers.assert_true(accepted)
					helpers.assert_eq(calls.stop, 1,
						"literal-true acceptance must hand off exactly one lease STOP")
					helpers.assert_eq(callback_count, 0)
					helpers.assert_type(native_callback, "function")
					native_callback(true, "late-duplicate")
					helpers.assert_eq(calls.stop, 1)
					calls.finish_stop(true, "stopped")
					helpers.assert_eq(callback_count, 1)
					helpers.assert_true(callback_result == true)
				else
					helpers.assert_eq(accepted, false,
						"callback true cannot override onboarding request " .. mode)
					helpers.assert_eq(calls.stop, 0)
					helpers.assert_eq(calls.save, 0)
					helpers.assert_true(remap.get_enabled())
					helpers.assert_eq(callback_count, 1)
					helpers.assert_true(callback_result == false)
					helpers.assert_type(native_callback, "function")
					native_callback(true, "late-after-refusal")
					helpers.assert_eq(callback_count, 1,
						"late native settlement must remain fenced after request refusal")
					helpers.assert_eq(calls.stop, 0)
				end
			end
		end)
	end)

	helpers.it("HS-019 shutdown invalidates an async disable preflight exactly once", function()
		with_fixture(function(fixture)
			local remap, calls, installer = fixture.load_remap_with_real_onboarding()
			local disable_count = 0
			local disable_outcome = nil
			local disable_reason = nil
			helpers.assert_true(remap.set_enabled(false, function(ok, reason)
				disable_count = disable_count + 1
				disable_outcome = ok
				disable_reason = reason
			end))
			helpers.assert_nil(disable_outcome)
			helpers.assert_eq(installer.task.terminate_calls, 1)

			local shutdown_count = 0
			local shutdown_outcome = nil
			helpers.assert_true(remap.shutdown("HS-019-preflight-shutdown", function(ok)
				shutdown_count = shutdown_count + 1
				shutdown_outcome = ok
			end))
			helpers.assert_eq(disable_count, 1,
				"shutdown must settle the superseded disable owner immediately")
			helpers.assert_true(disable_outcome == false)
			helpers.assert_eq(disable_reason, "shutdown-in-progress")
			helpers.assert_nil(shutdown_outcome)
			helpers.assert_eq(installer.task.terminate_calls, 1,
				"shutdown must join the exact native termination already in flight")
			helpers.assert_eq(calls.stop, 1,
				"shutdown must remain the sole exact lease-stop producer")

			local late_count = 0
			local late_outcome = nil
			helpers.assert_eq(remap.set_enabled(false, function(ok)
				late_count = late_count + 1
				late_outcome = ok
			end), false, "new enabled-state work must be refused after shutdown starts")
			helpers.assert_eq(late_count, 1)
			helpers.assert_true(late_outcome == false)
			helpers.assert_eq(calls.stop, 1)

			calls.finish_stop(true, "stopped")
			helpers.assert_nil(shutdown_outcome,
				"shutdown must still join the independently owned installer settlement")
			installer.task:complete(1, "", "cancelled")
			helpers.assert_eq(shutdown_count, 1)
			helpers.assert_true(shutdown_outcome == true)
			helpers.assert_eq(disable_count, 1,
				"the stale installer callback must not resettle its superseded disable")
			helpers.assert_eq(calls.stop, 1,
				"the stale installer callback must never launch set_enabled(false)")
			helpers.assert_eq(calls.save, 0,
				"shutdown fencing must not publish the superseded preference mutation")
		end)
	end)

	helpers.it("HS-019 local teardown cannot retain or resume an async disable preflight", function()
		with_fixture(function(fixture)
			local remap, calls, installer = fixture.load_remap_with_real_onboarding()
			local disable_count = 0
			local disable_outcome = nil
			local disable_reason = nil
			helpers.assert_true(remap.set_enabled(false, function(ok, reason)
				disable_count = disable_count + 1
				disable_outcome = ok
				disable_reason = reason
			end))
			helpers.assert_nil(disable_outcome)

			-- Model a caller that already owns an exact IDLE proof and enters the
			-- deliberately separate local-teardown phase while onboarding is pending.
			calls.lease_phase = "idle"
			helpers.assert_eq(remap.teardown_local(), false,
				"native onboarding settlement must remain retryable below teardown")
			helpers.assert_eq(disable_count, 1)
			helpers.assert_true(disable_outcome == false)
			helpers.assert_eq(disable_reason, "shutdown-in-progress")
			helpers.assert_eq(calls.stop, 0,
				"local teardown must never acquire a new lease-stop owner")

			installer.task:complete(1, "", "cancelled")
			helpers.assert_eq(disable_count, 1,
				"late native settlement must not revive the invalidated disable continuation")
			helpers.assert_eq(calls.stop, 0)
			helpers.assert_eq(calls.save, 0)
			helpers.assert_true(remap.teardown_local(),
				"settled onboarding debt must allow the same exact teardown retry")

			local late_outcome = nil
			helpers.assert_eq(remap.set_enabled(false,
				function(ok) late_outcome = ok end), false)
			helpers.assert_true(late_outcome == false)
			helpers.assert_eq(calls.stop, 0)
		end)
	end)

	helpers.it("HS-019 refuses every settings mutation during revoke and after teardown", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			seed_bindings(remap, calls)
			local revoke_outcome = nil
			helpers.assert_true(remap.revoke("HS-019-settings-lifecycle", function(ok)
				revoke_outcome = ok
			end))
			helpers.assert_nil(revoke_outcome)
			assert_settings_surface_refused(remap, calls, "during revoke")
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			helpers.assert_eq(remap.get_combo_combo_action(
				"left_shift+right_shift"), "layer")

			calls.finish_stop(true, "stopped")
			helpers.assert_true(revoke_outcome == true)
			helpers.assert_true(remap.teardown_local())
			assert_settings_surface_refused(remap, calls, "after teardown")
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			helpers.assert_eq(remap.get_combo_combo_action(
				"left_shift+right_shift"), "layer")
		end)
	end)

	helpers.it("HS-019 preserves enabled intent through pending compensation debt", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			seed_bindings(remap, calls)
			local terminals = {}
			local bulk_outcome = nil
			remap.regenerate = function(on_done)
				terminals[#terminals + 1] = on_done
				return true
			end

			helpers.assert_true(remap.clear_all_bindings(function(ok) bulk_outcome = ok end))
			calls.set_save_succeeds(false)
			terminals[1](false, "candidate-failed")
			helpers.assert_true(bulk_outcome == false)
			helpers.assert_true(remap.get_enabled())

			calls.set_save_succeeds(true)
			local first_disable_count = 0
			local first_disable_outcome = nil
			helpers.assert_eq(remap.set_enabled(false, function(ok)
				first_disable_count = first_disable_count + 1
				first_disable_outcome = ok
			end), false, "disable must remain refused while inverse regeneration is pending")
			helpers.assert_eq(first_disable_count, 1)
			helpers.assert_true(first_disable_outcome == false)
			helpers.assert_eq(calls.stop, 0)
			helpers.assert_true(remap.get_enabled())
			helpers.assert_true(calls.saved_payloads[#calls.saved_payloads].enabled == true,
				"bulk compensation must preserve the exact enabled preference")

			terminals[2](true, "inverse-ready")
			local second_disable_outcome = nil
			helpers.assert_true(remap.set_enabled(false,
				function(ok) second_disable_outcome = ok end))
			helpers.assert_nil(second_disable_outcome)
			helpers.assert_true(remap.get_enabled(),
				"STOP acceptance is not a live or durable disabled commit")
			calls.finish_stop(true, "stopped")
			helpers.assert_true(second_disable_outcome == true)
			helpers.assert_eq(remap.get_enabled(), false)
			helpers.assert_true(calls.saved_payloads[#calls.saved_payloads].enabled == false)
		end)
	end)

	helpers.it("HS-019 admits enabled intent only after synchronous exact debt settlement", function()
		with_fixture(function(fixture)
			for _, retry_mode in ipairs({ "true", "false", "nil", "throw" }) do
				local remap, calls = fixture.load_enabled_remap()
				seed_bindings(remap, calls)
				local regeneration_calls = 0
				local retrying = false
				remap.regenerate = function(on_done)
					regeneration_calls = regeneration_calls + 1
					if regeneration_calls == 1 then
						on_done(false, "candidate-failed")
						return true
					end
					if not retrying then return false end
					on_done(true, "synchronous-inverse-ready")
					if retry_mode == "throw" then error("synthetic post-inverse callback failure") end
					if retry_mode == "nil" then return nil end
					return retry_mode == "true"
				end

				helpers.assert_true(remap.clear_all_bindings())
				retrying = true
				local callback_count = 0
				local callback_result = nil
				local accepted = remap.set_enabled(false, function(ok)
					callback_count = callback_count + 1
					callback_result = ok
				end)
				if retry_mode == "true" then
					helpers.assert_true(accepted,
						"literal-true inverse acceptance may hand off to disable")
					helpers.assert_eq(callback_count, 0)
					helpers.assert_eq(calls.stop, 1)
					calls.finish_stop(true, "stopped")
					helpers.assert_true(callback_result == true)
					helpers.assert_eq(remap.get_enabled(), false)
				else
					helpers.assert_eq(accepted, false,
						"a callback cannot override inverse request " .. retry_mode)
					helpers.assert_eq(callback_count, 1)
					helpers.assert_true(callback_result == false)
					helpers.assert_eq(calls.stop, 0)
					helpers.assert_true(remap.get_enabled())
					helpers.assert_true(calls.saved_payloads[#calls.saved_payloads].enabled == true)
				end
			end
		end)
	end)
end)

helpers.describe("HS-022 Karabiner snapshots share the exact bulk owner", function()
	helpers.it("captures only detached persisted settings", function()
		with_fixture(function(fixture)
			local remap = fixture.load_enabled_remap()
			helpers.assert_true(remap.set_tap_action("left_shift", "escape"))
			helpers.assert_true(remap.set_combo_symmetric(true))

			local snapshot = remap.snapshot_settings()
			helpers.assert_type(snapshot, "table")
			helpers.assert_eq(snapshot.tap_hold_config.left_shift.tap, "escape")
			helpers.assert_true(snapshot.combo_symmetric == true)
			helpers.assert_nil(snapshot.watcher)
			helpers.assert_nil(snapshot.hotkey_cycle_windows)

			snapshot.tap_hold_config.left_shift.tap = "none"
			snapshot.combo_symmetric = false
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape",
				"mutating the parent snapshot must not mutate live state")
			helpers.assert_true(remap.get_combo_symmetric() == true)
		end)
	end)

	helpers.it("restores a detached snapshot only after one exact terminal", function()
		with_fixture(function(fixture)
			local remap = fixture.load_enabled_remap()
			helpers.assert_true(remap.set_tap_action("left_shift", "escape"))
			helpers.assert_true(remap.set_hold_action("left_shift", "layer"))
			local snapshot = remap.snapshot_settings()
			local original_snapshot = fixture.clone_payload(snapshot)
			helpers.assert_true(remap.set_tap_action("left_shift", "none"))
			helpers.assert_true(remap.set_hold_action("left_shift", "none"))

			local terminals = {}
			local callback_count = 0
			local outcome = nil
			remap.regenerate = function(on_done)
				terminals[#terminals + 1] = on_done
				return true
			end
			helpers.assert_true(remap.restore_settings(snapshot, function(ok)
				callback_count = callback_count + 1
				outcome = ok
			end))
			helpers.assert_nil(outcome)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			helpers.assert_eq(remap.get_hold_action("left_shift"), "layer")
			helpers.assert_true(helpers.deep_equal(snapshot, original_snapshot),
				"restore must never consume or rewrite its caller-owned snapshot")

			terminals[1](true, "ready")
			terminals[1](false, "late-duplicate")
			helpers.assert_true(outcome == true)
			helpers.assert_eq(callback_count, 1)
		end)
	end)

	helpers.it("rejects malformed snapshots and enabled-intent drift exactly once", function()
		with_fixture(function(fixture)
			local remap = fixture.load_enabled_remap()
			local callback_count = 0
			local outcome, reason = nil, nil
			helpers.assert_eq(remap.restore_settings({}, function(ok, detail)
				callback_count = callback_count + 1
				outcome, reason = ok, detail
			end), false)
			helpers.assert_eq(callback_count, 1)
			helpers.assert_true(outcome == false)
			helpers.assert_eq(reason, "invalid-settings-snapshot")

			local snapshot = remap.snapshot_settings()
			snapshot.enabled = false
			helpers.assert_eq(remap.restore_settings(snapshot, function(ok, detail)
				callback_count = callback_count + 1
				outcome, reason = ok, detail
			end), false)
			helpers.assert_eq(callback_count, 2)
			helpers.assert_true(outcome == false)
			helpers.assert_eq(reason, "enabled-intent-changed")
		end)
	end)

	helpers.it("retains the same snapshot until older bulk recovery settles", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			helpers.assert_true(remap.set_tap_action("left_shift", "escape"))
			local snapshot = remap.snapshot_settings()
			local snapshot_before = fixture.clone_payload(snapshot)
			calls.set_save_results({ "true", "false", "true", "true" })
			local terminals = {}
			local rejected_outcome = nil
			remap.regenerate = function(on_done)
				terminals[#terminals + 1] = on_done
				return true
			end

			helpers.assert_true(remap.clear_all_bindings(function(ok)
				rejected_outcome = ok
			end))
			terminals[1](false, "candidate-failed")
			helpers.assert_true(rejected_outcome == false)

			local blocked_count = 0
			helpers.assert_eq(remap.restore_settings(snapshot, function(ok)
				blocked_count = blocked_count + 1
				helpers.assert_true(ok == false)
			end), false,
				"the retrying call must settle older debt without overlapping a new inverse")
			helpers.assert_eq(blocked_count, 1)
			helpers.assert_eq(#terminals, 2)
			terminals[2](true, "older-inverse-ready")

			local restored_count = 0
			local restored_outcome = nil
			helpers.assert_true(remap.restore_settings(snapshot, function(ok)
				restored_count = restored_count + 1
				restored_outcome = ok
			end))
			helpers.assert_eq(#terminals, 3)
			helpers.assert_nil(restored_outcome)
			terminals[3](true, "snapshot-ready")
			helpers.assert_true(restored_outcome == true)
			helpers.assert_eq(restored_count, 1)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			helpers.assert_true(helpers.deep_equal(snapshot, snapshot_before),
				"every retry must use the same untouched detached snapshot")
		end)
	end)
end)

helpers.describe("configured navigation reservations share actual remap settings", function()
	local sequence = 0
	local function with_navigation_case(scenario, settings, catalogue, real_writes)
		local lfs = require("lfs")
		sequence = sequence + 1
		local directory = helpers.temp_dir() .. "/mac-remap-nav-" .. tostring(os.time()) .. "-" .. tostring(sequence)
		assert(lfs.mkdir(directory))
		local config = directory .. "/config_karabiner.toml"
		local layer = directory .. "/layers.toml"
		local function write(path, text)
			local stream = assert(io.open(path, "wb")); assert(stream:write(text)); assert(stream:close())
		end
		local settings_text = settings or '[karabiner]\nintegration_enabled = true\n[tap_holds]\nenabled = true\n[tap_holds.config.left_shift]\ntap = "none"\nhold = "layer"\n'
		local layer_text = '[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyJ" = "none"\n'
		write(config, settings_text); write(layer, layer_text)
		local called, detail = xpcall(function()
			helpers.with_stub_scope({ "platform.remap.nav_layer" }, function()
				package.loaded["platform.remap.nav_layer"] = nil
				with_fixture(function(fixture)
					local options = { real_user_config_path = config, initially_enabled = false, real_user_config_writes = real_writes == true }
					if catalogue ~= false then options.real_action_catalogue_path = helpers.driver_root() .. "platform/remap/data/actions.json" end
					local remap, calls = fixture.load_enabled_remap(options)
					local paths = package.loaded["infra.config_paths"]
					paths.get = function() return config end
					paths.get_config_dir = function() return directory end
					calls.nav_regenerate = function()
						local terminal, reason
						local accepted = remap.regenerate(function(ok, detail) terminal, reason = ok, detail end)
						if calls.start_paused_callback ~= nil then calls.deliver_ready(true, "owned-fixture-ready") end
						if #calls.resume_callbacks > 0 then calls.deliver_resumed(true, "owned-fixture-resumed") end
						calls.nav_terminal_reason = reason
						return accepted, terminal
					end
					calls.nav_fixture_regenerated, calls.nav_fixture_completed = calls.nav_regenerate()
					scenario(remap, calls, function(text) write(config, text) end, function(text) write(layer, text) end,
						settings_text, layer_text, config)
				end)
			end)
		end, debug.traceback)
		if real_writes then
			local guard = config .. ".ergoptiplus-write-lock-v1"
			local attributes = lfs.attributes(guard)
			if attributes ~= nil then
				assert(attributes.mode == "file" and attributes.size == 0, "only the actual owned empty cooperative guard may be removed")
				assert(os.remove(guard))
			end
		end
		assert(os.remove(config)); assert(os.remove(layer)); assert(lfs.rmdir(directory))
		if not called then error(detail, 0) end
	end

	helpers.it("nav-configured remap joins a reachable layer without any native acquisition", function()
		with_navigation_case(function(remap, calls)
			helpers.assert_eq(calls.nav_fixture_completed, true, "the original native fixture must complete its real final publication fence: " .. tostring(calls.nav_terminal_reason))
			local builds, deployments, starts = calls.build, calls.deploy, calls.start
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			helpers.assert_eq(capture.codes, { 38 })
			helpers.assert_eq(capture.current(), true)
			helpers.assert_eq({ calls.build, calls.deploy, calls.start }, { builds, deployments, starts })
		end)
	end)

	for _, settings in ipairs({
		'[karabiner]\nintegration_enabled = false\n[tap_holds.config.left_shift]\nhold = "layer"\n',
		'[karabiner]\nintegration_enabled = true\n[tap_holds]\nenabled = false\n[tap_holds.config.left_shift]\nhold = "layer"\n',
		'[karabiner]\nintegration_enabled = true\n[tap_holds.config.left_shift]\nhold = "none"\n',
	}) do
		helpers.it("nav-configured remap leaves unreachable Navigation inputs unreserved: " .. settings, function()
			with_navigation_case(function(remap, calls)
				local capture = remap.capture_configured_navigation_inventory()
				if calls.nav_fixture_regenerated ~= true then
					helpers.assert_nil(capture, "an uncompiled disabled owner must not invent an empty original-map receipt")
				else
					helpers.assert_type(capture, "table")
					helpers.assert_eq(capture.codes, {})
					helpers.assert_eq(capture.current(), true)
				end
			end, settings)
		end)
	end

	helpers.it("nav-configured remap refuses observed settings source replacement", function()
		with_navigation_case(function(remap, _, write, _, text)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			write(text .. "# external successor\n")
			helpers.assert_eq(capture.current(), false)
		end)
	end)

	helpers.it("nav-configured remap refuses Navigation source replacement", function()
		with_navigation_case(function(remap, calls, _, write, _, text)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			write(text .. "# external successor\n")
			helpers.assert_eq(capture.current(), false)
		end)
	end)

	helpers.it("nav-configured remap refuses a live setting mutation without inventing source currency", function()
		with_navigation_case(function(remap)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			helpers.assert_eq(remap.set_tap_action("left_shift", "escape"), true)
			helpers.assert_eq(capture.current(), false)
		end)
	end)

	helpers.it("nav-configured remap recognizes the real layer_on action", function()
		with_navigation_case(function(remap)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			helpers.assert_eq(capture.codes, { 38 })
			helpers.assert_eq(capture.current(), true)
		end, '[karabiner]\nintegration_enabled = true\n[tap_holds]\nenabled = true\n[tap_holds.config.left_shift]\ntap = "layer_on"\nhold = "none"\n')
	end)

	helpers.it("nav-configured remap cannot activate a layer action absent from its actual catalogue", function()
		with_navigation_case(function(remap)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			helpers.assert_eq(capture.codes, {})
			helpers.assert_eq(capture.current(), true)
		end, nil, false)
	end)

	helpers.it("nav-configured remap refuses an observed action activation change", function()
		with_navigation_case(function(remap)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			local observed = 0
			for _, action in ipairs(remap.AVAILABLE_ACTIONS) do
				if action.id == "layer" then
					for _, event in ipairs(action.karabiner_to) do
						if event.set_variable and event.set_variable.name == "layer_active" then
							event.set_variable.value = 0; observed = observed + 1
						end
					end
				end
			end
			helpers.assert_eq(observed, 1, "the real action's actual activation event changed")
			helpers.assert_eq(capture.current(), false)
		end)
	end)

	helpers.it("nav-configured remap refuses disk replacement after the actual original compilation", function()
		with_navigation_case(function(remap, calls, _, write, _, text)
			helpers.assert_eq(calls.nav_fixture_regenerated, true)
			write(text:gsub("KeyJ", "KeyG"))
			helpers.assert_nil(remap.capture_configured_navigation_inventory(), "a fresh disk load cannot replace the actual compiled-map baseline")
		end)
	end)

	helpers.it("nav-configured remap retires the old captured map after real regeneration", function()
		with_navigation_case(function(remap, calls, _, write, _, text)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			write(text:gsub("KeyJ", "KeyG"))
			local accepted, completed = calls.nav_regenerate()
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(completed, true)
			helpers.assert_eq(capture.current(), false)
			local successor = remap.capture_configured_navigation_inventory()
			helpers.assert_type(successor, "table")
			helpers.assert_eq(successor.codes, { 5 })
			helpers.assert_eq(successor.current(), true)
		end)
	end)

	helpers.it("nav-configured remap refuses settings removed after compilation even when saved bytes agree", function()
		with_navigation_case(function(remap, _, write, _, text)
			helpers.assert_eq(remap.set_hold_action("left_shift", "none"), true)
			write(text:gsub('hold = "layer"', 'hold = "none"'))
			helpers.assert_nil(remap.capture_configured_navigation_inventory(), "newly saved settings do not own the old compiled rules")
		end)
	end)

	helpers.it("nav-configured remap refuses a changed nested activator definition", function()
		with_navigation_case(function(remap)
			local capture = remap.capture_configured_navigation_inventory()
			helpers.assert_type(capture, "table")
			remap.TAP_HOLD_KEYS[1].id = "retired-definition"
			helpers.assert_eq(capture.current(), false)
		end)
	end)

	for _, phase in ipairs({ "build", "deploy" }) do
		helpers.it("nav-configured remap grants no receipt after actual " .. phase .. " refusal", function()
			with_navigation_case(function(remap, calls)
				local before = remap.capture_configured_navigation_inventory()
				helpers.assert_type(before, "table")
				local generator = package.loaded["platform.remap.generator"]
				local original = generator.build_karabiner_json
				if phase == "build" then generator.build_karabiner_json = function() return nil, "controlled original compiler refusal" end
				else calls.fail_deploy = true end
				local accepted = remap.regenerate()
				generator.build_karabiner_json = original; calls.fail_deploy = false
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(before.current(), false)
				helpers.assert_nil(remap.capture_configured_navigation_inventory(), "a failed or ambiguous publication gives no original-map authority")
			end)
		end)
	end

	helpers.it("nav-configured remap admits no prepared receipt inside the original deployment callback", function()
		with_navigation_case(function(remap, calls)
			local entered, during = 0, false
			calls.deploy_override = function()
				entered = entered + 1
				during = remap.capture_configured_navigation_inventory()
				return true, "owned-fixture-deployment"
			end
			local accepted, completed = calls.nav_regenerate()
			calls.deploy_override = nil
			helpers.assert_eq(entered, 1, "the original publisher actually reaches the held deployment boundary")
			helpers.assert_nil(during, "prepared input facts cannot authenticate successful publication")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(completed, true)
			helpers.assert_type(remap.capture_configured_navigation_inventory(), "table")
		end)
	end)

	helpers.it("nav-configured remap refuses source changed inside an otherwise successful deployment", function()
		with_navigation_case(function(remap, calls, _, write, _, text)
			local entered = 0
			calls.deploy_override = function()
				entered = entered + 1
				write(text:gsub("KeyJ", "KeyG"))
				return true, "owned-fixture-deployment"
			end
			local accepted, completed = calls.nav_regenerate()
			calls.deploy_override = nil
			helpers.assert_eq(entered, 1)
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(completed, true, "the original publisher's own success remains unchanged")
			helpers.assert_nil(remap.capture_configured_navigation_inventory(), "changed source cannot admit the compiled predecessor")
		end)
	end)
	helpers.it("nav-configured remap refuses actual compiler callback input mutation", function()
		with_navigation_case(function(remap, calls)
			local generator = package.loaded["platform.remap.generator"]
			local build, consumed = generator.build_karabiner_json, nil
			generator.build_karabiner_json = function(state, ...)
				state.nav_layer.registry.keys.KeyJ.karabiner.key_code = "g"
				local actual = require("platform.remap.nav_layer").build_rule(state.nav_layer.bindings, state.nav_layer.registry)
				consumed = actual.manipulators[1].from.key_code
				return build(state, ...)
			end
			local accepted, completed = calls.nav_regenerate()
			generator.build_karabiner_json = build
			helpers.assert_eq(consumed, "g", "the existing compiler callback sees the genuinely changed input")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(completed, true, "native fixture admission is preserved")
			helpers.assert_nil(remap.capture_configured_navigation_inventory(), "HS equality does not own a different compiled input")
		end)
	end)

	for _, phase in ipairs({ "prepare", "settle" }) do
	helpers.it("nav-configured " .. phase .. " predecessor read failure cannot erase a real successor", function()
		with_navigation_case(function(remap, calls)
			local original_open = io.open
			local logger = package.loaded["infra.logger"]
			local original_error, armed, entered = logger.error, false, 0
			local successor_accepted, successor_completed, successor
			logger.error = function(...)
				if armed then
					armed = false; io.open = original_open; calls.deploy_override = nil
					entered = entered + 1
					successor_accepted, successor_completed = calls.nav_regenerate()
					successor = remap.capture_configured_navigation_inventory()
				end
				return original_error(...)
			end
			local reads = 0
			local function arm_read_failure()
				armed = true
				io.open = function(path, mode)
					local handle, detail = original_open(path, mode)
					if armed and handle and mode == "r" and path:match("/config_karabiner%.toml$") then
						reads = reads + 1
						if phase == "prepare" and reads ~= 4 then return handle, detail end
						return { read = function(_, ...) return handle:read(...) end,
							close = function() assert(handle:close()); return false, "controlled real read close refusal" end }
					end
					return handle, detail
				end
			end
			if phase == "prepare" then arm_read_failure()
			else calls.deploy_override = function() arm_read_failure(); return true, "owned-fixture-deployment" end end
			local invoked, accepted, completed = pcall(calls.nav_regenerate)
			io.open = original_open; logger.error = original_error; calls.deploy_override = nil
			helpers.assert_eq(invoked, true)
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(completed, true)
			helpers.assert_eq(entered, 1, "a genuine original FileSystem failure invokes the diagnostic callback")
			helpers.assert_eq(successor_accepted, true)
			helpers.assert_eq(successor_completed, true, "the successor reaches its original final publication fence")
			helpers.assert_type(successor, "table")
			helpers.assert_eq(successor.current(), true)
			helpers.assert_type(remap.capture_configured_navigation_inventory(), "table", "the predecessor cannot clear the successor receipt")
		end)
	end)

	end
	helpers.it("nav-configured off-to-on joins the exact original acknowledged enable publication", function()
		with_navigation_case(function(remap, calls)
			helpers.assert_nil(remap.capture_configured_navigation_inventory())
			local terminal, reason
			local accepted = remap.set_enabled(true, function(ok, detail) terminal, reason = ok, detail end)
			if calls.start_paused_callback ~= nil then calls.deliver_ready(true, "owned-fixture-ready") end
			if #calls.resume_callbacks > 0 then calls.deliver_resumed(true, "owned-fixture-resumed") end
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(terminal, true, "the original enable must actually complete: " .. tostring(reason))
			local inventory = remap.capture_configured_navigation_inventory()
			helpers.assert_type(inventory, "table", "the original write receipt owns the new enabled bytes")
			helpers.assert_eq(inventory.codes, { 38 })
			helpers.assert_eq(inventory.current(), true)
		end, '[karabiner]\nintegration_enabled = false\n[tap_holds]\nenabled = true\n[tap_holds.config.left_shift]\nhold = "layer"\n', nil, true)
	end)

	for _, phase in ipairs({ "before_ready", "before_resumed" }) do
		helpers.it("nav-configured enable refuses external settings replacement " .. phase, function()
			with_navigation_case(function(remap, calls, write, _, _, _, path)
				local terminal, reason
				local accepted = remap.set_enabled(true, function(ok, detail) terminal, reason = ok, detail end)
				local function replace()
					local stream = assert(io.open(path, "rb")); local content = assert(stream:read("*a")); assert(stream:close())
					write(content .. "# independent enable-time successor\n")
				end
				if phase == "before_ready" then replace() end
				if calls.start_paused_callback ~= nil then calls.deliver_ready(true, "owned-fixture-ready") end
				if phase == "before_resumed" then replace() end
				if #calls.resume_callbacks > 0 then calls.deliver_resumed(true, "owned-fixture-resumed") end
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(terminal, true, "original native enable admission is unchanged: " .. tostring(reason))
				helpers.assert_nil(remap.capture_configured_navigation_inventory(), "a later read cannot replace the original compile/write source custody")
			end, '[karabiner]\nintegration_enabled = false\n[tap_holds]\nenabled = true\n[tap_holds.config.left_shift]\nhold = "layer"\n', nil, true)
		end)
	end

end)
