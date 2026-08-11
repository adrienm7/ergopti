--- tests/unit/modules/keymap/test_llm_bridge_stop.lua

--- ==============================================================================
--- MODULE: LLM Bridge M.stop() Regression Tests
--- DESCRIPTION:
--- Guards the "escape-trap-ghost-tap" fix in modules/keymap/llm_bridge.lua.
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

-- Reset modules so we can load with fresh stubs.
package.loaded["modules.keymap.llm_bridge"] = nil
package.loaded["infra.logger"]                = nil
helpers.load_with_stubs("infra.logger")





-- ====================================================
-- ====================================================
-- ======= 1/ M.stop() existence & basic safety =======
-- ====================================================
-- ====================================================

helpers.describe("llm_bridge M.stop(): existence (escape-trap-ghost-tap)", function()
	helpers.it("M.stop is a function", function()
		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		helpers.assert_eq(type(Bridge.stop), "function",
			"llm_bridge must export M.stop() (escape-trap-ghost-tap)")
	end)

	helpers.it("M.stop() does not raise before the trap is armed", function()
		package.loaded["modules.keymap.llm_bridge"] = nil
		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		-- Called directly. A stop before any start must leave the bridge startable:
		-- the boot path stops defensively before it starts.
		helpers.assert_eq(Bridge.stop(), true)
		helpers.assert_eq(type(Bridge.init), "function",
			"a stop with no escape trap armed must leave the bridge usable")
	end)

	helpers.it("M.stop() is idempotent — safe to call twice", function()
		package.loaded["modules.keymap.llm_bridge"] = nil
		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		local ok1, result1 = pcall(Bridge.stop)
		local ok2, result2 = pcall(Bridge.stop)
		helpers.assert_true(ok1 and ok2, "M.stop() must be safe to call multiple times in a row")
		helpers.assert_eq(result1, true)
		helpers.assert_eq(result2, true)
	end)
end)





-- ==============================================================
-- ==============================================================
-- ======= 2/ escape trap stopped when M.stop() is called =======
-- ==============================================================
-- ==============================================================

helpers.describe("llm_bridge M.stop(): stops the escape trap (escape-trap-ghost-tap)", function()
	helpers.it("M.stop() calls :stop() on the eventtap created by arm_escape_trap()", function()
		package.loaded["modules.keymap.llm_bridge"] = nil

		-- Intercept tooltip before the module loads so the module-level wiring
		-- binds to our stub instead of the real tooltip.
		-- llm_bridge.lua requires "ui.tooltip", not "infra.tooltip".
		local show_cb = nil
		local orig_tooltip = package.loaded["ui.tooltip"] or {}
		local orig_set_on_show = orig_tooltip.set_on_show_callback
		orig_tooltip.set_on_show_callback = function(cb) show_cb = cb end
		package.loaded["ui.tooltip"] = orig_tooltip

		-- Load the module — module-level code runs and calls
		-- tooltip.set_on_show_callback(arm_escape_trap), storing arm_escape_trap in show_cb.
		package.loaded["modules.keymap.llm_bridge"] = nil
		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")

		-- Intercept hs.eventtap.new on the CURRENT _G.hs (replaced by load_with_stubs above).
		-- Must happen after the reload so the module's arm_escape_trap() closure uses
		-- this interception rather than the previous stub instance.
		local trap_stopped = false
		local trap_enabled = false
		local mock_trap    = {
			start = function(self) trap_enabled = true; return self end,
			stop = function(self) trap_stopped = true; trap_enabled = false; return self end,
			isEnabled = function() return trap_enabled end,
		}
		local orig_eventtap_new = hs.eventtap.new
		hs.eventtap.new = function(types, cb) return mock_trap end

		-- Trigger arm_escape_trap() via the stored show callback
		if type(show_cb) == "function" then
			helpers.assert_eq(show_cb(), true)
		end

		helpers.assert_eq(Bridge.stop(), true)

		-- Restore
		hs.eventtap.new = orig_eventtap_new
		if orig_set_on_show then
			orig_tooltip.set_on_show_callback = orig_set_on_show
		end
		package.loaded["ui.tooltip"] = orig_tooltip

		helpers.assert_true(trap_stopped,
			"M.stop() must call :stop() on the escape trap eventtap (escape-trap-ghost-tap)")
	end)

	helpers.it("retries after a transient start failure instead of publishing a dead trap", function()
		package.loaded["modules.keymap.llm_bridge"] = nil
		local show_cb = nil
		local orig_tooltip = package.loaded["ui.tooltip"] or {}
		local orig_set_on_show = orig_tooltip.set_on_show_callback
		orig_tooltip.set_on_show_callback = function(cb) show_cb = cb end
		package.loaded["ui.tooltip"] = orig_tooltip

		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		local orig_eventtap_new = hs.eventtap.new
		local created, starts = 0, 0
		hs.eventtap.new = function()
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

		helpers.assert_eq(type(show_cb), "function")
		helpers.assert_eq(show_cb(), false,
			"a thrown native start cannot own visible tooltip interaction")
		helpers.assert_eq(show_cb(), true,
			"a later show must retry and commit after the transient failure")
		helpers.assert_eq(created, 2,
			"the failed disabled candidate must not block a fresh eventtap")
		helpers.assert_eq(starts, 2)
		helpers.assert_eq(Bridge.stop(), true)

		hs.eventtap.new = orig_eventtap_new
		orig_tooltip.set_on_show_callback = orig_set_on_show
		package.loaded["ui.tooltip"] = orig_tooltip
	end)

	helpers.it("retains and retries the handle when stop raises", function()
		package.loaded["modules.keymap.llm_bridge"] = nil
		local show_cb = nil
		local orig_tooltip = package.loaded["ui.tooltip"] or {}
		local orig_set_on_show = orig_tooltip.set_on_show_callback
		orig_tooltip.set_on_show_callback = function(cb) show_cb = cb end
		package.loaded["ui.tooltip"] = orig_tooltip

		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		local orig_eventtap_new = hs.eventtap.new
		local enabled, stop_calls = false, 0
		hs.eventtap.new = function()
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

		helpers.assert_eq(show_cb(), true)
		helpers.assert_eq(Bridge.stop(), false,
			"a thrown native stop must remain an incomplete lifecycle step")
		helpers.assert_eq(enabled, true)
		helpers.assert_eq(Bridge.stop(), true,
			"the retained handle must make the next teardown attempt effective")
		helpers.assert_eq(enabled, false)
		helpers.assert_eq(stop_calls, 2)
		helpers.assert_eq(Bridge.stop(), true)
		helpers.assert_eq(stop_calls, 2,
			"verified teardown releases the handle and becomes idempotent")

		hs.eventtap.new = orig_eventtap_new
		orig_tooltip.set_on_show_callback = orig_set_on_show
		package.loaded["ui.tooltip"] = orig_tooltip
	end)

	helpers.it("retains the handle when stop returns but the tap remains enabled", function()
		package.loaded["modules.keymap.llm_bridge"] = nil
		local show_cb = nil
		local orig_tooltip = package.loaded["ui.tooltip"] or {}
		local orig_set_on_show = orig_tooltip.set_on_show_callback
		orig_tooltip.set_on_show_callback = function(cb) show_cb = cb end
		package.loaded["ui.tooltip"] = orig_tooltip

		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		local orig_eventtap_new = hs.eventtap.new
		local enabled, stop_calls = false, 0
		hs.eventtap.new = function()
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

		helpers.assert_eq(show_cb(), true)
		helpers.assert_eq(Bridge.stop(), false)
		helpers.assert_eq(enabled, true,
			"a no-op stop must be detected through native state")
		helpers.assert_eq(Bridge.stop(), true)
		helpers.assert_eq(stop_calls, 2)

		hs.eventtap.new = orig_eventtap_new
		orig_tooltip.set_on_show_callback = orig_set_on_show
		package.loaded["ui.tooltip"] = orig_tooltip
	end)

	helpers.it("contains and file-logs a throw at the first Escape callback line", function()
		local original_provenance = package.loaded["adapters.event_provenance"]
		local original_tooltip = package.loaded["ui.tooltip"] or {}
		local original_set_on_show = original_tooltip.set_on_show_callback
		local logger = package.loaded["infra.logger"]
		local original_logger_error = logger.error
		local original_eventtap_new = hs.eventtap.new
		local show_cb, event_cb
		local error_count = 0
		local enabled = false

		package.loaded["adapters.event_provenance"] = {
			STATUS_UNREADABLE = "unreadable",
			classify_with_fence = function() error("CLASSIFY_THROW") end,
		}
		original_tooltip.set_on_show_callback = function(cb) show_cb = cb end
		package.loaded["ui.tooltip"] = original_tooltip
		logger.error = function(...) error_count = error_count + 1; return original_logger_error(...) end
		package.loaded["modules.keymap.llm_bridge"] = nil

		local case_ok, case_err = pcall(function()
			local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
			hs.eventtap.new = function(_, callback)
				event_cb = callback
				return {
					start = function(self) enabled = true; return self end,
					stop = function(self) enabled = false; return self end,
					isEnabled = function() return enabled end,
				}
			end
			helpers.assert_eq(show_cb(), true)
			local callback_ok, consumed = pcall(event_cb, {})
			helpers.assert_true(callback_ok, "the Quartz callback boundary must contain the throw")
			helpers.assert_eq(consumed, false, "a failed classifier must pass the physical key through")
			helpers.assert_true(error_count >= 1, "the swallowed Hammerspoon callback error must reach the file logger")
			helpers.assert_eq(Bridge.stop(), true)
		end)

		hs.eventtap.new = original_eventtap_new
		logger.error = original_logger_error
		original_tooltip.set_on_show_callback = original_set_on_show
		package.loaded["ui.tooltip"] = original_tooltip
		package.loaded["adapters.event_provenance"] = original_provenance
		package.loaded["modules.keymap.llm_bridge"] = nil
		if not case_ok then error(case_err) end
	end)
end)
