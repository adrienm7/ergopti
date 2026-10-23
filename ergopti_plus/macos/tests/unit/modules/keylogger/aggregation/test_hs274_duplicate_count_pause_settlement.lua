--- tests/unit/modules/keylogger/aggregation/test_hs274_duplicate_count_pause_settlement.lua

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
package.loaded["tests.support.modules.keylogger.aggregation.hs274_duplicate_count_fixture"] = nil
local Fixture = require("tests.support.modules.keylogger.aggregation.hs274_duplicate_count_fixture")
local Accounting = Fixture.Accounting





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
				package.loaded["modules.keylogger.context_tracker"].resync_context = function()
					-- The healthy tracker double acknowledges the accepted fixture identity.
					scenario.state.active_app_name = "TestApp"
					scenario.state.active_app_pid = 1
					scenario.state.foreground_refresh_pending = false
					return true
				end
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
end)
