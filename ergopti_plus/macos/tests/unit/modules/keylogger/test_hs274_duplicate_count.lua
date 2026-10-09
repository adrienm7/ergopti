--- tests/unit/modules/keylogger/test_hs274_duplicate_count.lua

--- ==============================================================================
--- MODULE: HS-274 — a remapped tap and its physical key
--- DESCRIPTION:
--- Ported from docs/audits/hammerspoon/2026_09_08/proofs/duplicate-count.lua,
--- driving the real keylogger keyDown and flagsChanged branches and the real
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
local Accounting = require("tests.support.hs274_accounting_fixture")

-- macOS virtual keycodes of the shipped CapsLock tap (tap = Return).
local KEYCODE_CAPS_LOCK = 57
local KEYCODE_RETURN = 36
-- The left Command modifier, a flagsChanged key.
local KEYCODE_LEFT_COMMAND = 55

--- Returns the meta.kc of the only recorded typing event.
--- @param scenario table HS-274 accounting scenario.
--- @return number|nil kc
local function only_typing_kc(scenario)
	local events = scenario.typing_events()
	helpers.assert_eq(#events, 1, "the key must produce exactly one typing event")
	return events[1][3].kc
end





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
			local keylogger = package.loaded["modules.keylogger.init"]
			local paused = false
			local control = { is_paused = function() return paused end }
			scenario.state.is_enabled = false
			helpers.assert_eq(keylogger.start(control), true)
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
			package.loaded["modules.keylogger.context_tracker"].resync_context = function() return true end
			helpers.assert_eq(keylogger.resync_context(), true)
			scenario.flags_changed(55, { cmd = true })
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 3)
			helpers.assert_eq(keylogger.stop(), true)
			helpers.assert_eq(keylogger.start(control), true)
			helpers.assert_true(rawequal(package.loaded["modules.keylogger.init"], keylogger))
			helpers.assert_eq(scenario.mode.bind_settlement({}, function() return true end), false)
			scenario.mode.select_stream(Accounting.STREAM_OWNER)
			scenario.mode.release(Accounting.STREAM_OWNER)
			helpers.assert_eq(keylogger.stop(), true)
			end, debug.traceback)
			_G.hs.caffeinate = previous_caffeinate
			if not called then error(failure, 0) end
		end)
	end)
	helpers.it("(wp3-held) restores independent fixture parent and child identities", function()
		local original_mode = package.loaded["modules.keylogger.physical_accounting_mode"]
		local original_logger = package.loaded["modules.keylogger.init"]
		local first_mode, first_state
		Accounting.run(function(scenario)
			first_mode, first_state = scenario.mode, scenario.state
			scenario.flags_changed(55, { cmd = true })
			scenario.mode.select_stream(Accounting.STREAM_OWNER)
		end)
		helpers.assert_true(rawequal(package.loaded["modules.keylogger.physical_accounting_mode"], original_mode))
		helpers.assert_true(rawequal(package.loaded["modules.keylogger.init"], original_logger))
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
		helpers.assert_true(rawequal(package.loaded["modules.keylogger.physical_accounting_mode"], original_mode))
		helpers.assert_true(rawequal(package.loaded["modules.keylogger.init"], original_logger))
	end)
	helpers.it("(wp3-held) reloads only the actual keylogger's settlement child", function()
		local previous_mode = package.loaded["modules.keylogger.physical_accounting_mode"]
		Accounting.run(function(scenario)
			scenario.flags_changed(55, { cmd = true })
			scenario.mode.select_stream(Accounting.STREAM_OWNER)
			local fixture = require("tests.support.keylogger_provenance_fixture").load_keylogger()
			local mode = require("modules.keylogger.physical_accounting_mode")
			helpers.assert_true(not rawequal(mode, scenario.mode))
			helpers.assert_true(not rawequal(fixture.state, scenario.state))
			helpers.assert_eq(fixture.state.modifier_suppressed_releases, {})
			helpers.assert_eq(mode.select_stream(Accounting.STREAM_OWNER), true)
			helpers.assert_eq(mode.release(Accounting.STREAM_OWNER), true)
			helpers.load_with_stubs("hs")
			helpers.assert_true(rawequal(package.loaded["modules.keylogger.physical_accounting_mode"], mode),
				"an unrelated parent must retain the process bookkeeping owner")
		end)
		helpers.assert_true(rawequal(package.loaded["modules.keylogger.physical_accounting_mode"], previous_mode))
	end)
end)
