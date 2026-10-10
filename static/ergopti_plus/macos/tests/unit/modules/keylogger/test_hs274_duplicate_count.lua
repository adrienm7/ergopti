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

helpers.describe("HS-274 held modifier pause settlement (wp3)", function()
	local sides = { 54, 55, 56, 60, 58, 61, 59, 62, 63 }
	local side_flags = {
		[54] = "cmd", [55] = "cmd", [56] = "shift", [60] = "shift",
		[58] = "alt", [61] = "alt", [59] = "ctrl", [62] = "ctrl", [63] = "fn",
	}
	local function held_flags(keycode) return { [side_flags[keycode]] = true } end

	--- Runs the existing accounting fixture with the real keylogger lifecycle.
	--- Only the native watchers and the context refresh result are existing doubles.
	--- @param body function Scenario receiving physical events and pause controls.
	local function with_pause(body)
		Accounting.run(function(scenario)
			local previous_caffeinate = _G.hs.caffeinate
			_G.hs.caffeinate = { watcher = { new = function()
				return {
					start = function(self) return self end,
					stop = function(self) return self end,
				}
			end } }
			local keylogger = package.loaded["modules.keylogger.init"]
			local paused = false
			local control = { is_paused = function() return paused end }
			local called, failure = xpcall(function()
				scenario.state.is_enabled = false
				helpers.assert_eq(keylogger.start(control), true)
				for _, timer in ipairs(_G.hs.timer.__timers) do
					if timer.delay == 0 and timer.running then timer:fire() end
				end
				scenario.state.is_secure_field = false
				package.loaded["modules.keylogger.context_tracker"].resync_context = function() return true end
				local function pause() paused = true end
				local function resume()
					-- ScriptControl performs this refresh before its final pause-state commit.
					helpers.assert_eq(paused, true)
					helpers.assert_eq(keylogger.resync_context(), true)
					paused = false
				end
				body(scenario, pause, resume)
			end, debug.traceback)
			local stopped, stop_result = pcall(keylogger.stop)
			_G.hs.caffeinate = previous_caffeinate
			if not called then error(failure, 0) end
			helpers.assert_eq(stopped, true)
			helpers.assert_eq(stop_result, true)
		end)
	end

	--- Checks the complete action/keycode sequence without borrowing hold timing.
	--- @param scenario table Existing accounting scenario.
	--- @param expected table Literal ordered action/keycode pairs.
	local function assert_events(scenario, expected)
		local actual = {}
		for _, event in ipairs(scenario.system_events) do
			actual[#actual + 1] = { event.action, event.keycode }
		end
		helpers.assert_eq(actual, expected)
	end

	--- Proves that the next allowed press is a press and its release is a hold.
	--- @param scenario table Existing accounting scenario.
	--- @param keycode number Physical modifier side.
	--- @param previous number Number of earlier credited events.
	local function fresh_pair(scenario, keycode, previous)
		scenario.flags_changed(keycode, held_flags(keycode))
		helpers.assert_eq(#scenario.system_events, previous + 1)
		helpers.assert_eq(scenario.system_events[previous + 1].action, "modifier_press")
		helpers.assert_eq(scenario.system_events[previous + 1].keycode, keycode)
		scenario.flags_changed(keycode, {})
		helpers.assert_eq(#scenario.system_events, previous + 2)
		helpers.assert_eq(scenario.system_events[previous + 2].action, "modifier_hold")
		helpers.assert_eq(scenario.system_events[previous + 2].keycode, keycode)
		helpers.assert_eq(scenario.state.modifier_down_at[keycode], nil)
		helpers.assert_eq(scenario.state.modifier_suppressed_releases[keycode], nil)
	end

	for _, keycode in ipairs(sides) do
		helpers.it("(wp3-pause) suppresses an existing hold across resume for side " .. keycode, function()
			with_pause(function(scenario, pause, resume)
				scenario.flags_changed(keycode, held_flags(keycode))
				helpers.assert_eq(#scenario.system_events, 1)
				pause()
				resume()
				helpers.assert_eq(scenario.state.modifier_down_at[keycode], nil)
				helpers.assert_eq(scenario.state.modifier_suppressed_releases[keycode], true)
				scenario.flags_changed(keycode, {})
				helpers.assert_eq(#scenario.system_events, 1, "crossing release emits neither press nor hold")
				fresh_pair(scenario, keycode, 1)
				assert_events(scenario, {
					{ "modifier_press", keycode }, { "modifier_press", keycode }, { "modifier_hold", keycode },
				})
			end)
		end)

		helpers.it("(wp3-pause) retires an observed release before resume for side " .. keycode, function()
			with_pause(function(scenario, pause, resume)
				scenario.flags_changed(keycode, held_flags(keycode))
				pause()
				scenario.flags_changed(keycode, {})
				helpers.assert_eq(#scenario.system_events, 1, "paused release produces no telemetry")
				helpers.assert_eq(scenario.state.modifier_down_at[keycode], nil)
				helpers.assert_eq(scenario.state.modifier_suppressed_releases[keycode], nil)
				resume()
				fresh_pair(scenario, keycode, 1)
				assert_events(scenario, {
					{ "modifier_press", keycode }, { "modifier_press", keycode }, { "modifier_hold", keycode },
				})
			end)
		end)

		helpers.it("(wp3-pause) cancels a new paused hold across resume for side " .. keycode, function()
			with_pause(function(scenario, pause, resume)
				pause()
				scenario.flags_changed(keycode, held_flags(keycode))
				helpers.assert_eq(#scenario.system_events, 0)
				helpers.assert_eq(scenario.state.modifier_down_at[keycode], nil)
				resume()
				helpers.assert_eq(scenario.state.modifier_suppressed_releases[keycode], true)
				scenario.flags_changed(keycode, {})
				helpers.assert_eq(#scenario.system_events, 0, "release cannot invent the excluded press")
				fresh_pair(scenario, keycode, 0)
				assert_events(scenario, { { "modifier_press", keycode }, { "modifier_hold", keycode } })
			end)
		end)

		helpers.it("(wp3-pause) forgets a complete excluded pair for side " .. keycode, function()
			with_pause(function(scenario, pause, resume)
				pause()
				scenario.flags_changed(keycode, held_flags(keycode))
				scenario.flags_changed(keycode, {})
				helpers.assert_eq(#scenario.system_events, 0)
				helpers.assert_eq(scenario.state.modifier_down_at[keycode], nil)
				helpers.assert_eq(scenario.state.modifier_suppressed_releases[keycode], nil)
				resume()
				fresh_pair(scenario, keycode, 0)
				assert_events(scenario, { { "modifier_press", keycode }, { "modifier_hold", keycode } })
			end)
		end)

		helpers.it("(wp3-pause) separates a paused release and new press for side " .. keycode, function()
			with_pause(function(scenario, pause, resume)
				scenario.flags_changed(keycode, held_flags(keycode))
				pause()
				scenario.flags_changed(keycode, {})
				helpers.assert_eq(scenario.state.modifier_down_at[keycode], nil)
				scenario.flags_changed(keycode, held_flags(keycode))
				helpers.assert_eq(#scenario.system_events, 1)
				helpers.assert_eq(scenario.state.modifier_down_at[keycode], nil)
				resume()
				scenario.flags_changed(keycode, {})
				helpers.assert_eq(#scenario.system_events, 1)
				fresh_pair(scenario, keycode, 1)
				assert_events(scenario, {
					{ "modifier_press", keycode }, { "modifier_press", keycode }, { "modifier_hold", keycode },
				})
			end)
		end)
	end

	helpers.it("(wp3-pause) cancels both Command sides without a shared-flag inference", function()
		with_pause(function(scenario, pause, resume)
			scenario.flags_changed(55, { cmd = true })
			pause()
			scenario.flags_changed(54, { cmd = true })
			helpers.assert_eq(#scenario.system_events, 1)
			resume()
			scenario.flags_changed(55, { cmd = true })
			helpers.assert_eq(#scenario.system_events, 1)
			scenario.flags_changed(54, {})
			helpers.assert_eq(#scenario.system_events, 1)
			helpers.assert_eq(scenario.state.modifier_down_at, {})
			helpers.assert_eq(scenario.state.modifier_suppressed_releases, {})
			fresh_pair(scenario, 55, 1)
			assert_events(scenario, {
				{ "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55 },
			})
		end)
	end)

	helpers.it("(wp3-pause) retires only the released Command side before resume", function()
		with_pause(function(scenario, pause, resume)
			scenario.flags_changed(54, { cmd = true })
			scenario.flags_changed(55, { cmd = true })
			pause()
			scenario.flags_changed(55, { cmd = true })
			helpers.assert_eq(#scenario.system_events, 2)
			helpers.assert_eq(scenario.state.modifier_down_at[55], nil)
			helpers.assert_true(type(scenario.state.modifier_down_at[54]) == "number")
			resume()
			helpers.assert_eq(scenario.state.modifier_suppressed_releases[55], nil)
			helpers.assert_eq(scenario.state.modifier_suppressed_releases[54], true)
			scenario.flags_changed(54, {})
			helpers.assert_eq(#scenario.system_events, 2)
			fresh_pair(scenario, 55, 2)
			assert_events(scenario, {
				{ "modifier_press", 54 }, { "modifier_press", 55 },
				{ "modifier_press", 55 }, { "modifier_hold", 55 },
			})
		end)
	end)
end)

-- Composition limit: Accounting constructed the real event consumer with its
-- existing ContextTracker startup double. These controls bind a fresh REAL
-- ContextTracker to that SAME CoreState and drive its registered AX callback.
-- They do not start the keylogger or prove native watcher startup/retirement.
-- Native application, AX elements, and observer methods remain boundary doubles.
helpers.describe("HS-274 held modifier actual secure callback (wp3)", function()
	local function with_secure_callback(body)
		Accounting.run(function(scenario)
			local startup_tracker = package.loaded["modules.keylogger.context_tracker"]
			local original_startup_init = startup_tracker.init
			helpers.with_fresh_modules({ "modules.keylogger.context_tracker", "adapters.secure_field_detector" }, function()
				-- Reuse the consumer's existing hs table. load_with_stubs here would
				-- manufacture another hs image after the consumer captured its own.
				local native = _G.hs
				local previous_application = native.application
				local previous_window = native.window
				local previous_ax = native.axuielement
				local previous_caffeinate = native.caffeinate
				local controls = { role_reads = 0, subrole_reads = 0, starts = 0, stops = 0 }
				local function element(role)
					return { attributeValue = function(_, name)
						if name == "AXRole" then controls.role_reads = controls.role_reads + 1; return role end
						if name == "AXSubrole" then controls.subrole_reads = controls.subrole_reads + 1; return nil end
						if name == "AXValue" then return "" end
					end }
				end
				local ordinary = element("AXTextField")
				local secure = element("AXSecureTextField")
				local app_element = { attributeValue = function(_, name)
					if name == "AXFocusedUIElement" then return ordinary end
				end }
				local app = {
					name = function() return "Editor" end,
					bundleID = function() return "test.editor" end,
					path = function() return "/Applications/Editor.app" end,
					pid = function() return 4242 end,
				}
				local window = { title = function() return "Ordinary window" end,
					isFullScreen = function() return false end }
				local observer = {
					addWatcher = function(self) return self end,
					removeWatcher = function(self) return self end,
					callback = function(self, callback) controls.callback = callback; return self end,
					start = function(self) controls.starts = controls.starts + 1; return self end,
					stop = function(self) controls.stops = controls.stops + 1; return self end,
				}
				controls.ordinary_element, controls.secure_element, controls.observer = ordinary, secure, observer
				local tracker, keylogger
				local called, failure = xpcall(function()
					native.application = { watcher = { activated = 1 }, frontmostApplication = function() return app end }
					native.window = { focusedWindow = function() return window end }
					native.axuielement = {
						applicationElementForPID = function() return app_element end,
						applicationElement = function() return app_element end,
						windowElement = function() return nil end,
						observer = { new = function() return observer end },
					}
					-- Observe the ACTUAL start boundary on the tracker object retained
					-- by the production keylogger; never author a settlement function.
					keylogger = package.loaded["modules.keylogger.init"]
					startup_tracker.init = function(state, manager, paused, settle)
						controls.startup_dependencies = { state, manager, paused, settle }
						return original_startup_init(state, manager, paused, settle)
					end
					native.caffeinate = { watcher = { new = function()
						return { start = function(self) return self end, stop = function(self) return self end }
					end } }
					scenario.state.is_enabled = false
					helpers.assert_eq(keylogger.start({ is_paused = function() return false end }), true)
					for _, timer in ipairs(native.timer.__timers) do
						if timer.delay == 0 and timer.running then timer:fire() end
					end
					local dependencies = controls.startup_dependencies
					helpers.assert_eq(type(dependencies), "table")
					helpers.assert_eq(dependencies[1], scenario.state)
					helpers.assert_eq(dependencies[2], package.loaded["modules.keylogger.log_manager"])
					helpers.assert_eq(type(dependencies[3]), "function")
					tracker = require("modules.keylogger.context_tracker")
					helpers.assert_eq(scenario.state.secure_field_filter_enabled, true)
					helpers.assert_eq(tracker.init(dependencies[1], dependencies[2], dependencies[3], dependencies[4]), true)
					helpers.assert_eq(tracker.capture_frontmost_app(), true)
					helpers.assert_eq(scenario.state.active_app_bundle, "test.editor")
					helpers.assert_eq(scenario.state.ax_observer, observer)
					helpers.assert_eq(controls.starts, 1)
					helpers.assert_eq(type(controls.callback), "function")
					local function focus(focused, expected_secure)
						local roles, subroles = controls.role_reads, controls.subrole_reads
						helpers.assert_eq(package.loaded["modules.keylogger.context_tracker"], tracker)
						helpers.assert_eq(_G.hs, native)
						helpers.assert_eq(scenario.state.ax_observer, observer)
						controls.callback(focused, "AXFocusedUIElementChanged", observer)
						helpers.assert_eq(controls.role_reads, roles + 1, "The registered callback must read the actual AX role")
						helpers.assert_eq(controls.subrole_reads, subroles + 1, "The real classifier must read the actual AX subrole")
						helpers.assert_eq(scenario.state.is_secure_field, expected_secure)
						helpers.assert_eq(keylogger.context_allows_logging(), not expected_secure)
					end
					controls.ordinary = function() focus(ordinary, false) end
					controls.secure = function() focus(secure, true) end
					controls.ordinary()
					helpers.assert_eq(#scenario.system_events, 0)
					body(scenario, controls)
				end, debug.traceback)
				-- Revoke the exact committed callback using the real owner before
				-- restoring the native ports, even if a regression assertion fails.
				local cleanup_ok, cleanup_result = true, true
				if tracker then cleanup_ok, cleanup_result = pcall(tracker.update_ax_observer, nil) end
				local stop_ok, stop_result = true, true
				if keylogger then stop_ok, stop_result = pcall(keylogger.stop) end
				startup_tracker.init = original_startup_init
				native.application = previous_application
				native.window = previous_window
				native.axuielement = previous_ax
				native.caffeinate = previous_caffeinate
				if not called then error(failure, 0) end
				helpers.assert_eq(stop_ok, true)
				helpers.assert_eq(stop_result, true)
				helpers.assert_eq(cleanup_ok, true)
				helpers.assert_eq(cleanup_result, true)
				helpers.assert_eq(controls.stops, 1)
				helpers.assert_eq(scenario.state.ax_observer, nil)
			end)
		end)
	end

	local function assert_events(scenario, expected)
		local actual = {}
		for _, event in ipairs(scenario.system_events) do actual[#actual + 1] = { event.action, event.keycode } end
		helpers.assert_eq(actual, expected)
	end

	local function fresh_pair(scenario, previous)
		scenario.flags_changed(55, { cmd = true })
		helpers.assert_eq(#scenario.system_events, previous + 1)
		helpers.assert_eq(scenario.system_events[previous + 1].action, "modifier_press")
		helpers.assert_eq(scenario.system_events[previous + 1].keycode, 55)
		scenario.flags_changed(55, {})
		helpers.assert_eq(#scenario.system_events, previous + 2)
		helpers.assert_eq(scenario.system_events[previous + 2].action, "modifier_hold")
		helpers.assert_eq(scenario.system_events[previous + 2].keycode, 55)
		helpers.assert_eq(scenario.state.modifier_down_at[55], nil)
		helpers.assert_eq(scenario.state.modifier_suppressed_releases[55], nil)
	end

	helpers.it("(wp3-secure) ordinary_pair_control", function()
		with_secure_callback(function(scenario)
			fresh_pair(scenario, 0)
			assert_events(scenario, { { "modifier_press", 55 }, { "modifier_hold", 55 } })
		end)
	end)

	helpers.it("(wp3-secure) release_inside_secure_interval_then_fresh_pair", function()
		with_secure_callback(function(scenario, context)
			scenario.flags_changed(55, { cmd = true })
			assert_events(scenario, { { "modifier_press", 55 } })
			context.secure()
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 1, "An excluded release must not emit telemetry")
			context.ordinary()
			fresh_pair(scenario, 1)
			assert_events(scenario, { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55 } })
		end)
	end)

	helpers.it("(wp3-secure) secure_interval_without_physical_transition", function()
		with_secure_callback(function(scenario, context)
			scenario.flags_changed(55, { cmd = true })
			assert_events(scenario, { { "modifier_press", 55 } })
			context.secure()
			context.ordinary()
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 1, "The whole crossing duration must be cancelled")
			fresh_pair(scenario, 1)
			assert_events(scenario, { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55 } })
		end)
	end)

	helpers.it("(wp3-secure) new_press_inside_secure_interval", function()
		with_secure_callback(function(scenario, context)
			context.secure()
			scenario.flags_changed(55, { cmd = true })
			helpers.assert_eq(#scenario.system_events, 0, "An excluded press must not emit telemetry")
			context.ordinary()
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 0, "An excluded press's crossing release must not become a new press")
			fresh_pair(scenario, 0)
			assert_events(scenario, { { "modifier_press", 55 }, { "modifier_hold", 55 } })
		end)
	end)

	helpers.it("(wp3-secure) complete_pair_inside_secure_interval_healthy", function()
		with_secure_callback(function(scenario, context)
			context.secure()
			scenario.flags_changed(55, { cmd = true })
			helpers.assert_eq(#scenario.system_events, 0)
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 0, "The complete excluded pair must not emit telemetry")
			context.ordinary()
			fresh_pair(scenario, 0)
			assert_events(scenario, { { "modifier_press", 55 }, { "modifier_hold", 55 } })
		end)
	end)

	--- Uses the shipped configuration writer while retaining classified secure state.
	--- Native clock values are fixed fixture nanoseconds, not a production deadline.
	local function with_disabled_secure_filter(body)
		with_secure_callback(function(scenario, context)
			local keylogger = package.loaded["modules.keylogger.init"]
			local timer = _G.hs.timer
			local previous_clock = timer.absoluteTime
			local previous_filter = scenario.state.secure_field_filter_enabled
			local clock = 1000000000
			local called, failure = xpcall(function()
				keylogger.set_secure_field_filter_enabled(false)
				helpers.assert_eq(scenario.state.secure_field_filter_enabled, false)
				timer.absoluteTime = function() return clock end
				context.at = function(milliseconds) clock = milliseconds * 1000000 end
				context.included_secure = function()
					local roles, subroles = context.role_reads, context.subrole_reads
					helpers.assert_eq(scenario.state.ax_observer, context.observer)
					context.callback(context.secure_element, "AXFocusedUIElementChanged", context.observer)
					helpers.assert_eq(context.role_reads, roles + 1)
					helpers.assert_eq(context.subrole_reads, subroles + 1)
					helpers.assert_eq(scenario.state.is_secure_field, true)
					helpers.assert_eq(keylogger.context_allows_logging(), true,
						"The actual disabled filter must include the genuinely classified secure field")
				end
				body(scenario, context)
			end, debug.traceback)
			timer.absoluteTime = previous_clock
			keylogger.set_secure_field_filter_enabled(previous_filter)
			if not called then error(failure, 0) end
			helpers.assert_eq(scenario.state.secure_field_filter_enabled, previous_filter)
		end)
	end

	local function assert_included_durations(scenario)
		local actual = {}
		for _, event in ipairs(scenario.system_events) do
			actual[#actual + 1] = { event.action, event.keycode, event.hold_ms }
		end
		helpers.assert_eq(actual, {
			{ "modifier_press", 55 }, { "modifier_hold", 55, 6000 },
			{ "modifier_press", 55 }, { "modifier_hold", 55, 1000 },
		})
	end

	helpers.it("(wp3-secure-policy) disabled_secure_interval_preserves_full_hold", function()
		with_disabled_secure_filter(function(scenario, context)
			context.at(1000); scenario.flags_changed(55, { cmd = true })
			assert_events(scenario, { { "modifier_press", 55 } })
			context.at(2000); context.included_secure()
			context.at(4000); context.ordinary()
			context.at(7000); scenario.flags_changed(55, {})
			assert_events(scenario, { { "modifier_press", 55 }, { "modifier_hold", 55 } })
			helpers.assert_eq(scenario.system_events[2].hold_ms, 6000,
				"A secure interval with its filter disabled must preserve the full included duration")
			context.at(8000); scenario.flags_changed(55, { cmd = true })
			context.at(9000); scenario.flags_changed(55, {})
			assert_included_durations(scenario)
			helpers.assert_eq(scenario.state.modifier_down_at[55], nil)
			helpers.assert_eq(scenario.state.modifier_suppressed_releases[55], nil)
		end)
	end)

	helpers.it("(wp3-secure-policy) disabled_secure_pair_is_included", function()
		with_disabled_secure_filter(function(scenario, context)
			context.included_secure()
			context.at(3000); scenario.flags_changed(55, { cmd = true })
			assert_events(scenario, { { "modifier_press", 55 } })
			context.at(9000); scenario.flags_changed(55, {})
			assert_events(scenario, { { "modifier_press", 55 }, { "modifier_hold", 55 } })
			helpers.assert_eq(scenario.system_events[2].hold_ms, 6000)
			context.ordinary()
			context.at(10000); scenario.flags_changed(55, { cmd = true })
			context.at(11000); scenario.flags_changed(55, {})
			assert_included_durations(scenario)
			helpers.assert_eq(scenario.state.modifier_down_at[55], nil)
			helpers.assert_eq(scenario.state.modifier_suppressed_releases[55], nil)
		end)
	end)

	local function raw_ordinary_callback(scenario, context, allowed)
		local roles, subroles = context.role_reads, context.subrole_reads
		context.callback(context.ordinary_element, "AXFocusedUIElementChanged", context.observer)
		helpers.assert_eq(context.role_reads, roles + 1)
		helpers.assert_eq(context.subrole_reads, subroles + 1)
		helpers.assert_eq(scenario.state.is_secure_field, false)
		helpers.assert_eq(package.loaded["modules.keylogger.init"].context_allows_logging(), allowed)
	end

	helpers.it("(wp3-secure-policy) actual_startup_retains_exact_settlement_hook", function()
		with_secure_callback(function(scenario, context)
			helpers.assert_eq(context.startup_dependencies[1], scenario.state)
			helpers.assert_eq(type(context.startup_dependencies[4]), "function",
				"The actual production startup must supply its own pure settlement hook")
		end)
	end)

	helpers.it("(wp3-secure-policy) enabling_filter_inside_secure_cancels_whole_hold", function()
		with_disabled_secure_filter(function(scenario, context)
			context.at(1000); scenario.flags_changed(55, { cmd = true })
			assert_events(scenario, { { "modifier_press", 55 } })
			context.at(2000); context.included_secure()
			context.at(3000)
			local keylogger = package.loaded["modules.keylogger.init"]
			keylogger.set_secure_field_filter_enabled(true)
			helpers.assert_eq(scenario.state.is_secure_field, true)
			helpers.assert_eq(keylogger.context_allows_logging(), false)
			context.at(4000); context.ordinary()
			context.at(7000); scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 1, "Enabling exclusion must cancel the whole existing hold")
			context.at(8000); scenario.flags_changed(55, { cmd = true })
			context.at(9000); scenario.flags_changed(55, {})
			assert_events(scenario, { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55 } })
			helpers.assert_eq(scenario.system_events[3].hold_ms, 1000)
			helpers.assert_eq(scenario.state.modifier_down_at[55], nil)
			helpers.assert_eq(scenario.state.modifier_suppressed_releases[55], nil)
		end)
	end)

	helpers.it("(wp3-secure-policy) malformed_held_refusal_blocks_then_recovers", function()
		with_secure_callback(function(scenario, context)
			scenario.flags_changed(55, { cmd = true })
			local timestamp = scenario.state.modifier_down_at[55]
			helpers.assert_eq(type(timestamp), "number")
			scenario.state.modifier_down_at[55] = "invalid"
			context.secure()
			raw_ordinary_callback(scenario, context, false)
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 1)
			helpers.assert_eq(scenario.state.modifier_down_at[55], "invalid", "Refusal retains malformed cleanup debt")
			scenario.state.modifier_down_at[55] = timestamp
			raw_ordinary_callback(scenario, context, true)
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 1)
			fresh_pair(scenario, 1)
			assert_events(scenario, { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55 } })
		end)
	end)

	helpers.it("(wp3-secure-policy) malformed_marker_refusal_blocks_then_recovers", function()
		with_secure_callback(function(scenario, context)
			scenario.flags_changed(55, { cmd = true })
			scenario.state.modifier_suppressed_releases[54] = false
			context.secure()
			raw_ordinary_callback(scenario, context, false)
			helpers.assert_eq(scenario.state.modifier_suppressed_releases[54], false)
			scenario.state.modifier_suppressed_releases[54] = nil
			raw_ordinary_callback(scenario, context, true)
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 1)
			fresh_pair(scenario, 1)
			assert_events(scenario, { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55 } })
		end)
	end)

	-- Frozen pending-release controls; no product implementation or native evidence.
	local function with_pending_release_clock(body)
		with_secure_callback(function(scenario, context)
			local timer, clock = _G.hs.timer, 1000000000
			local original_clock = timer.absoluteTime
			timer.absoluteTime = function() return clock end
			local ok, failure = xpcall(function()
				body(scenario, context, function(ms) clock = ms * 1000000 end)
			end, debug.traceback)
			timer.absoluteTime = original_clock
			if not ok then error(failure, 0) end
		end)
	end

	for _, malformed in ipairs({
		{ name = "unrelated held timestamp corruption", field = "modifier_down_at", value = "invalid" },
		{ name = "unrelated marker corruption", field = "modifier_suppressed_releases", value = false },
	}) do
		helpers.it("(wp3-pending-release) " .. malformed.name, function()
			with_pending_release_clock(function(scenario, context, at)
				local keylogger = package.loaded["modules.keylogger.init"]
				at(1000); scenario.flags_changed(55, { cmd = true })
				scenario.state[malformed.field][54] = malformed.value
				context.secure()
				helpers.assert_eq(keylogger.context_allows_logging(), false)
				helpers.assert_eq(keylogger.may_persist(), false)
				at(3000); scenario.flags_changed(55, {})
				helpers.assert_eq(#scenario.system_events, 1, "Pending release cannot credit excluded telemetry")
				helpers.assert_eq(scenario.state[malformed.field][54], malformed.value,
					"Observed release cannot repair unrelated malformed debt")
				helpers.assert_eq(keylogger.context_allows_logging(), false)
				helpers.assert_eq(keylogger.may_persist(), false)
				-- Only this explicit fixture owner repairs its injected unrelated entry.
				scenario.state[malformed.field][54] = nil
				raw_ordinary_callback(scenario, context, true)
				at(8000); scenario.flags_changed(55, { cmd = true })
				at(9000); scenario.flags_changed(55, {})
				local actual = {}
				for _, event in ipairs(scenario.system_events) do
					actual[#actual + 1] = { event.action, event.keycode, event.hold_ms }
				end
				helpers.assert_eq(actual, {
					{ "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 },
				}, "Known physical release before repair must not invert the fresh pair")
			end)
		end)
	end

	for _, refused in ipairs({
		{ name = "invalid release flags preserve known held timestamp", key = 55, flags = { cmd = "invalid" } },
		{ name = "unknown physical key preserves known held timestamp", key = 999, flags = {} },
	}) do
		helpers.it("(wp3-pending-release) " .. refused.name, function()
			with_pending_release_clock(function(scenario, context, at)
				local keylogger = package.loaded["modules.keylogger.init"]
				at(1000); scenario.flags_changed(55, { cmd = true })
				local timestamp = scenario.state.modifier_down_at[55]
				scenario.state.modifier_down_at[54] = "invalid"
				context.secure()
				at(3000); scenario.flags_changed(refused.key, refused.flags)
				helpers.assert_eq(scenario.state.modifier_down_at[55], timestamp)
				helpers.assert_eq(scenario.state.modifier_down_at[54], "invalid")
				helpers.assert_eq(keylogger.context_allows_logging(), false)
				helpers.assert_eq(keylogger.may_persist(), false)
				helpers.assert_eq(#scenario.system_events, 1)
				scenario.state.modifier_down_at[54] = nil
				raw_ordinary_callback(scenario, context, true)
				scenario.flags_changed(55, {})
				helpers.assert_eq(#scenario.system_events, 1, "Refusal retains the genuine crossing release debt")
			end)
		end)
	end

	-- Independent hostile native-getter port; no product callback or source rewritten.
	helpers.it("(wp3-pending-release) native getter owner replacement preserves pending debt without foreign equality", function()
		with_pending_release_clock(function(scenario, context, at)
			local keylogger = package.loaded["modules.keylogger.init"]
			at(1000); scenario.flags_changed(55, { cmd = true })
			local held, suppressed = scenario.state.modifier_down_at, scenario.state.modifier_suppressed_releases
			local timestamp = rawget(held, 55)
			helpers.assert_eq(type(timestamp), "number")
			rawset(held, 54, "invalid")
			context.secure()
			helpers.assert_eq(keylogger.context_allows_logging(), false)
			local handler
			for index = 1, 200 do
				local name, value = debug.getupvalue(scenario.flags_changed, index)
				if name == nil then break end
				if name == "handle_key" then handler = value; break end
			end
			helpers.assert_eq(type(handler), "function", "Use the existing fixture's exact production event handler")
			local equality_calls, getter_calls = 0, 0
			local equality = function() equality_calls = equality_calls + 1; return true end
			local held_meta, suppressed_meta = { __eq = equality }, { __eq = equality }
			local foreign_held = setmetatable({ [55] = 42, [54] = "foreign" }, held_meta)
			local foreign_suppressed = setmetatable({ [54] = false }, suppressed_meta)
			local event = {
				getType = function() return _G.hs.eventtap.event.types.flagsChanged end,
				getKeyCode = function() return 55 end,
				getProperty = function() return 0 end,
				getFlags = function()
					getter_calls = getter_calls + 1
					scenario.state.modifier_down_at = foreign_held
					scenario.state.modifier_suppressed_releases = foreign_suppressed
					return {}
				end,
			}
			local called, failure = xpcall(function()
				at(3000); handler(event)
				-- Old conservative omission can refuse before reading any getter.
				-- It is safe but does not qualify the replacement-getter observation.
				print("WP3_OWNER_GETTER_CALLBACK_OBSERVED " .. getter_calls)
				helpers.assert_true(getter_calls == 0 or getter_calls == 1)
				helpers.assert_eq(equality_calls, 0, "Foreign owner equality cannot be called for ownership proof")
				helpers.assert_eq(rawget(held, 55), timestamp, "Foreign replacement cannot cancel captured owner's interval")
				helpers.assert_eq(rawget(held, 54), "invalid")
				helpers.assert_eq(#scenario.system_events, 1)
				helpers.assert_eq(keylogger.context_allows_logging(), false)
				helpers.assert_eq(keylogger.may_persist(), false)
				helpers.assert_eq(rawget(foreign_held, 55), 42)
				helpers.assert_eq(rawget(foreign_held, 54), "foreign")
				helpers.assert_eq(rawget(foreign_suppressed, 54), false)
				helpers.assert_true(rawequal(getmetatable(foreign_held), held_meta))
				helpers.assert_true(rawequal(getmetatable(foreign_suppressed), suppressed_meta))
				local held_count, suppressed_count = 0, 0
				for _ in next, foreign_held do held_count = held_count + 1 end
				for _ in next, foreign_suppressed do suppressed_count = suppressed_count + 1 end
				helpers.assert_eq(held_count, 2)
				helpers.assert_eq(suppressed_count, 1)
				if getter_calls == 1 then
					helpers.assert_true(rawequal(scenario.state.modifier_down_at, foreign_held))
					helpers.assert_true(rawequal(scenario.state.modifier_suppressed_releases, foreign_suppressed))
				end
			end, debug.traceback)
			-- Only this fixture owner restores its injected state; no product repair proof.
			scenario.state.modifier_down_at, scenario.state.modifier_suppressed_releases = held, suppressed
			rawset(held, 55, timestamp); rawset(held, 54, nil)
			if not called then error(failure, 0) end
		end)
	end)

end)

-- Frozen independent policy vectors; transcribed from EXPECTATIONS-BEFORE.json.
local private_modifier_vectors = {
	{
		id = "windowFocused:ordinary_pair_control",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "ordinary@1000", "down55@1000", "up55@2000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:release_private_then_fresh_pair",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "up55@3000", "ordinary@4000", "down55@5000", "up55@6000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:whole_private_interval_without_key_transition",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "ordinary@4000", "up55@7000", "down55@8000", "up55@9000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:press_private_then_crossing_release",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "private@2000", "down55@3000", "ordinary@4000", "up55@5000", "down55@6000", "up55@7000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:whole_pair_inside_private",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "private@2000", "down55@3000", "up55@4000", "ordinary@5000", "down55@6000", "up55@7000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:private_release_then_private_repress",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "up55@3000", "down55@4000", "ordinary@5000", "up55@6000", "down55@7000", "up55@8000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:disabled_private_interval_preserves_full_hold",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "public_set_private_filter_enabled(false)", "down55@1000", "private@2000", "ordinary@4000", "up55@7000", "down55@8000", "up55@9000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:disabled_private_pair_is_included",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "public_set_private_filter_enabled(false)", "private@2000", "down55@3000", "up55@9000", "ordinary@9500", "down55@10000", "up55@11000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:enabling_private_filter_inside_private_cancels_hold",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "public_set_private_filter_enabled(false)", "down55@1000", "private@2000", "public_set_private_filter_enabled(true)@3000", "ordinary@4000", "up55@7000", "down55@8000", "up55@9000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:private_and_secure_overlap_stays_denied_until_both_exit",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "real_AX_secure@3000", "ordinary@4000", "up55@5000", "real_AX_ordinary@6000", "down55@7000", "up55@8000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:ordinary_pair_control",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "ordinary@1000", "down55@1000", "up55@2000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:release_private_then_fresh_pair",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "up55@3000", "ordinary@4000", "down55@5000", "up55@6000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:whole_private_interval_without_key_transition",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "ordinary@4000", "up55@7000", "down55@8000", "up55@9000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:press_private_then_crossing_release",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "private@2000", "down55@3000", "ordinary@4000", "up55@5000", "down55@6000", "up55@7000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:whole_pair_inside_private",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "private@2000", "down55@3000", "up55@4000", "ordinary@5000", "down55@6000", "up55@7000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:private_release_then_private_repress",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "up55@3000", "down55@4000", "ordinary@5000", "up55@6000", "down55@7000", "up55@8000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:disabled_private_interval_preserves_full_hold",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "public_set_private_filter_enabled(false)", "down55@1000", "private@2000", "ordinary@4000", "up55@7000", "down55@8000", "up55@9000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:disabled_private_pair_is_included",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "public_set_private_filter_enabled(false)", "private@2000", "down55@3000", "up55@9000", "ordinary@9500", "down55@10000", "up55@11000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:enabling_private_filter_inside_private_cancels_hold",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "public_set_private_filter_enabled(false)", "down55@1000", "private@2000", "public_set_private_filter_enabled(true)@3000", "ordinary@4000", "up55@7000", "down55@8000", "up55@9000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:private_and_secure_overlap_stays_denied_until_both_exit",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "real_AX_secure@3000", "ordinary@4000", "up55@5000", "real_AX_ordinary@6000", "down55@7000", "up55@8000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
}

-- Composition limit: the original Accounting fixture constructed the real event
-- consumer with its retained tracker double. Before the ACTUAL start below, the
-- retained public ports forward to a fresh REAL tracker. Its init receives the
-- EXACT production fourth callback; no test settlement function is manufactured.
-- Window/AX/application/persistence boundaries remain doubles, not native proof.
local function with_private_window_callback(vector, body)
	Accounting.run(function(scenario)
		local startup_tracker = package.loaded["modules.keylogger.context_tracker"]
		local lifecycle = package.loaded["adapters.process_lifecycle"]
		local manager = package.loaded["modules.keylogger.log_manager"]
		local original_activation = lifecycle.onAppActivate
		local original_append = manager.append_log
		local port_names = { "init", "app_watcher_cb", "update_private_status", "update_ax_observer",
			"capture_frontmost_app", "resync_context" }
		local previous_ports = {}
		for _, name in ipairs(port_names) do previous_ports[name] = startup_tracker[name] end
		helpers.with_fresh_modules({ "modules.keylogger.context_tracker", "adapters.secure_field_detector" }, function()
			local native = _G.hs
			local previous_application, previous_window = native.application, native.window
			local previous_ax, previous_caffeinate = native.axuielement, native.caffeinate
			local previous_clock = native.timer.absoluteTime
			local controls = { clock_ms = 1000, title = vector.ordinary_title,
				title_reads = 0, role_reads = 0, subrole_reads = 0,
				filter_new = 0, subscriptions = 0, unsubscribes = 0,
				ax_starts = 0, ax_stops = 0, metadata = {} }
			local function element(role)
				return { attributeValue = function(_, name)
					if name == "AXRole" then controls.role_reads = controls.role_reads + 1; return role end
					if name == "AXSubrole" then controls.subrole_reads = controls.subrole_reads + 1; return nil end
					if name == "AXValue" then return "" end
				end }
			end
			local ordinary, secure = element("AXTextField"), element("AXSecureTextField")
			local app_element = { attributeValue = function(_, name)
				if name == "AXFocusedUIElement" then return ordinary end
			end }
			local app = { name = function() return "Firefox" end,
				bundleID = function() return "org.mozilla.firefox" end,
				path = function() return "/Applications/Firefox.app" end,
				pid = function() return 4242 end }
			local window = { title = function() controls.title_reads = controls.title_reads + 1; return controls.title end,
				isFullScreen = function() return false end, application = function() return app end }
			local observer = {
				addWatcher = function(self) return self end,
				removeWatcher = function(self) return self end,
				callback = function(self, callback) controls.ax_callback = callback; return self end,
				start = function(self) controls.ax_starts = controls.ax_starts + 1; return self end,
				stop = function(self) controls.ax_stops = controls.ax_stops + 1; return self end,
			}
			local filter = {
				subscribe = function(self, events, callback)
					controls.subscriptions = controls.subscriptions + 1
					controls.events, controls.window_callback = events, callback
					return self
				end,
				unsubscribeAll = function(self) controls.unsubscribes = controls.unsubscribes + 1; return self end,
			}
			local tracker, keylogger
			local called, failure = xpcall(function()
				native.timer.absoluteTime = function() return controls.clock_ms * 1000000 end
				native.application = { watcher = { activated = 1 }, frontmostApplication = function() return app end }
				native.window = { focusedWindow = function() return window end, filter = {
					windowFocused = "windowFocused", windowTitleChanged = "windowTitleChanged",
					new = function(browsers)
						controls.filter_new = controls.filter_new + 1
						controls.browsers = browsers
						return filter
					end,
				} }
				native.axuielement = {
					applicationElementForPID = function() return app_element end,
					applicationElement = function() return app_element end,
					windowElement = function() return nil end,
					observer = { new = function() return observer end },
				}
				native.caffeinate = { watcher = { new = function()
					return { start = function(self) return self end, stop = function(self) return self end }
				end } }
				tracker = require("modules.keylogger.context_tracker")
				for _, name in ipairs(port_names) do
					if name ~= "init" then startup_tracker[name] = tracker[name] end
				end
				startup_tracker.init = function(state, log_manager, paused, settle)
					controls.startup_dependencies = { state, log_manager, paused, settle }
					controls.forwarded_dependencies = { state, log_manager, paused, settle }
					return tracker.init(state, log_manager, paused, settle)
				end
				lifecycle.onAppActivate = function(callback)
					controls.activation_callback = callback
					return original_activation(callback)
				end
				-- Persistence-boundary recorder: the original fixture has no append_log.
				manager.append_log = function(entry) controls.metadata[#controls.metadata + 1] = entry; return true end
				keylogger = package.loaded["modules.keylogger.init"]
				scenario.state.is_enabled = false
				helpers.assert_eq(keylogger.start({ is_paused = function() return false end }), true)
				local deps = controls.startup_dependencies
				helpers.assert_eq(type(deps), "table")
				helpers.assert_eq(deps[1], scenario.state)
				helpers.assert_eq(deps[2], manager)
				helpers.assert_eq(type(deps[3]), "function")
				helpers.assert_eq(type(deps[4]), "function", "Only the actual production startup supplies settlement")
				for index = 1, 4 do helpers.assert_eq(controls.forwarded_dependencies[index], deps[index]) end
				helpers.assert_eq(tracker.init(deps[1], deps[2], deps[3], deps[4]), true)
				helpers.assert_eq(type(controls.activation_callback), "function")
				helpers.assert_eq(controls.unsubscribes, 0, "The actual activation must precede native filter retirement")
				controls.activation_callback("Firefox", app)
				helpers.assert_eq(scenario.state.active_app_bundle, "org.mozilla.firefox")
				helpers.assert_eq(scenario.state.is_secure_field, false)
				helpers.assert_eq(scenario.state.is_private_window, false)
				helpers.assert_eq(keylogger.context_allows_logging(), true)
				helpers.assert_true(controls.role_reads > 0 and controls.subrole_reads > 0,
					"The real AX classifier must establish ordinary secure state")
				helpers.assert_eq(controls.filter_new, 1)
				helpers.assert_eq(controls.subscriptions, 1)
				helpers.assert_eq(controls.events, { native.window.filter.windowFocused, native.window.filter.windowTitleChanged })
				helpers.assert_true(type(controls.browsers) == "table")
				local firefox_found = false
				for _, browser in ipairs(controls.browsers) do if browser == "Firefox" then firefox_found = true end end
				helpers.assert_eq(firefox_found, true)
				helpers.assert_eq(controls.window_callback, tracker.update_private_status)
				helpers.assert_eq(scenario.state.ax_observer, observer)
				helpers.assert_eq(controls.ax_starts, 1)
				helpers.assert_eq(type(controls.ax_callback), "function")
				helpers.assert_eq(#scenario.system_events, 0)
				controls.expected_secure = false
				controls.private = function(private)
					helpers.assert_eq(controls.unsubscribes, 0, "An unsubscribed window callback has no delivery authority")
					controls.title = private and vector.private_title or vector.ordinary_title
					local reads = controls.title_reads
					helpers.assert_eq(_G.hs, native)
					helpers.assert_eq(package.loaded["modules.keylogger.context_tracker"], tracker)
					helpers.assert_eq(controls.window_callback, tracker.update_private_status)
					helpers.assert_eq(scenario.state.is_secure_field, controls.expected_secure)
					controls.window_callback(window, "Firefox", native.window.filter[vector.registered_event])
					helpers.assert_eq(controls.title_reads, reads + 1, "The registered callback must read the native title")
					helpers.assert_eq(scenario.state.is_private_window, private)
					helpers.assert_eq(scenario.state.is_secure_field, controls.expected_secure)
					local expected_allowed = not controls.expected_secure
						and (not private or scenario.state.private_filter_enabled == false)
					helpers.assert_eq(keylogger.context_allows_logging(), expected_allowed)
				end
				controls.ax = function(is_secure)
					helpers.assert_eq(controls.unsubscribes, 0, "The native window subscription must remain active during AX overlap")
					local roles, subroles = controls.role_reads, controls.subrole_reads
					controls.ax_callback(is_secure and secure or ordinary, "AXFocusedUIElementChanged", observer)
					helpers.assert_eq(controls.role_reads, roles + 1)
					helpers.assert_eq(controls.subrole_reads, subroles + 1)
					controls.expected_secure = is_secure
					helpers.assert_eq(scenario.state.is_secure_field, is_secure)
					local expected_allowed = not is_secure
						and (not scenario.state.is_private_window or scenario.state.private_filter_enabled == false)
					helpers.assert_eq(keylogger.context_allows_logging(), expected_allowed)
				end
				body(scenario, controls, keylogger)
			end, debug.traceback)
			local stop_ok, stopped = true, true
			if keylogger then stop_ok, stopped = pcall(keylogger.stop) end
			for _, name in ipairs(port_names) do startup_tracker[name] = previous_ports[name] end
			lifecycle.onAppActivate, manager.append_log = original_activation, original_append
			native.application, native.window = previous_application, previous_window
			native.axuielement, native.caffeinate = previous_ax, previous_caffeinate
			native.timer.absoluteTime = previous_clock
			if not called then error(failure, 0) end
			helpers.assert_eq(stop_ok, true)
			helpers.assert_eq(stopped, true)
			helpers.assert_eq(controls.unsubscribes, 1)
			helpers.assert_eq(controls.ax_stops, 1)
			helpers.assert_eq(scenario.state.ax_observer, nil)
		end)
	end)
end

helpers.describe("HS-274 held modifier registered private window callbacks (wp3)", function()
	for _, vector in ipairs(private_modifier_vectors) do
		helpers.it("(wp3-private) " .. vector.id, function()
			with_private_window_callback(vector, function(scenario, controls, keylogger)
				for _, step in ipairs(vector.steps) do
					local command, at = step:match("^(.-)@(%d+)$")
					command = command or step
					if at then controls.clock_ms = tonumber(at) end
					if command == "private" then controls.private(true)
					elseif command == "ordinary" then controls.private(false)
					elseif command == "real_AX_secure" then controls.ax(true)
					elseif command == "real_AX_ordinary" then controls.ax(false)
					elseif command == "down55" or command == "up55" then
						helpers.assert_eq(controls.unsubscribes, 0, "The registered window observation must still be active before physical delivery")
						local prior = #scenario.system_events
						local allowed = keylogger.context_allows_logging()
						scenario.flags_changed(55, command == "down55" and { cmd = true } or {})
						if not allowed then helpers.assert_eq(#scenario.system_events, prior, "Excluded events emit no modifier telemetry") end
					else
						local value = command:match("^public_set_private_filter_enabled%((%a+)%)$")
						helpers.assert_true(value == "true" or value == "false", "Every frozen step must be consumed")
						helpers.assert_eq(controls.unsubscribes, 0, "The private-policy setter must start from an active subscription")
						keylogger.set_private_filter_enabled(value == "true")
						helpers.assert_eq(controls.unsubscribes, 0, "Changing the existing private policy must not retire its native subscription")
						helpers.assert_eq(scenario.state.private_filter_enabled, value == "true")
					end
				end
				local actual = {}
				for _, event in ipairs(scenario.system_events) do
					actual[#actual + 1] = { event.action, event.keycode, event.hold_ms }
				end
				helpers.assert_eq(actual, vector.expected)
				helpers.assert_eq(scenario.state.modifier_down_at, {})
				helpers.assert_eq(scenario.state.modifier_suppressed_releases, {})
			end)
		end)
	end
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
-- BEFORE actual keylogger.start. The real registered activation supplies context;
-- application/AX/persistence ports are doubles, not native authentication proof.
local function with_system_policy_callback(vector, body)
	Accounting.run(function(scenario)
		local startup_tracker = package.loaded["modules.keylogger.context_tracker"]
		local lifecycle = package.loaded["adapters.process_lifecycle"]
		local manager = package.loaded["modules.keylogger.log_manager"]
		local previous_activation, previous_append = lifecycle.onAppActivate, manager.append_log
		local ports = { "init", "app_watcher_cb", "update_private_status", "update_ax_observer",
			"capture_frontmost_app", "resync_context" }
		local previous_ports = {}
		for _, name in ipairs(ports) do previous_ports[name] = startup_tracker[name] end
		helpers.with_fresh_modules({ "modules.keylogger.context_tracker", "adapters.secure_field_detector" }, function()
			local native = _G.hs
			local previous_app, previous_window = native.application, native.window
			local previous_ax, previous_caffeinate = native.axuielement, native.caffeinate
			local previous_clock = native.timer.absoluteTime
			local controls = { clock_ms = 1000, role_reads = 0, subrole_reads = 0,
				title_reads = 0, observers = {}, metadata = {} }
			local function application(name, bundle, pid)
				return { name = function() return name end, bundleID = function() return bundle end,
					path = function() return "/Applications/Fixture.app" end, pid = function() return pid end }
			end
			local apps = {
				auth = application("Authentication Dialog", vector.auth_bundle_id, 4242),
				ordinary = application("Editor", "test.editor", 4848),
			}
			controls.current_app = apps[vector.startup_application]
			local ordinary = { attributeValue = function(_, name)
				if name == "AXRole" then controls.role_reads = controls.role_reads + 1; return "AXTextField" end
				if name == "AXSubrole" then controls.subrole_reads = controls.subrole_reads + 1; return nil end
				if name == "AXValue" then return "" end
			end }
			local app_element = { attributeValue = function(_, name)
				if name == "AXFocusedUIElement" then return ordinary end
			end }
			local window = { title = function() controls.title_reads = controls.title_reads + 1; return "Public document" end,
				isFullScreen = function() return false end,
				application = function() return controls.current_app end }
			local tracker, keylogger
			local called, failure = xpcall(function()
				native.timer.absoluteTime = function() return controls.clock_ms * 1000000 end
				native.application = { watcher = { activated = 1 }, frontmostApplication = function() return controls.current_app end }
				native.window = { focusedWindow = function() return window end }
				native.axuielement = {
					applicationElementForPID = function() return app_element end,
					applicationElement = function() return app_element end,
					windowElement = function() return nil end,
					observer = { new = function()
						local owner = { starts = 0, stops = 0 }
						owner.addWatcher = function(self) return self end
						owner.removeWatcher = function(self) return self end
						owner.callback = function(self, callback) self.retained_callback = callback; return self end
						owner.start = function(self) self.starts = self.starts + 1; return self end
						owner.stop = function(self) self.stops = self.stops + 1; return self end
						controls.observers[#controls.observers + 1] = owner
						return owner
					end },
				}
				native.caffeinate = { watcher = { new = function()
					return { start = function(self) return self end, stop = function(self) return self end }
				end } }
				tracker = require("modules.keylogger.context_tracker")
				for _, name in ipairs(ports) do if name ~= "init" then startup_tracker[name] = tracker[name] end end
				startup_tracker.init = function(state, log_manager, paused, settle)
					controls.startup_dependencies = { state, log_manager, paused, settle }
					return tracker.init(state, log_manager, paused, settle)
				end
				lifecycle.onAppActivate = function(callback)
					controls.activation_callback = callback
					return previous_activation(callback)
				end
				manager.append_log = function(entry) controls.metadata[#controls.metadata + 1] = entry; return true end
				keylogger = package.loaded["modules.keylogger.init"]
				-- Only the actual public writer establishes initial policy, never raw state.
				keylogger.set_system_auth_filter_enabled(vector.initial_system_filter)
				helpers.assert_eq(scenario.state.system_auth_filter_enabled, vector.initial_system_filter)
				scenario.state.is_enabled = false
				helpers.assert_eq(keylogger.start({ is_paused = function() return false end }), true)
				local deps = controls.startup_dependencies
				helpers.assert_eq(type(deps), "table")
				helpers.assert_eq(deps[1], scenario.state)
				helpers.assert_eq(deps[2], manager)
				helpers.assert_eq(type(deps[3]), "function")
				helpers.assert_eq(type(deps[4]), "function")
				helpers.assert_eq(tracker.init(deps[1], deps[2], deps[3], deps[4]), true)
				helpers.assert_eq(type(controls.activation_callback), "function")
				local retained_activation = controls.activation_callback
				controls.activate = function(kind)
					helpers.assert_true(kind == "auth" or kind == "ordinary")
					controls.current_app = apps[kind]
					local roles, subroles, titles = controls.role_reads, controls.subrole_reads, controls.title_reads
					helpers.assert_eq(_G.hs, native)
					helpers.assert_eq(package.loaded["modules.keylogger.context_tracker"], tracker)
					helpers.assert_eq(controls.activation_callback, retained_activation)
					retained_activation(controls.current_app:name(), controls.current_app)
					helpers.assert_true(controls.role_reads > roles and controls.subrole_reads > subroles,
						"Real AX classification must establish rawsecure=false independently of the auth bundle")
					helpers.assert_eq(controls.title_reads, titles + 1)
					helpers.assert_eq(scenario.state.active_app_bundle, kind == "auth" and vector.auth_bundle_id or "test.editor")
					helpers.assert_eq(scenario.state.is_secure_field, false)
					helpers.assert_eq(scenario.state.is_private_window, false)
					helpers.assert_eq(keylogger.context_allows_logging(), kind ~= "auth" or scenario.state.system_auth_filter_enabled == false)
					helpers.assert_eq(scenario.state.ax_observer, controls.observers[#controls.observers])
				end
				controls.activate(vector.startup_application)
				helpers.assert_eq(#scenario.system_events, 0)
				body(scenario, controls, keylogger)
			end, debug.traceback)
			local stopped_ok, stopped = true, true
			if keylogger then stopped_ok, stopped = pcall(keylogger.stop) end
			for _, name in ipairs(ports) do startup_tracker[name] = previous_ports[name] end
			lifecycle.onAppActivate, manager.append_log = previous_activation, previous_append
			native.application, native.window = previous_app, previous_window
			native.axuielement, native.caffeinate = previous_ax, previous_caffeinate
			native.timer.absoluteTime = previous_clock
			if not called then error(failure, 0) end
			helpers.assert_eq(stopped_ok, true)
			helpers.assert_eq(stopped, true)
			helpers.assert_true(#controls.observers >= 1)
			for _, owner in ipairs(controls.observers) do
				helpers.assert_eq(owner.starts, 1)
				helpers.assert_eq(owner.stops, 1)
			end
			helpers.assert_eq(scenario.state.ax_observer, nil)
		end)
	end)
end

helpers.describe("HS-274 held modifier actual system-auth policy writer (wp3)", function()
	for _, vector in ipairs(system_modifier_vectors) do
		helpers.it("(wp3-system-policy) " .. vector.id, function()
			with_system_policy_callback(vector, function(scenario, controls, keylogger)
				for _, step in ipairs(vector.steps) do
					local command, at = step:match("^(.-)@(%d+)$")
					helpers.assert_eq(type(command), "string")
					controls.clock_ms = tonumber(at)
					if command == "activate_auth" then controls.activate("auth")
					elseif command == "activate_ordinary" then controls.activate("ordinary")
					elseif command == "down55" or command == "up55" then
						local prior, allowed = #scenario.system_events, keylogger.context_allows_logging()
						scenario.flags_changed(55, command == "down55" and { cmd = true } or {})
						if not allowed then helpers.assert_eq(#scenario.system_events, prior) end
					else
						local value = command:match("^system%((%a+)%)$")
						helpers.assert_true(value == "true" or value == "false")
						keylogger.set_system_auth_filter_enabled(value == "true")
						helpers.assert_eq(scenario.state.system_auth_filter_enabled, value == "true")
						helpers.assert_eq(scenario.state.is_secure_field, false)
						helpers.assert_eq(scenario.state.is_private_window, false)
						helpers.assert_eq(keylogger.context_allows_logging(), controls.current_app:bundleID() == "test.editor" or value == "false")
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
