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
				startup_tracker.init = function(state, log_manager, paused)
					controls.startup_dependencies = { state, log_manager, paused }
					return tracker.init(state, log_manager, paused)
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
				helpers.assert_nil(deps[4], "Root three-argument context owner is preserved")
				helpers.assert_eq(tracker.init(deps[1], deps[2], deps[3]), true)
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

-- Independent frozen fault injection: only held/marker maps change, never privacy state.
helpers.describe("Root backport auth setter exact cancellation debt", function()
	for _, fault in ipairs({ "held", "marker" }) do
		helpers.it("malformed " .. fault .. " debt refuses both auth writes and all public accounting until exact retry", function()
			local vector = { auth_bundle_id = "com.apple.SecurityAgent", initial_system_filter = false, startup_application = "auth" }
			with_system_policy_callback(vector, function(scenario, controls, keylogger)
				controls.clock_ms = 1000
				scenario.flags_changed(55, { cmd = true })
				helpers.assert_eq(scenario.state.modifier_down_at[55], 1000)
				local held_before, suppressed_before = {}, {}
				for key, value in pairs(scenario.state.modifier_down_at) do held_before[key] = value end
				for key, value in pairs(scenario.state.modifier_suppressed_releases) do suppressed_before[key] = value end
				if fault == "held" then scenario.state.modifier_down_at[55] = "invalid"
				else scenario.state.modifier_suppressed_releases[54] = "invalid" end
				controls.clock_ms = 3000
				local enabled = pcall(keylogger.set_system_auth_filter_enabled, true)
				helpers.assert_eq(enabled, false, "malformed pure settlement must refuse public enable")
				helpers.assert_eq(scenario.state.system_auth_filter_enabled, true)
				helpers.assert_eq(keylogger.context_allows_logging(), false)
				local disabled = pcall(keylogger.set_system_auth_filter_enabled, false)
				helpers.assert_eq(disabled, false, "effective permission cannot bypass unfinished cancellation")
				helpers.assert_eq(scenario.state.system_auth_filter_enabled, false)
				helpers.assert_eq(scenario.state.is_secure_field, false)
				helpers.assert_eq(scenario.state.is_private_window, false)
				helpers.assert_eq(keylogger.context_allows_logging(), false)
				helpers.assert_eq(keylogger.may_persist(), false)
				local events_before, buffer_before = #scenario.system_events, scenario.state.buffer
				helpers.assert_eq(type(scenario.state.buffer_text), "string")
				helpers.assert_eq(type(scenario.state.buffer_events), "table")
				helpers.assert_eq(type(scenario.state.rich_chunks), "table")
				local text_before = scenario.state.buffer_text
				local typing_before, rich_before = #scenario.state.buffer_events, #scenario.state.rich_chunks
				local wpm_before = #scenario.state.recent_typing_eff
				controls.clock_ms = 4000
				scenario.flags_changed(55, {})
				local synthetic_result = keylogger.notify_synthetic("synthetic fixture", "hotstring", 0)
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
				local recovered, recovery_result = pcall(keylogger.set_system_auth_filter_enabled, false)
				helpers.assert_eq(recovered, true)
				helpers.assert_nil(recovery_result)
				helpers.assert_eq(keylogger.context_allows_logging(), true)
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
