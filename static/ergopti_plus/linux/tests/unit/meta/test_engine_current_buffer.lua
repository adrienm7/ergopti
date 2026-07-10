--- tests/unit/meta/test_engine_current_buffer.lua

--- ==============================================================================
--- MODULE: Engine current_buffer Accessor Test
--- DESCRIPTION:
--- Guards the shared hotstring engine's current_buffer() accessor.
---
--- ROOT CAUSE ENCODED:
--- The daemon fed the LLM prediction engine with prediction_engine.on_char(ch)
--- and no buffer, so on_char early-returned (it needs the rolling typing buffer to
--- detect its trigger sequences) and the LLM never predicted. The fix threads the
--- engine's current buffer through; this test proves the engine exposes that
--- buffer as the typed text and clears it on reset, so the daemon has a real
--- buffer to pass.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================================
-- =====================================================
-- ======= 1/ Behavioural: buffer reflects typing =======
-- =====================================================
-- =====================================================

helpers.describe("hotstring_engine:current_buffer exposes the rolling typing buffer", function()
	helpers.it("returns the concatenation of the typed characters", function()
		local engine_mod = helpers.load_module("modules.hotstrings.engine")
		local engine = engine_mod.new()
		engine:on_char("h")
		engine:on_char("i")
		engine:on_char("!")
		helpers.assert_eq(engine:current_buffer(), "hi!", "current_buffer must return the typed characters")
	end)

	helpers.it("is empty after reset", function()
		local engine_mod = helpers.load_module("modules.hotstrings.engine")
		local engine = engine_mod.new()
		engine:on_char("x")
		engine:reset()
		helpers.assert_eq(engine:current_buffer(), "", "current_buffer must be empty after reset")
	end)
end)
