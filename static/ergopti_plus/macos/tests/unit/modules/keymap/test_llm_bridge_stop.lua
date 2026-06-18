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
--- The fix adds M.stop(), which calls :stop() on _escape_trap and nils the
--- reference. keymap/init.lua M.stop() now calls LLMBridge.stop() so the
--- lifecycle is always respected.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Reset modules so we can load with fresh stubs.
package.loaded["modules.keymap.llm_bridge"] = nil
package.loaded["lib.logger"]                = nil
helpers.load_with_stubs("lib.logger")




-- =====================================================
-- =====================================================
-- ======= 1/ M.stop() existence & basic safety =======
-- =====================================================
-- =====================================================

helpers.describe("llm_bridge M.stop(): existence (escape-trap-ghost-tap)", function()
	helpers.it("M.stop is a function", function()
		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		helpers.assert_eq(type(Bridge.stop), "function",
			"llm_bridge must export M.stop() (escape-trap-ghost-tap)")
	end)

	helpers.it("M.stop() does not raise before the trap is armed", function()
		package.loaded["modules.keymap.llm_bridge"] = nil
		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		local ok = pcall(Bridge.stop)
		helpers.assert_true(ok, "M.stop() must not throw when _escape_trap is nil")
	end)

	helpers.it("M.stop() is idempotent — safe to call twice", function()
		package.loaded["modules.keymap.llm_bridge"] = nil
		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		local ok1 = pcall(Bridge.stop)
		local ok2 = pcall(Bridge.stop)
		helpers.assert_true(ok1 and ok2, "M.stop() must be safe to call multiple times in a row")
	end)
end)




-- ==============================================================
--- ==============================================================
-- ======= 2/ escape trap stopped when M.stop() is called =======
--- ==============================================================
-- ==============================================================

helpers.describe("llm_bridge M.stop(): stops the escape trap (escape-trap-ghost-tap)", function()
	helpers.it("M.stop() calls :stop() on the eventtap created by arm_escape_trap()", function()
		package.loaded["modules.keymap.llm_bridge"] = nil

		local trap_stopped = false
		local mock_trap    = {
			start  = function(self) return self end,
			stop   = function(self) trap_stopped = true end,
		}

		-- Intercept hs.eventtap.new to return the mock trap
		local orig_eventtap_new = hs.eventtap.new
		hs.eventtap.new = function(types, cb) return mock_trap end

		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")

		-- Arm the trap by simulating what tooltip.set_on_show_callback does
		-- (it stores arm_escape_trap as a callback; we fire it via the stub)
		local show_cb = nil
		local orig_tooltip = package.loaded["lib.tooltip"] or {}
		local orig_set_on_show = orig_tooltip.set_on_show_callback
		orig_tooltip.set_on_show_callback = function(cb) show_cb = cb end
		package.loaded["lib.tooltip"] = orig_tooltip

		-- Reload so the module-level wiring runs with our intercepted tooltip
		package.loaded["modules.keymap.llm_bridge"] = nil
		Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")

		-- Trigger arm_escape_trap() via the stored show callback
		if type(show_cb) == "function" then
			show_cb()
		end

		Bridge.stop()

		-- Restore
		hs.eventtap.new = orig_eventtap_new
		if orig_set_on_show then
			orig_tooltip.set_on_show_callback = orig_set_on_show
		end

		helpers.assert_true(trap_stopped,
			"M.stop() must call :stop() on the escape trap eventtap (escape-trap-ghost-tap)")
	end)
end)
