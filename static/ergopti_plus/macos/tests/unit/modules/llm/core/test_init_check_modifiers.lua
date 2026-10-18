--- tests/unit/modules/llm/core/test_init_check_modifiers.lua

--- ==============================================================================
--- MODULE: llm core (init.lua) Unit Tests
--- DESCRIPTION:
--- Validates the LLM core orchestrator: DEFAULT_STATE shape, profile getter/
--- setter contract, backend selection, and the modifier check helper used by
--- the keystroke routing layer.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.llm.core.init_fixture"] = nil
local Fixture = require("tests.support.modules.llm.core.init_fixture")
local Core = Fixture.Core





-- =====================================
-- =====================================
-- ======= 5/ check_modifiers ==========
-- =====================================
-- =====================================

helpers.describe("Core.check_modifiers", function()
	helpers.it("returns false for non-table targetMods", function()
		helpers.assert_eq(Core.check_modifiers({}, nil), false)
		helpers.assert_eq(Core.check_modifiers({}, "alt"), false)
	end)

	helpers.it("returns false for {'none'}", function()
		helpers.assert_eq(Core.check_modifiers({}, { "none" }), false)
	end)

	helpers.it("matches a single modifier exactly", function()
		helpers.assert_eq(Core.check_modifiers({ alt = true }, { "alt" }), true)
		helpers.assert_eq(Core.check_modifiers({ alt = false }, { "alt" }), false)
	end)

	helpers.it("rejects when extra modifiers are pressed", function()
		-- Target alt, but cmd is also held
		helpers.assert_eq(Core.check_modifiers({ alt = true, cmd = true }, { "alt" }), false)
	end)

	helpers.it("matches multi-modifier sets exactly", function()
		helpers.assert_eq(
			Core.check_modifiers({ cmd = true, shift = true }, { "cmd", "shift" }),
			true
		)
		helpers.assert_eq(
			Core.check_modifiers({ cmd = true, shift = false }, { "cmd", "shift" }),
			false
		)
	end)

	helpers.it("returns false when expected modifier is missing", function()
		helpers.assert_eq(Core.check_modifiers({}, { "alt" }), false)
	end)
end)




-- =========================================
-- =========================================
-- ======= 6/ Model setters =================
-- =========================================
-- =========================================

helpers.describe("Core model setters", function()
	helpers.it("set_llm_model_ollama accepts strings", function()
		Core.set_llm_model_ollama("foo:bar")
	end)

	helpers.it("set_llm_model_mlx accepts strings", function()
		Core.set_llm_model_mlx("foo-mlx")
	end)

	helpers.it("get_current_model returns a string", function()
		helpers.assert_eq(type(Core.get_current_model()), "string")
	end)
end)
