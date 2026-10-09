--- tests/unit/modules/llm/test_prediction_engine_canonicals.lua

--- ==============================================================================
--- MODULE: No Literal Standing In For A Setting
--- DESCRIPTION:
--- That the prediction engine takes every configurable value from the shared
--- source, and refuses to run rather than substituting one of its own.
---
--- THE DEFECT THIS PINS:
--- Two shared modules were loaded through pcall, with a literal written beside
--- each read as a fallback: `(HttpBridge and HttpBridge.DEFAULT_TEMPERATURE) or
--- 0.1`, `or 150`, `or 500`. Those are the temperature the user set, the token
--- budget, and the context window — three settings quietly replaced by numbers
--- nobody chose, on a machine where one require happened to fail.
---
--- The privacy pair is worse, because `nil and X` is falsy rather than absent:
---
---     local _secure_field_filter_enabled =
---         (HttpBridge and HttpBridge.DEFAULT_DISABLE_PASSWORD_FIELDS)
---
--- With the module unloadable that reads FALSE, and `_is_secure_context` returns
--- early without consulting the detector at all. The filter shipped enabled and
--- failed OPEN: the text around the caret went to the model from a password
--- field, silently, with the setting still showing as on.
---
--- Both are now hard requires. A driver that cannot read its own configuration
--- must say so, not invent one.
--- ==============================================================================

local helpers = require("tests.helpers")

local Engine = helpers.load_module("modules.llm.prediction_engine")
local Bridge = helpers.load_module("infra.llm_bridge")
local PromptBuilder = helpers.load_module("llm.prompt_builder")
local Utf8 = helpers.load_module("compat.utf8")




-- =================================================================
-- =================================================================
-- ======= 1/ The values are the shared ones =======================
-- =================================================================
-- =================================================================

helpers.describe("prediction engine: where its numbers come from", function()

	helpers.it("declares the shared canonicals it depends on", function()
		helpers.assert_eq(type(Bridge.DEFAULT_TEMPERATURE), "number",
			"the temperature the user set lives here; a literal beside the read "
				.. "replaces their choice with one nobody made")
		helpers.assert_eq(type(Bridge.DEFAULT_CONTEXT_LENGTH), "number")
		helpers.assert_eq(type(PromptBuilder.DEFAULT_MAX_TOKENS), "number")
	end)

	helpers.it("states the privacy posture as a real boolean", function()
		helpers.assert_eq(type(Bridge.DEFAULT_DISABLE_PASSWORD_FIELDS), "boolean",
			"read through `module and module.FIELD`, an unloadable module makes this "
				.. "nil — which is falsy, so the gate returns early and never asks the "
				.. "detector anything. The filter shipped enabled and failed open.")
		helpers.assert_eq(type(Bridge.DEFAULT_DISABLE_URL_BARS), "boolean")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Context caps use UTF-8 codepoints ====================
-- =================================================================
-- =================================================================

helpers.describe("prompt builder: UTF-8 context cap", function()

	helpers.it("keeps exact trailing codepoints for both limit sources", function()
		local accent = string.char(0xC3, 0xA9)
		local cases = {
			{
				name     = "context override",
				buffer   = accent:rep(600) .. "x",
				config   = { max_words = 0, context_window_chars = 500 },
				expected = accent:rep(499) .. "x",
			},
			{
				name     = "max-words heuristic",
				buffer   = accent:rep(300) .. "x",
				config   = { max_words = 5, context_window_chars = 0 },
				expected = accent:rep(199) .. "x",
			},
		}

		for _, case in ipairs(cases) do
			local context = PromptBuilder.build_params(case.buffer, case.config).context
			local length, invalid_at = Utf8.len(context)
			helpers.assert_eq(context, case.expected,
				case.name .. " must keep the exact trailing codepoints")
			helpers.assert_true(length ~= nil and invalid_at == nil,
				case.name .. " must never split a UTF-8 sequence")
		end
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ It refuses rather than inventing =====================
-- =================================================================
-- =================================================================

helpers.describe("prediction engine: a missing canonical is fatal", function()

	helpers.it("fails to load when the shared bridge is unavailable", function()
		local module_name = "modules.llm.prediction_engine"
		local bridge_name = "infra.llm_bridge"
		local previous_engine = package.loaded[module_name]
		local previous_bridge = package.loaded[bridge_name]
		local previous_searchers = package.preload[bridge_name]

		package.loaded[module_name] = nil
		package.loaded[bridge_name] = nil
		package.preload[bridge_name] = function()
			error("simulated: the shared bridge cannot be read")
		end

		local ok = pcall(require, module_name)

		package.preload[bridge_name] = previous_searchers
		package.loaded[bridge_name] = previous_bridge
		package.loaded[module_name] = previous_engine

		helpers.assert_true(not ok,
			"a driver that cannot read its own configuration must say so. Degrading "
				.. "to literals means the temperature, the context window and both "
				.. "privacy filters silently stop reflecting what the user chose, and "
				.. "the menu keeps showing the settings as if they applied.")
	end)

	helpers.it("still exports its surface after the failed load is undone", function()
		-- The case above reaches into package.loaded; this is the receipt that it
		-- put everything back. A test that leaves the module registry damaged
		-- fails whichever file happens to load next, which reads as a bug there.
		local reloaded = helpers.load_module("modules.llm.prediction_engine")
		helpers.assert_eq(type(reloaded.init), "function")
		helpers.assert_eq(type(reloaded.predict), "function")
	end)

end)
