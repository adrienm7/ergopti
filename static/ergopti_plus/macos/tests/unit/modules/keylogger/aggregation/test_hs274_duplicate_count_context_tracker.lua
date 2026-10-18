--- tests/unit/modules/keylogger/aggregation/test_hs274_duplicate_count_context_tracker.lua

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
local private_modifier_vectors = Fixture.private_modifier_vectors
local with_private_window_callback = Fixture.with_private_window_callback





-- Callback graph controls: these test initialization identity only; the secure
-- interval controls above exercise the genuine function captured from startup.
helpers.describe("context tracker optional modifier settlement identity", function()
	local function with_tracker(body)
		helpers.with_fresh_modules({ "modules.keylogger.context_tracker" }, function()
			local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker")
			body(tracker, {}, {}, function() return false end)
		end)
	end

	helpers.it("rejects malformed optional settlement before publishing any dependency", function()
		with_tracker(function(tracker, state, manager, paused)
			for _, invalid in ipairs({ false, {}, 17, "settle" }) do
				helpers.assert_eq(tracker.init(state, manager, paused, invalid), false)
			end
			local settle = function() return true end
			helpers.assert_eq(tracker.init(state, manager, paused, settle), true,
				"rejected attempts must not publish state or poison the valid callback")
		end)
	end)

	helpers.it("accepts only the exact bound settlement callback on reinitialization", function()
		with_tracker(function(tracker, state, manager, paused)
			local settle = function() return true end
			helpers.assert_eq(tracker.init(state, manager, paused, settle), true)
			helpers.assert_eq(tracker.init(state, manager, paused, settle), true)
			helpers.assert_eq(tracker.init(state, manager, paused, function() return true end), false)
			helpers.assert_eq(tracker.init(state, manager, paused), false,
				"a bound owner cannot silently lose its settlement callback")
			helpers.assert_eq(tracker.init(state, manager, paused, settle), true,
				"refused replacement must preserve the original dependency graph")
		end)
	end)

	helpers.it("preserves exact legacy three-argument initialization without binding a callback", function()
		with_tracker(function(tracker, state, manager, paused)
			helpers.assert_eq(tracker.init(state, manager, paused), true)
			helpers.assert_eq(tracker.init(state, manager, paused), true)
			helpers.assert_eq(tracker.init(state, manager, paused, function() return true end), false,
				"a competing callback cannot attach behind the original three-argument owner")
			helpers.assert_eq(tracker.init(state, manager, paused), true)
		end)
	end)
end)

-- Frozen independent policy vectors; transcribed from EXPECTATIONS-BEFORE.json.

-- Composition limit: the original Accounting fixture constructed the real event
-- consumer with its retained tracker double. Before the ACTUAL start below, the
-- retained public ports forward to a fresh REAL tracker. Its init receives the
-- EXACT production fourth callback; no test settlement function is manufactured.
-- Window/AX/application/persistence boundaries remain doubles, not native proof.

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

helpers.describe("HS-274 private publication keeps settlement before foreign work (wp3)", function()
	helpers.it("(wp3-private-order) private classification precedes metadata callback reentry", function()
		with_private_window_callback(private_modifier_vectors[1], function(scenario, controls, keylogger)
			scenario.flags_changed(55, { cmd = true })
			local manager = package.loaded["modules.keylogger.log_manager"]
			local append = manager.append_log
			local reentries = 0
			manager.append_log = function(entry)
				reentries = reentries + 1
				helpers.assert_eq(scenario.state.is_private_window, true,
					"the real title classification is published before foreign metadata code")
				helpers.assert_eq(scenario.state.modifier_down_at[55], nil,
					"the excluded hold is settled before a foreign callback can deliver its release")
				scenario.flags_changed(55, {})
				return append(entry)
			end
			controls.clock_ms = 3000
			controls.private(true)
			manager.append_log = append
			helpers.assert_eq(reentries, 1, "actual window-switch persistence called the reentrant boundary")
			helpers.assert_eq(#scenario.system_events, 1)
			controls.clock_ms = 4000; controls.private(false)
			controls.clock_ms = 5000; scenario.flags_changed(55, { cmd = true })
			controls.clock_ms = 6000; scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 3)
			helpers.assert_eq(scenario.system_events[3].hold_ms, 1000)
		end)
	end)

	helpers.it("(wp3-private-order) a missing window retries the same refused settlement", function()
		with_private_window_callback(private_modifier_vectors[1], function(scenario, controls, keylogger)
			scenario.flags_changed(55, { cmd = true })
			local timestamp = scenario.state.modifier_down_at[55]
			helpers.assert_eq(type(timestamp), "number")
			scenario.state.modifier_down_at[55] = "invalid"
			controls.title = private_modifier_vectors[1].private_title
			controls.clock_ms = 2000
			local accepted = pcall(controls.window_callback)
			helpers.assert_eq(accepted, false, "the actual registered private writer must refuse malformed held debt")
			helpers.assert_eq(scenario.state.is_private_window, true, "refusal does not erase native denial")
			helpers.assert_eq(scenario.state.modifier_down_at[55], "invalid")
			scenario.state.modifier_down_at[55] = timestamp
			local focused = hs.window.focusedWindow
			hs.window.focusedWindow = function() return nil end
			controls.window_callback()
			hs.window.focusedWindow = focused
			helpers.assert_eq(scenario.state.modifier_down_at[55], nil,
				"nil-window return must retry original settlement before it can restore inclusion")
			helpers.assert_eq(scenario.state.modifier_suppressed_releases[55], true)
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 1)
			controls.clock_ms = 4000; controls.private(false)
			controls.clock_ms = 5000; scenario.flags_changed(55, { cmd = true })
			controls.clock_ms = 6000; scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 3)
			helpers.assert_eq(scenario.system_events[3].hold_ms, 1000)
		end)
	end)

	helpers.it("(wp3-private-order) enabling private filtering preserves refused debt until exact retry", function()
		with_private_window_callback(private_modifier_vectors[1], function(scenario, controls, keylogger)
			keylogger.set_private_filter_enabled(false)
			scenario.flags_changed(55, { cmd = true })
			controls.clock_ms = 2000; controls.private(true)
			local timestamp = scenario.state.modifier_down_at[55]
			helpers.assert_eq(type(timestamp), "number")
			scenario.state.modifier_down_at[55] = "invalid"
			local accepted = pcall(keylogger.set_private_filter_enabled, true)
			helpers.assert_eq(accepted, false, "the public writer cannot publish a successful inclusion transition over malformed debt")
			helpers.assert_eq(scenario.state.private_filter_enabled, true)
			helpers.assert_eq(scenario.state.modifier_down_at[55], "invalid")
			scenario.state.modifier_down_at[55] = timestamp
			keylogger.set_private_filter_enabled(true)
			helpers.assert_eq(scenario.state.modifier_down_at[55], nil)
			controls.clock_ms = 4000; controls.private(false)
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 1)
			controls.clock_ms = 5000; scenario.flags_changed(55, { cmd = true })
			controls.clock_ms = 6000; scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 3)
			helpers.assert_eq(scenario.system_events[3].hold_ms, 1000)
		end)
	end)
end)

helpers.describe("HS-274 private classification precedes early native metadata (wp3)", function()
	helpers.it("(wp3-private-early) fullscreen reentry sees private denial and the settled hold", function()
		with_private_window_callback(private_modifier_vectors[1], function(scenario, controls, keylogger)
			scenario.flags_changed(55, { cmd = true })
			local window = hs.window.focusedWindow()
			local fullscreen = window.isFullScreen
			local reentries = 0
			window.isFullScreen = function(self)
				reentries = reentries + 1
				helpers.assert_eq(scenario.state.is_private_window, true,
					"early native metadata cannot run before genuine private title classification")
				helpers.assert_eq(scenario.state.modifier_down_at[55], nil,
					"early metadata must not observe an unsettled excluded hold")
				scenario.flags_changed(55, {})
				return fullscreen(self)
			end
			controls.clock_ms = 3000; controls.private(true)
			window.isFullScreen = fullscreen
			helpers.assert_eq(reentries, 1, "the actual native metadata port was called")
			helpers.assert_eq(#scenario.system_events, 1)
			controls.clock_ms = 4000; controls.private(false)
			controls.clock_ms = 5000; scenario.flags_changed(55, { cmd = true })
			controls.clock_ms = 6000; scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 3)
			helpers.assert_eq(scenario.system_events[3].hold_ms, 1000)
		end)
	end)

	helpers.it("(wp3-private-early) title acquisition preserves the prior denial until its result", function()
		with_private_window_callback(private_modifier_vectors[1], function(scenario, controls, keylogger)
			controls.clock_ms = 2000; controls.private(true)
			local window = hs.window.focusedWindow()
			local title = window.title
			local reads = 0
			window.title = function(self)
				reads = reads + 1
				helpers.assert_eq(scenario.state.is_private_window, true,
					"a title read cannot clear the retained private denial before returning classification input")
				scenario.flags_changed(55, { cmd = true })
				return title(self)
			end
			controls.clock_ms = 3000; controls.private(false)
			window.title = title
			helpers.assert_eq(reads, 1)
			helpers.assert_eq(#scenario.system_events, 0, "the reentrant press belongs to the still-excluded interval")
			scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 0)
			controls.clock_ms = 5000; scenario.flags_changed(55, { cmd = true })
			controls.clock_ms = 6000; scenario.flags_changed(55, {})
			helpers.assert_eq(#scenario.system_events, 2)
			helpers.assert_eq(scenario.system_events[2].hold_ms, 1000)
		end)
	end)
end)
