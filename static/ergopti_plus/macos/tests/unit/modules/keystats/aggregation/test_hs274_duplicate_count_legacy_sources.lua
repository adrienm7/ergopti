--- tests/unit/modules/keystats/aggregation/test_hs274_duplicate_count_legacy_sources.lua

--- ==============================================================================
--- MODULE: HS-274 — a remapped tap and its physical key
--- DESCRIPTION:
--- Ported from docs/audits/hammerspoon/2026_09_08/proofs/duplicate-count.lua,
--- driving the real keystats keyDown and flagsChanged branches and the real
--- aggregator instead of a stubbed classifier.
---
--- ROOT CAUSE ENCODED:
--- Two independent writers credit a managed tap-hold. The Karabiner
--- shell_command ledger credits the physical key (karabiner_press), and the
--- Quartz event tap credits the remapped output it observes (meta.kc). The
--- historical guard `kc = KcBridge.is_ke_managed_output_kc(keycode) and nil or
--- keycode` always evaluated to keycode, because `true and nil` is nil and
--- `nil or keycode` is keycode, so every remapped tap is credited twice. With the
--- shipped defaults, one CapsLock tap (tap = Return) credits CapsLock AND Return.
---
--- The legacy cases pin today's behaviour, double count included: fixing it by
--- suppressing the output keycode would lose real presses (see
--- test_hs274_physical_collision.lua). The stream cases prove the fix that
--- physical_accounting_mode.lua enables: while a complete capture is admitted,
--- neither the event tap nor the ledger credits anything, so each physical press
--- is credited once, by the stream. Restoring the `and nil or keycode` idiom
--- fails them, and so does any fallback to the legacy sources during a gap.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.keystats.aggregation.hs274_duplicate_count_fixture"] = nil
local Fixture = require("tests.support.modules.keystats.aggregation.hs274_duplicate_count_fixture")
local Accounting = Fixture.Accounting
local KEYCODE_CAPS_LOCK = Fixture.KEYCODE_CAPS_LOCK
local KEYCODE_LEFT_COMMAND = Fixture.KEYCODE_LEFT_COMMAND
local KEYCODE_RETURN = Fixture.KEYCODE_RETURN
local only_typing_kc = Fixture.only_typing_kc
local with_system_policy_callback = Fixture.with_system_policy_callback





-- =================================
-- =================================
-- ======= 1/ Legacy Sources =======
-- =================================
-- =================================

helpers.describe("HS-274 duplicate count — legacy sources", function()
	helpers.it("credits a managed tap as its physical key and as its output (documented double count)", function()
		Accounting.run(function(scenario)
			-- Even when the classifier claims Return as a managed output, the
			-- legacy writer keeps crediting it: suppression is not the fix.
			scenario.kc_bridge.is_ke_managed_output_kc = function() return true end
			scenario.ledger_press(KEYCODE_CAPS_LOCK)
			scenario.key_down(KEYCODE_RETURN, "\r")
			helpers.assert_eq(only_typing_kc(scenario), KEYCODE_RETURN)
			helpers.assert_eq(scenario.counts(), { [KEYCODE_CAPS_LOCK] = 1, [KEYCODE_RETURN] = 1 },
				"one physical CapsLock tap is credited twice while the legacy sources own accounting")
		end)
	end)

	helpers.it("credits an ordinary key exactly once", function()
		Accounting.run(function(scenario)
			scenario.key_down(0, "a")
			helpers.assert_eq(only_typing_kc(scenario), 0)
			helpers.assert_eq(scenario.counts(), { [0] = 1 })
		end)
	end)

	helpers.it("records modifier presses and holds from flagsChanged", function()
		Accounting.run(function(scenario)
			scenario.flags_changed(KEYCODE_LEFT_COMMAND, { cmd = true })
			scenario.flags_changed(KEYCODE_LEFT_COMMAND, {})
			helpers.assert_eq(#scenario.system_events, 2)
			helpers.assert_eq(scenario.system_events[1].action, "modifier_press")
			helpers.assert_eq(scenario.system_events[1].keycode, KEYCODE_LEFT_COMMAND)
			helpers.assert_eq(scenario.system_events[2].action, "modifier_hold")
			helpers.assert_eq(scenario.system_events[2].keycode, KEYCODE_LEFT_COMMAND)
		end)
	end)
end)





-- ===================================
-- ===================================
-- ======= 2/ Exclusive Stream =======
-- ===================================
-- ===================================

helpers.describe("HS-274 duplicate count — admitted producer stream", function()
	helpers.it("credits a managed tap once, from the stream's physical key", function()
		Accounting.run(function(scenario)
			scenario.admit_stream()
			scenario.stream_press(KEYCODE_CAPS_LOCK)
			scenario.key_down(KEYCODE_RETURN, "\r")
			helpers.assert_eq(only_typing_kc(scenario), nil,
				"the event tap must not credit the remapped output while a capture is admitted")
			helpers.assert_eq(scenario.typing_events()[1][1], "[ENTER]",
				"the logical text of the output is still recorded")
			helpers.assert_eq(scenario.counts(), { [KEYCODE_CAPS_LOCK] = 1 })
		end)
	end)

	helpers.it("credits an ordinary key only through the stream", function()
		Accounting.run(function(scenario)
			scenario.admit_stream()
			scenario.stream_press(0)
			scenario.key_down(0, "a")
			helpers.assert_eq(only_typing_kc(scenario), nil)
			helpers.assert_eq(scenario.typing_events()[1][1], "a")
			helpers.assert_eq(scenario.counts(), { [0] = 1 })
		end)
	end)

	helpers.it("stops modifier presses and holds while keeping their bookkeeping", function()
		Accounting.run(function(scenario)
			scenario.admit_stream()
			scenario.flags_changed(KEYCODE_LEFT_COMMAND, { cmd = true })
			helpers.assert_true(scenario.state.modifier_down_at[KEYCODE_LEFT_COMMAND] ~= nil,
				"the press must still be tracked so a later hold is not inverted")
			scenario.flags_changed(KEYCODE_LEFT_COMMAND, {})
			helpers.assert_eq(scenario.state.modifier_down_at[KEYCODE_LEFT_COMMAND], nil)
			helpers.assert_eq(#scenario.system_events, 0,
				"flagsChanged must credit no modifier while a capture is admitted")
		end)
	end)

	helpers.it("closes the Karabiner ledger, which is open under the legacy sources", function()
		Accounting.run(function(scenario)
			helpers.assert_eq(scenario.ledger_may_persist(), true)
			scenario.admit_stream()
			helpers.assert_eq(scenario.ledger_may_persist(), false)
		end)
	end)
end)





-- =====================================
-- =====================================
-- ======= 3/ No Silent Fallback =======
-- =====================================
-- =====================================

helpers.describe("HS-274 duplicate count — gaps never fall back", function()
	helpers.it("credits nothing while a selected stream has no admitted capture", function()
		Accounting.run(function(scenario)
			scenario.mode.select_stream(Accounting.STREAM_OWNER)
			scenario.ledger_press(KEYCODE_CAPS_LOCK)
			scenario.key_down(KEYCODE_RETURN, "\r")
			helpers.assert_eq(only_typing_kc(scenario), nil)
			helpers.assert_eq(scenario.ledger_may_persist(), false)
			scenario.flags_changed(KEYCODE_LEFT_COMMAND, { cmd = true })
			helpers.assert_eq(#scenario.system_events, 0)
		end)
	end)

	helpers.it("keeps the gap for fixture-only coverage and after a lost capture", function()
		Accounting.run(function(scenario)
			local mode = scenario.mode
			mode.select_stream(Accounting.STREAM_OWNER)
			helpers.assert_eq(mode.admit(Accounting.STREAM_OWNER, Accounting.STREAM_CAPTURE,
				"fixture_only"), false)
			scenario.key_down(0, "a")
			helpers.assert_eq(mode.admit(Accounting.STREAM_OWNER, Accounting.STREAM_CAPTURE,
				mode.COMPLETE_COVERAGE), true)
			mode.interrupt(Accounting.STREAM_OWNER, Accounting.STREAM_CAPTURE)
			scenario.key_down(1, "s")
			local events = scenario.typing_events()
			helpers.assert_eq(#events, 2)
			helpers.assert_eq(events[1][3].kc, nil, "fixture-only coverage must stay a gap")
			helpers.assert_eq(events[2][3].kc, nil, "a lost capture must stay a gap")
			helpers.assert_eq(scenario.ledger_may_persist(), false)
		end)
	end)

	helpers.it("returns to the legacy sources only on the owner's explicit release", function()
		Accounting.run(function(scenario)
			scenario.admit_stream()
			scenario.mode.release(Accounting.STREAM_OWNER)
			scenario.key_down(0, "a")
			helpers.assert_eq(only_typing_kc(scenario), 0)
			helpers.assert_eq(scenario.ledger_may_persist(), true)
		end)
	end)
end)

helpers.describe("HS-274 held modifier source settlement (wp3)", function()
	local sides = { 54, 55, 56, 60, 58, 61, 59, 62 }
	local side_flags = {
		[54] = "cmd", [55] = "cmd", [56] = "shift", [60] = "shift",
		[58] = "alt", [61] = "alt", [59] = "ctrl", [62] = "ctrl",
	}
	local function held_flags(keycode) return { [side_flags[keycode]] = true } end
	for _, keycode in ipairs(sides) do
		helpers.it("(wp3-held) suppresses the crossing release of legacy modifier " .. keycode, function()
			Accounting.run(function(scenario)
				scenario.flags_changed(keycode, held_flags(keycode))
				helpers.assert_eq(#scenario.system_events, 1)
				scenario.mode.select_stream(Accounting.STREAM_OWNER)
				helpers.assert_eq(scenario.state.modifier_down_at[keycode], nil)
				helpers.assert_eq(scenario.state.modifier_suppressed_releases[keycode], true)
				scenario.mode.admit(Accounting.STREAM_OWNER, Accounting.STREAM_CAPTURE, scenario.mode.COMPLETE_COVERAGE)
				scenario.mode.interrupt(Accounting.STREAM_OWNER, Accounting.STREAM_CAPTURE)
				scenario.mode.release(Accounting.STREAM_OWNER)
				scenario.mode.select_stream("successor")
				scenario.mode.release("successor")
				scenario.flags_changed(keycode, {})
				helpers.assert_eq(#scenario.system_events, 1, "the old release is neither a new press nor a hold")
				helpers.assert_eq(scenario.state.modifier_down_at[keycode], nil)
				helpers.assert_eq(scenario.state.modifier_suppressed_releases[keycode], nil)
				scenario.flags_changed(keycode, held_flags(keycode))
				scenario.flags_changed(keycode, {})
				helpers.assert_eq(#scenario.system_events, 3)
				helpers.assert_eq(scenario.system_events[2].action, "modifier_press")
				helpers.assert_eq(scenario.system_events[3].action, "modifier_hold")
			end)
		end)
		helpers.it("(wp3-held) never credits an orphan gap hold for modifier " .. keycode, function()
			Accounting.run(function(scenario)
				scenario.mode.select_stream(Accounting.STREAM_OWNER)
				scenario.flags_changed(keycode, held_flags(keycode))
				scenario.mode.release(Accounting.STREAM_OWNER)
				scenario.flags_changed(keycode, {})
				helpers.assert_eq(#scenario.system_events, 0)
				helpers.assert_eq(scenario.state.modifier_down_at[keycode], nil)
				scenario.flags_changed(keycode, held_flags(keycode))
				scenario.flags_changed(keycode, {})
				helpers.assert_eq(#scenario.system_events, 2)
				helpers.assert_eq(scenario.system_events[1].action, "modifier_press")
				helpers.assert_eq(scenario.system_events[2].action, "modifier_hold")
			end)
		end)
	end
	helpers.it("(wp3-held) keeps all eight held sides through admission and interruption", function()
		Accounting.run(function(scenario)
			scenario.mode.select_stream(Accounting.STREAM_OWNER)
			for _, keycode in ipairs(sides) do scenario.flags_changed(keycode, held_flags(keycode)) end
			scenario.mode.admit(Accounting.STREAM_OWNER, Accounting.STREAM_CAPTURE, scenario.mode.COMPLETE_COVERAGE)
			scenario.mode.interrupt(Accounting.STREAM_OWNER, Accounting.STREAM_CAPTURE)
			scenario.mode.release(Accounting.STREAM_OWNER)
			for _, keycode in ipairs(sides) do scenario.flags_changed(keycode, {}) end
			helpers.assert_eq(#scenario.system_events, 0)
			helpers.assert_eq(scenario.state.modifier_down_at, {})
			helpers.assert_eq(scenario.state.modifier_suppressed_releases, {})
		end)
	end)
	helpers.it("(wp3-held) refuses malformed held state without changing tables or source", function()
		Accounting.run(function(scenario)
			local held = { [55] = "unknown timestamp" }
			local suppressed = scenario.state.modifier_suppressed_releases
			scenario.state.modifier_down_at = held
			local accepted, reason = scenario.mode.select_stream(Accounting.STREAM_OWNER)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(reason, "settlement_refused")
			helpers.assert_true(rawequal(scenario.state.modifier_down_at, held))
			helpers.assert_true(rawequal(scenario.state.modifier_suppressed_releases, suppressed))
			helpers.assert_eq(scenario.mode.credit_source(), scenario.mode.SOURCE_LEGACY)
		end)
	end)
	helpers.it("(wp3-held) retires a secure-field crossing release without recording it", function()
		Accounting.run(function(scenario)
			scenario.flags_changed(55, { cmd = true })
			scenario.mode.select_stream(Accounting.STREAM_OWNER)
			scenario.mode.release(Accounting.STREAM_OWNER)
			scenario.state.is_secure_field = true
			scenario.flags_changed(55, {})
			helpers.assert_eq(scenario.state.modifier_suppressed_releases[55], nil)
			scenario.state.is_secure_field = false
			scenario.flags_changed(55, { cmd = true })
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 3)
		end)
	end)
	helpers.it("(wp3-held) retains one process owner through normal stop and restart", function()
		Accounting.run(function(scenario)
			local previous_caffeinate = _G.hs.caffeinate
			_G.hs.caffeinate = { watcher = { new = function()
				return {
					start = function(self) return self end,
					stop = function(self) return self end,
				}
			end } }
			local called, failure = xpcall(function()
			local keystats = package.loaded["modules.keystats.init"]
			local paused = false
			local control = { is_paused = function() return paused end }
			scenario.state.is_enabled = false
			helpers.assert_eq(keystats.start(control), true)
			for _, timer in ipairs(_G.hs.timer.__timers) do
				if timer.delay == 0 and timer.running then timer:fire() end
			end
			scenario.state.is_secure_field = false
			scenario.flags_changed(55, { cmd = true })
			scenario.mode.select_stream(Accounting.STREAM_OWNER)
			scenario.mode.release(Accounting.STREAM_OWNER)
			paused = true
			scenario.flags_changed(55, {})
			helpers.assert_eq(scenario.state.modifier_suppressed_releases[55], nil)
			paused = false
			package.loaded["modules.keystats.context_tracker"].resync_context = function()
				-- The healthy tracker double acknowledges the accepted fixture identity.
				scenario.state.active_app_name = "TestApp"
				scenario.state.active_app_pid = 1
				scenario.state.foreground_refresh_pending = false
				return true
			end
			helpers.assert_eq(keystats.resync_context(), true)
			scenario.flags_changed(55, { cmd = true })
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 3)
			helpers.assert_eq(keystats.stop(), true)
			helpers.assert_eq(keystats.start(control), true)
			helpers.assert_true(rawequal(package.loaded["modules.keystats.init"], keystats))
			helpers.assert_eq(scenario.mode.bind_settlement({}, function() return true end), false)
			scenario.mode.select_stream(Accounting.STREAM_OWNER)
			scenario.mode.release(Accounting.STREAM_OWNER)
			helpers.assert_eq(keystats.stop(), true)
			end, debug.traceback)
			_G.hs.caffeinate = previous_caffeinate
			if not called then error(failure, 0) end
		end)
	end)
	helpers.it("(wp3-held) restores independent fixture parent and child identities", function()
		local original_mode = package.loaded["modules.keystats.physical_accounting_mode"]
		local original_logger = package.loaded["modules.keystats.init"]
		local first_mode, first_state
		Accounting.run(function(scenario)
			first_mode, first_state = scenario.mode, scenario.state
			scenario.flags_changed(55, { cmd = true })
			scenario.mode.select_stream(Accounting.STREAM_OWNER)
		end)
		helpers.assert_true(rawequal(package.loaded["modules.keystats.physical_accounting_mode"], original_mode))
		helpers.assert_true(rawequal(package.loaded["modules.keystats.init"], original_logger))
		Accounting.run(function(scenario)
			helpers.assert_true(not rawequal(scenario.mode, first_mode))
			helpers.assert_true(not rawequal(scenario.state, first_state))
			helpers.assert_eq(scenario.state.modifier_suppressed_releases, {})
			scenario.mode.select_stream(Accounting.STREAM_OWNER)
			scenario.mode.release(Accounting.STREAM_OWNER)
			scenario.flags_changed(55, { cmd = true })
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 2)
		end)
		helpers.assert_true(rawequal(package.loaded["modules.keystats.physical_accounting_mode"], original_mode))
		helpers.assert_true(rawequal(package.loaded["modules.keystats.init"], original_logger))
	end)
	helpers.it("(wp3-held) reloads only the actual keystats's settlement child", function()
		local previous_mode = package.loaded["modules.keystats.physical_accounting_mode"]
		Accounting.run(function(scenario)
			scenario.flags_changed(55, { cmd = true })
			scenario.mode.select_stream(Accounting.STREAM_OWNER)
			local fixture = require("tests.support.keystats_provenance_fixture").load_keystats()
			local mode = require("modules.keystats.physical_accounting_mode")
			helpers.assert_true(not rawequal(mode, scenario.mode))
			helpers.assert_true(not rawequal(fixture.state, scenario.state))
			helpers.assert_eq(fixture.state.modifier_suppressed_releases, {})
			helpers.assert_eq(mode.select_stream(Accounting.STREAM_OWNER), true)
			helpers.assert_eq(mode.release(Accounting.STREAM_OWNER), true)
			helpers.load_with_stubs("hs")
			helpers.assert_true(rawequal(package.loaded["modules.keystats.physical_accounting_mode"], mode),
				"an unrelated parent must retain the process bookkeeping owner")
		end)
		helpers.assert_true(rawequal(package.loaded["modules.keystats.physical_accounting_mode"], previous_mode))
	end)
end)

-- Independently frozen SEC004/SEC005/opt-out and whole-interval vectors.
local system_modifier_vectors = {
	{ id = "com.apple.SecurityAgent:disabled_filter_keeps_full_included_interval", auth_bundle_id = "com.apple.SecurityAgent", initial_system_filter = false, startup_application = "auth", steps = { "down55@1000", "activate_ordinary@2000", "activate_auth@4000", "up55@7000", "down55@8000", "up55@9000" }, expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } } },
	{ id = "com.apple.SecurityAgent:enabling_while_held_cancels_whole_interval", auth_bundle_id = "com.apple.SecurityAgent", initial_system_filter = false, startup_application = "auth", steps = { "down55@1000", "system(true)@3000", "activate_ordinary@4000", "up55@7000", "down55@8000", "up55@9000" }, expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } } },
	{ id = "com.apple.SecurityAgent:disable_then_reenable_same_auth_context_cancels_whole_interval", auth_bundle_id = "com.apple.SecurityAgent", initial_system_filter = true, startup_application = "auth", steps = { "system(false)@1000", "down55@1000", "system(true)@3000", "activate_ordinary@4000", "up55@7000", "down55@8000", "up55@9000" }, expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } } },
	{ id = "com.apple.CoreAuthUI:disabled_filter_keeps_full_included_interval", auth_bundle_id = "com.apple.CoreAuthUI", initial_system_filter = false, startup_application = "auth", steps = { "down55@1000", "activate_ordinary@2000", "activate_auth@4000", "up55@7000", "down55@8000", "up55@9000" }, expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } } },
	{ id = "com.apple.CoreAuthUI:enabling_while_held_cancels_whole_interval", auth_bundle_id = "com.apple.CoreAuthUI", initial_system_filter = false, startup_application = "auth", steps = { "down55@1000", "system(true)@3000", "activate_ordinary@4000", "up55@7000", "down55@8000", "up55@9000" }, expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } } },
	{ id = "com.apple.CoreAuthUI:disable_then_reenable_same_auth_context_cancels_whole_interval", auth_bundle_id = "com.apple.CoreAuthUI", initial_system_filter = true, startup_application = "auth", steps = { "system(false)@1000", "down55@1000", "system(true)@3000", "activate_ordinary@4000", "up55@7000", "down55@8000", "up55@9000" }, expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } } },
	{ id = "ordinary_context_is_not_excluded_by_auth_policy", auth_bundle_id = "com.apple.SecurityAgent", initial_system_filter = true, startup_application = "ordinary", steps = { "down55@1000", "system(false)@2000", "system(true)@3000", "up55@7000", "down55@8000", "up55@9000" }, expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } } },
}

-- Composition limit: Accounting constructs the real event consumer with its
-- tracker double. The exact retained startup ports forward to a REAL tracker
-- BEFORE actual keystats.start. The real registered activation supplies context;
-- application/AX/persistence ports are doubles, not native authentication proof.

helpers.describe("HS-274 held modifier actual system-auth policy writer (wp3)", function()
	for _, vector in ipairs(system_modifier_vectors) do
		helpers.it("(wp3-system-policy) " .. vector.id, function()
			with_system_policy_callback(vector, function(scenario, controls, keystats)
				for _, step in ipairs(vector.steps) do
					local command, at = step:match("^(.-)@(%d+)$")
					helpers.assert_eq(type(command), "string")
					controls.clock_ms = tonumber(at)
					if command == "activate_auth" then controls.activate("auth")
					elseif command == "activate_ordinary" then controls.activate("ordinary")
					elseif command == "down55" or command == "up55" then
						local prior, allowed = #scenario.system_events, keystats.context_allows_logging()
						scenario.flags_changed(55, command == "down55" and { cmd = true } or {})
						if not allowed then helpers.assert_eq(#scenario.system_events, prior) end
					else
						local value = command:match("^system%((%a+)%)$")
						helpers.assert_true(value == "true" or value == "false")
						keystats.set_system_auth_filter_enabled(value == "true")
						helpers.assert_eq(scenario.state.system_auth_filter_enabled, value == "true")
						helpers.assert_eq(scenario.state.is_secure_field, false)
						helpers.assert_eq(scenario.state.is_private_window, false)
						helpers.assert_eq(keystats.context_allows_logging(), controls.current_app:bundleID() == "test.editor" or value == "false")
					end
				end
				local actual = {}
				for _, event in ipairs(scenario.system_events) do actual[#actual + 1] = { event.action, event.keycode, event.hold_ms } end
				helpers.assert_eq(actual, vector.expected)
				helpers.assert_eq(scenario.state.modifier_down_at, {})
				helpers.assert_eq(scenario.state.modifier_suppressed_releases, {})
			end)
		end)
	end
end)

-- Independent frozen fault injection: only held/marker maps change, never privacy state.
helpers.describe("Root backport auth setter exact cancellation debt", function()
	for _, fault in ipairs({ "held", "marker" }) do
		helpers.it("malformed " .. fault .. " debt refuses both auth writes and all public accounting until exact retry", function()
			local vector = { auth_bundle_id = "com.apple.SecurityAgent", initial_system_filter = false, startup_application = "auth" }
			with_system_policy_callback(vector, function(scenario, controls, keystats)
				controls.clock_ms = 1000
				scenario.flags_changed(55, { cmd = true })
				helpers.assert_eq(scenario.state.modifier_down_at[55], 1000)
				local held_before, suppressed_before = {}, {}
				for key, value in pairs(scenario.state.modifier_down_at) do held_before[key] = value end
				for key, value in pairs(scenario.state.modifier_suppressed_releases) do suppressed_before[key] = value end
				if fault == "held" then scenario.state.modifier_down_at[55] = "invalid"
				else scenario.state.modifier_suppressed_releases[54] = "invalid" end
				controls.clock_ms = 3000
				local enabled = pcall(keystats.set_system_auth_filter_enabled, true)
				helpers.assert_eq(enabled, false, "malformed pure settlement must refuse public enable")
				helpers.assert_eq(scenario.state.system_auth_filter_enabled, true)
				helpers.assert_eq(keystats.context_allows_logging(), false)
				local disabled = pcall(keystats.set_system_auth_filter_enabled, false)
				helpers.assert_eq(disabled, false, "effective permission cannot bypass unfinished cancellation")
				helpers.assert_eq(scenario.state.system_auth_filter_enabled, false)
				helpers.assert_eq(scenario.state.is_secure_field, false)
				helpers.assert_eq(scenario.state.is_private_window, false)
				helpers.assert_eq(keystats.context_allows_logging(), false)
				helpers.assert_eq(keystats.may_persist(), false)
				local events_before, buffer_before = #scenario.system_events, scenario.state.buffer
				helpers.assert_eq(type(scenario.state.buffer_text), "string")
				helpers.assert_eq(type(scenario.state.buffer_events), "table")
				helpers.assert_eq(type(scenario.state.rich_chunks), "table")
				local text_before = scenario.state.buffer_text
				local typing_before, rich_before = #scenario.state.buffer_events, #scenario.state.rich_chunks
				local wpm_before = #scenario.state.recent_typing_eff
				controls.clock_ms = 4000
				scenario.flags_changed(55, {})
				local synthetic_result = keystats.notify_synthetic("synthetic fixture", "hotstring", 0)
				helpers.assert_nil(synthetic_result, "denied public sink must not enqueue accepted synthetic work")
				helpers.assert_eq(#scenario.system_events, events_before)
				helpers.assert_eq(scenario.state.buffer, buffer_before)
				helpers.assert_eq(scenario.state.buffer_text, text_before)
				helpers.assert_eq(#scenario.state.buffer_events, typing_before)
				helpers.assert_eq(#scenario.state.rich_chunks, rich_before)
				helpers.assert_eq(#scenario.state.recent_typing_eff, wpm_before)
				-- Restore the exact independent observation, not a computed expectation.
				scenario.state.modifier_down_at = held_before
				scenario.state.modifier_suppressed_releases = suppressed_before
				local recovered, recovery_result = pcall(keystats.set_system_auth_filter_enabled, false)
				helpers.assert_eq(recovered, true)
				helpers.assert_nil(recovery_result)
				helpers.assert_eq(keystats.context_allows_logging(), true)
				helpers.assert_eq(scenario.state.modifier_down_at, {})
				helpers.assert_eq(scenario.state.modifier_suppressed_releases[55], true)
				controls.clock_ms = 7000
				scenario.flags_changed(55, {})
				controls.clock_ms = 8000
				scenario.flags_changed(55, { cmd = true })
				controls.clock_ms = 9000
				scenario.flags_changed(55, {})
				local actual = {}
				for _, event in ipairs(scenario.system_events) do actual[#actual + 1] = { event.action, event.keycode, event.hold_ms } end
				helpers.assert_eq(actual, { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } })
				helpers.assert_eq(scenario.state.modifier_down_at, {})
				helpers.assert_eq(scenario.state.modifier_suppressed_releases, {})
			end)
		end)
	end
end)
