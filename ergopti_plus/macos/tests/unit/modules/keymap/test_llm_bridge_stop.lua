--- tests/unit/modules/keymap/test_llm_bridge_stop.lua

--- ==============================================================================
--- MODULE: LLM Bridge Lifecycle and Fallback Regression Tests
--- DESCRIPTION:
--- Guards the escape-trap lifecycle in modules/keymap/llm_bridge.lua with a
--- self-contained dependency fixture that cannot inherit another test's partial
--- tooltip or prediction-engine double. It also exercises fallback key routing
--- after the tooltip deliberately passes through a physical input event.
---
--- ROOT CAUSE ENCODED:
--- arm_escape_trap() created a persistent hs.eventtap that intercepted Escape.
--- No M.stop() existed, so the tap continued to fire after the keymap module
--- was stopped (e.g. during a Hammerspoon reload). The orphaned tap consumed
--- Escape in every subsequent application until a full HS restart.
---
--- The fix verifies both start and stop against :isEnabled(). A failed start
--- never becomes published ownership, while a failed stop retains the only
--- handle so a later lifecycle attempt can retry it.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ========================================
-- ========================================
-- ======= 1/ Isolated Test Fixture =======
-- ========================================
-- ========================================

local function noop() end
local with_bridge_fixture = require("tests.support.llm_bridge_fixture").with_bridge_fixture





-- ====================================================
-- ====================================================
-- ======= 2/ M.stop() existence & basic safety =======
-- ====================================================
-- ====================================================

helpers.describe("llm_bridge M.stop(): existence (escape-trap-ghost-tap)", function()
	helpers.it("M.stop is a function (escape-trap-ghost-tap)", function()
		with_bridge_fixture(function(fixture)
			helpers.assert_eq(type(fixture.bridge.stop), "function",
				"llm_bridge must export M.stop() (escape-trap-ghost-tap)")
		end)
	end)

	helpers.it("M.stop() does not raise before the trap is armed (escape-trap-ghost-tap)", function()
		with_bridge_fixture(function(fixture)
			-- A defensive stop before start must leave the bridge usable
			helpers.assert_eq(fixture.bridge.stop(), true)
			helpers.assert_eq(type(fixture.bridge.init), "function",
				"a stop with no escape trap armed must leave the bridge usable")
		end)
	end)

	helpers.it("M.stop() is idempotent — safe to call twice (escape-trap-ghost-tap)", function()
		with_bridge_fixture(function(fixture)
			local ok1, result1 = pcall(fixture.bridge.stop)
			local ok2, result2 = pcall(fixture.bridge.stop)
			helpers.assert_true(ok1 and ok2, "M.stop() must be safe to call multiple times in a row")
			helpers.assert_eq(result1, true)
			helpers.assert_eq(result2, true)
		end)
	end)
end)





-- ===========================================================
-- ===========================================================
-- ======= 3/ Fallback Prediction Selection ==================
-- ===========================================================
-- ===========================================================

helpers.describe("llm_bridge fallback prediction selection", function()
	helpers.it("(HS-059) Tab accepts the currently selected row", function()
		with_bridge_fixture(function(fixture)
			fixture.engine_visible = true
			fixture.predictions = { "first", "second", "third" }
			fixture.current_index = 3
			fixture.engine.set_llm_enabled(true)

			local accepted = {}
			fixture.bridge.apply_prediction = function(index)
				accepted[#accepted + 1] = index
				return true
			end

			helpers.assert_eq(fixture.bridge.handle_llm_keys(48, {}, false), true,
				"the keymap fallback must consume a visible bare Tab")
			helpers.assert_eq(accepted, { 3 },
				"the fallback must accept the same row the tooltip still highlights")
		end)
	end)

	helpers.it("passes modified submit keys through while preserving explicit selection", function()
		with_bridge_fixture(function(fixture)
			fixture.engine_visible = true
			fixture.predictions = { "first", "second", "third" }
			fixture.current_index = 2
			fixture.validation_mods = { "alt" }
			fixture.engine.set_llm_enabled(true)

			local accepted = {}
			fixture.bridge.apply_prediction = function(index)
				accepted[#accepted + 1] = index
				return true
			end

			local submit_keys = { 48, 36, 76 }
			local modifier_flags = {
				{ cmd = true }, { ctrl = true }, { alt = true }, { shift = true },
			}
			for _, keycode in ipairs(submit_keys) do
				for _, flags in ipairs(modifier_flags) do
					helpers.assert_eq(fixture.bridge.handle_llm_keys(keycode, flags, false), false,
						"a modified Tab or Enter must reach the foreground application")
				end
			end
			helpers.assert_eq(#accepted, 0,
				"modified submit chords must never accept a prediction")

			helpers.assert_true(fixture.bridge.handle_llm_keys(48, {}, false))
			helpers.assert_true(fixture.bridge.handle_llm_keys(36, {}, false))
			helpers.assert_true(fixture.bridge.handle_llm_keys(76, {}, false))
			helpers.assert_eq(accepted, { 2, 2, 2 },
				"bare submit keys still accept the highlighted prediction")

			helpers.assert_true(fixture.bridge.handle_llm_keys(18, { alt = true }, false))
			helpers.assert_eq(accepted, { 2, 2, 2, 1 },
				"configured modifier-plus-digit selection remains available")
		end)
	end)

	helpers.it("(bare-digit-validation) empty validation modifiers own bare digits", function()
		with_bridge_fixture(function(fixture)
			fixture.engine_visible = true
			fixture.predictions = { "only" }
			fixture.current_index = 1
			fixture.validation_mods = {}
			fixture.engine.set_llm_enabled(true)

			local accepted = {}
			local apply_result = true
			fixture.bridge.apply_prediction = function(index)
				accepted[#accepted + 1] = index
				return apply_result
			end

			helpers.assert_eq(fixture.bridge.handle_llm_keys(18, { alt = true }, false), false,
				"a modified digit must reach the application when validation uses bare digits")
			helpers.assert_eq(fixture.bridge.handle_llm_keys(19, {}, false), false,
				"a digit beyond the shown predictions keeps the pass-through")
			helpers.assert_eq(#accepted, 0)

			helpers.assert_eq(fixture.bridge.handle_llm_keys(18, {}, false), true,
				"a bare 1 must accept even the single shown prediction")
			apply_result = false
			helpers.assert_eq(fixture.bridge.handle_llm_keys(18, {}, false), true,
				"a failed injection must still consume the digit instead of typing it")
			helpers.assert_eq(accepted, { 1, 1 })

			fixture.engine_visible = false
			helpers.assert_eq(fixture.bridge.handle_llm_keys(18, {}, false), false,
				"digits type normally when no prediction is shown")
			helpers.assert_eq(accepted, { 1, 1 })
		end)
	end)
end)





-- ==============================================================
-- ==============================================================
-- ======= 4/ escape trap stopped when M.stop() is called =======
-- ==============================================================
-- ==============================================================

helpers.describe("llm_bridge M.stop(): stops the escape trap (escape-trap-ghost-tap)", function()
	helpers.it("M.stop() calls :stop() on the eventtap created by arm_escape_trap() (escape-trap-ghost-tap)", function()
		local original_tooltip = package.loaded["ui.tooltip"]
		local original_hs = rawget(_G, "hs")
		local partial_calls = 0
		local partial_tooltip = {
			set_on_show_callback = function() partial_calls = partial_calls + 1 end,
		}
		local trap_stopped = false

		with_bridge_fixture(function(fixture)
			local trap_enabled = false
			local mock_trap = {
				start = function(self) trap_enabled = true; return self end,
				stop = function(self) trap_stopped = true; trap_enabled = false; return self end,
				isEnabled = function() return trap_enabled end,
			}
			fixture.hs.eventtap.new = function() return mock_trap end

			helpers.assert_eq(type(fixture.show_callback), "function",
				"the isolated tooltip must receive arm_escape_trap")
			helpers.assert_eq(fixture.show_callback(), true)
			helpers.assert_eq(fixture.bridge.stop(), true)
		end, { preloaded_tooltip = partial_tooltip })

		helpers.assert_eq(partial_calls, 0,
			"a partial tooltip left by another test must never satisfy this fixture")
		helpers.assert_eq(package.loaded["ui.tooltip"], original_tooltip,
			"the fixture must restore the caller's package cache")
		helpers.assert_eq(rawget(_G, "hs"), original_hs,
			"the fixture must restore the caller's Hammerspoon global")
		helpers.assert_true(trap_stopped,
			"M.stop() must call :stop() on the escape trap eventtap (escape-trap-ghost-tap)")
	end)

	helpers.it("restores package.loaded and _G.hs when a scenario assertion raises (escape-trap-ghost-tap)", function()
		local original_tooltip = package.loaded["ui.tooltip"]
		local original_engine = package.loaded["modules.llm.prediction_engine"]
		local original_hs = rawget(_G, "hs")
		local partial_tooltip = { hide = noop }
		local ok, err = pcall(function()
			with_bridge_fixture(function()
				error("EXPECTED_FIXTURE_ASSERTION")
			end, { preloaded_tooltip = partial_tooltip })
		end)

		helpers.assert_eq(ok, false, "the sentinel scenario must actually raise")
		helpers.assert_true(tostring(err):find("EXPECTED_FIXTURE_ASSERTION", 1, true) ~= nil,
			"the fixture must preserve the original assertion failure")
		helpers.assert_eq(package.loaded["ui.tooltip"], original_tooltip)
		helpers.assert_eq(package.loaded["modules.llm.prediction_engine"], original_engine)
		helpers.assert_eq(rawget(_G, "hs"), original_hs)
	end)

	helpers.it("retries after a transient start failure instead of publishing a dead trap (escape-trap-ghost-tap)", function()
		with_bridge_fixture(function(fixture)
			local created, starts = 0, 0
			fixture.hs.eventtap.new = function()
				created = created + 1
				local ordinal = created
				local enabled = false
				return {
					start = function(self)
						starts = starts + 1
						if ordinal == 1 then error("START_FAIL") end
						enabled = true
						return self
					end,
					stop = function(self) enabled = false; return self end,
					isEnabled = function() return enabled end,
				}
			end

			helpers.assert_eq(type(fixture.show_callback), "function")
			helpers.assert_eq(fixture.show_callback(), false,
				"a thrown native start cannot own visible tooltip interaction")
			helpers.assert_eq(fixture.show_callback(), true,
				"a later show must retry and commit after the transient failure")
			helpers.assert_eq(created, 2,
				"the failed disabled candidate must not block a fresh eventtap")
			helpers.assert_eq(starts, 2)
			helpers.assert_eq(fixture.bridge.stop(), true)
		end)
	end)

	helpers.it("retains and retries the handle when stop raises (escape-trap-ghost-tap)", function()
		with_bridge_fixture(function(fixture)
			local enabled, stop_calls = false, 0
			fixture.hs.eventtap.new = function()
				return {
					start = function(self) enabled = true; return self end,
					stop = function(self)
						stop_calls = stop_calls + 1
						if stop_calls == 1 then error("STOP_FAIL") end
						enabled = false
						return self
					end,
					isEnabled = function() return enabled end,
				}
			end

			helpers.assert_eq(fixture.show_callback(), true)
			helpers.assert_eq(fixture.bridge.stop(), false,
				"a thrown native stop must remain an incomplete lifecycle step")
			helpers.assert_eq(enabled, true)
			helpers.assert_eq(fixture.bridge.stop(), true,
				"the retained handle must make the next teardown attempt effective")
			helpers.assert_eq(enabled, false)
			helpers.assert_eq(stop_calls, 2)
			helpers.assert_eq(fixture.bridge.stop(), true)
			helpers.assert_eq(stop_calls, 2,
				"verified teardown releases the handle and becomes idempotent")
		end)
	end)

	helpers.it("retains the handle when stop returns but the tap remains enabled (escape-trap-ghost-tap)", function()
		with_bridge_fixture(function(fixture)
			local enabled, stop_calls = false, 0
			fixture.hs.eventtap.new = function()
				return {
					start = function(self) enabled = true; return self end,
					stop = function(self)
						stop_calls = stop_calls + 1
						if stop_calls > 1 then enabled = false end
						return self
					end,
					isEnabled = function() return enabled end,
				}
			end

			helpers.assert_eq(fixture.show_callback(), true)
			helpers.assert_eq(fixture.bridge.stop(), false)
			helpers.assert_eq(enabled, true,
				"a no-op stop must be detected through native state")
			helpers.assert_eq(fixture.bridge.stop(), true)
			helpers.assert_eq(stop_calls, 2)
		end)
	end)

	helpers.it("contains and file-logs a throw at the first Escape callback line (escape-trap-ghost-tap)", function()
		local throwing_provenance = {
			STATUS_UNREADABLE = "unreadable",
			classify_with_fence = function() error("CLASSIFY_THROW") end,
		}
		with_bridge_fixture(function(fixture)
			local event_callback
			local error_count = 0
			local enabled = false
			local original_logger_error = fixture.logger.error
			fixture.logger.error = function(...)
				error_count = error_count + 1
				return original_logger_error(...)
			end
			fixture.hs.eventtap.new = function(_, callback)
				event_callback = callback
				return {
					start = function(self) enabled = true; return self end,
					stop = function(self) enabled = false; return self end,
					isEnabled = function() return enabled end,
				}
			end

			helpers.assert_eq(fixture.show_callback(), true)
			local callback_ok, consumed = pcall(event_callback, {})
			helpers.assert_true(callback_ok, "the Quartz callback boundary must contain the throw")
			helpers.assert_eq(consumed, false, "a failed classifier must pass the physical key through")
			helpers.assert_true(error_count >= 1,
				"the swallowed Hammerspoon callback error must reach the file logger")
			helpers.assert_eq(fixture.bridge.stop(), true)
		end, { event_provenance = throwing_provenance })
	end)
end)
