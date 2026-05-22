--- tests/unit/modules/llm/test_init.lua

--- ==============================================================================
--- MODULE: llm core (init.lua) Unit Tests
--- DESCRIPTION:
--- Validates the LLM core orchestrator: DEFAULT_STATE shape, profile getter/
--- setter contract, backend selection, and the modifier check helper used by
--- the keystroke routing layer.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local Core = helpers.load_with_stubs("modules.llm")




-- =====================================
--- ======================================
-- ======= 1/ DEFAULT_STATE shape =======
--- ======================================
-- =====================================

helpers.describe("Core.DEFAULT_STATE", function()
	local required_keys = {
		"llm_enabled", "llm_backend",
		"llm_model_ollama", "llm_model_mlx",
		"llm_debounce", "llm_num_predictions",
		"llm_sequential_mode", "llm_context_length",
		"llm_temperature", "llm_min_words", "llm_max_words",
		"llm_arrow_nav_enabled", "llm_show_info_bar",
		"llm_pred_indent", "llm_active_profile",
		"llm_reset_on_nav", "llm_after_hotstring",
		"llm_auto_raise_temp", "llm_streaming",
		"llm_streaming_multi", "llm_instant_on_word_end",
	}

	for _, k in ipairs(required_keys) do
		helpers.it("contains '" .. k .. "'", function()
			helpers.assert_true(Core.DEFAULT_STATE[k] ~= nil, k .. " is missing")
		end)
	end

	helpers.it("llm_temperature is in [0, 1.5]", function()
		local t = Core.DEFAULT_STATE.llm_temperature
		helpers.assert_true(type(t) == "number" and t >= 0 and t <= 1.5)
	end)

	helpers.it("llm_min_words <= llm_max_words", function()
		helpers.assert_true(Core.DEFAULT_STATE.llm_min_words <= Core.DEFAULT_STATE.llm_max_words)
	end)

	helpers.it("llm_num_predictions is at least 1", function()
		helpers.assert_true(Core.DEFAULT_STATE.llm_num_predictions >= 1)
	end)

	helpers.it("llm_backend is a known identifier", function()
		local b = Core.DEFAULT_STATE.llm_backend
		helpers.assert_true(b == "ollama" or b == "mlx")
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ Backend Accessors =========
-- =====================================
-- =====================================

helpers.describe("Core.set_backend / get_backend", function()
	helpers.it("get_backend returns the configured default", function()
		local b = Core.get_backend()
		helpers.assert_true(type(b) == "string")
	end)

	helpers.it("set_backend updates the active value", function()
		Core.set_backend("mlx")
		helpers.assert_eq(Core.get_backend(), "mlx")
		Core.set_backend("ollama")
		helpers.assert_eq(Core.get_backend(), "ollama")
	end)

	helpers.it("set_backend ignores empty / non-string", function()
		Core.set_backend("ollama")
		Core.set_backend("")
		helpers.assert_eq(Core.get_backend(), "ollama")
		Core.set_backend(nil)
		helpers.assert_eq(Core.get_backend(), "ollama")
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ Profile Accessors =========
-- =====================================
-- =====================================

helpers.describe("Core profile accessors", function()
	helpers.it("get_active_profile returns a table with 'id'", function()
		local p = Core.get_active_profile()
		helpers.assert_true(type(p) == "table" and type(p.id) == "string")
	end)

	helpers.it("set_active_profile changes the active id (resolved through Profiles)", function()
		Core.set_active_profile("advanced")
		helpers.assert_eq(Core.get_active_profile().id, "advanced")
	end)

	helpers.it("set_active_profile ignores non-string", function()
		Core.set_active_profile("basic")
		Core.set_active_profile(nil)
		Core.set_active_profile(42)
		helpers.assert_eq(Core.get_active_profile().id, "basic")
	end)

	helpers.it("get_all_profiles includes the four built-ins", function()
		local all = Core.get_all_profiles()
		helpers.assert_true(#all >= 4)
	end)

	helpers.it("set_user_profiles merges user list with built-ins", function()
		Core.set_user_profiles({ { id = "myuser", label = "Mine", system_single = "X" } })
		local all = Core.get_all_profiles()
		local has_user = false
		for _, p in ipairs(all) do if p.id == "myuser" then has_user = true end end
		helpers.assert_true(has_user)
	end)

	helpers.it("set_user_profiles ignores non-table input", function()
		Core.set_user_profiles({})
		Core.set_user_profiles("garbage")
		-- Should not crash
	end)
end)




-- =====================================
-- =====================================
-- ======= 4/ Streaming flag ===========
-- =====================================
-- =====================================

helpers.describe("Core.set_llm_streaming", function()
	helpers.it("accepts boolean true", function()
		Core.set_llm_streaming(true)
	end)

	helpers.it("accepts boolean false", function()
		Core.set_llm_streaming(false)
	end)

	helpers.it("treats non-boolean as false", function()
		Core.set_llm_streaming("yes")
		-- No exception expected
	end)
end)




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
