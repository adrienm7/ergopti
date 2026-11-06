--- tests/unit/ui/healthcheck/test_healthcheck_ai_section.lua

--- ==============================================================================
--- MODULE: Diagnostics AI Section Facts (Linux)
--- DESCRIPTION:
--- The AI section of the real snapshot reports the backend the user selected
--- and a known-off switch as false, through the actual collector and the
--- shared share projection.
---
--- ROOT CAUSE ENCODED: the collector hardcoded "ollama" for an API user (audit
--- LDG-001) and `is_enabled() == true or nil` erased a known false, which the
--- page showed as unknown and the export dropped (audit LDG-002).
--- ==============================================================================

local helpers = require("tests.helpers")

--- The AI section of a real snapshot for one prediction owner.
--- @param llm table|nil Prediction engine double.
--- @return table ai
local function ai_section(llm)
	local Bridge = helpers.load_module("ui.healthcheck.bridge")
	return Bridge.build_snapshot({ llm = llm }, false).sections.ai
end

helpers.describe("diagnostics AI section (linux)", function()
	helpers.it("names the selected API backend instead of Ollama (ldg-001)", function()
		local calls = 0
		local ai = ai_section({ is_enabled = function() return true end,
			get_backend = function() calls = calls + 1; return "api" end })
		helpers.assert_eq(ai.ai_backend, "api")
		helpers.assert_eq(calls, 1, "the collector must ask the engine, not assume")
		helpers.assert_eq(ai_section({ is_enabled = function() return true end,
			get_backend = function() return "ollama" end }).ai_backend, "ollama")
	end)

	helpers.it("keeps a switched-off AI as false, not unknown (ldg-002)", function()
		helpers.assert_eq(ai_section({ is_enabled = function() return false end,
			get_backend = function() return "ollama" end }).ai_enabled, false)
		helpers.assert_eq(ai_section({ is_enabled = function() return true end,
			get_backend = function() return "ollama" end }).ai_enabled, true)
		helpers.assert_nil(ai_section({ get_backend = function() return "ollama" end }).ai_enabled,
			"an engine without the switch stays unknown")
		helpers.assert_eq(ai_section(nil), {}, "no engine reports nothing")
	end)
end)
