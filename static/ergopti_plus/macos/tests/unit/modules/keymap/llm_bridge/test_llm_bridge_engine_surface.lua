--- tests/unit/modules/keymap/llm_bridge/test_llm_bridge_engine_surface.lua

--- ==============================================================================
--- MODULE: Regression — every engine call of the LLM bridge exists on the real engine
--- DESCRIPTION:
--- modules/keymap/llm_bridge.lua forwards its settings and predictions to
--- modules.llm.prediction_engine through `engine.<name>(...)`. Every bridge test
--- replaces that engine with a stub, so a stub that defines a name the real
--- engine does not export keeps the whole suite green while production calls
--- nil. That is how prediction_engine.perform_check once called a
--- StreamingHandler function production never implemented.
---
--- The only check that loaded the real engine, for set_llm_display_model_name,
--- left with an absence-only file in 8bb0267ae5; its claimed twin in
--- test_llm_bridge_no_duplicate_init.lua runs against a stub. This file covers
--- the whole class instead of one setter: it collects every `engine.<name>(`
--- call in the bridge's executable source and requires each name to be a
--- function of the real, freshly loaded engine.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Removes Lua comments so a name quoted in documentation is never collected.
--- @param source string Lua source text.
--- @return string The source without long or line comments.
local function strip_comments(source)
	local without_long = source:gsub("%-%-%[(=*)%[.-%]%1%]", "")
	return (without_long:gsub("%-%-[^\n]*", ""))
end

--- Returns the sorted distinct names the bridge calls on `engine`.
--- @param source string The bridge source.
--- @return string[] Distinct called names.
local function engine_calls(source)
	local seen, names = {}, {}
	for name in ("\n" .. strip_comments(source)):gmatch("[^%w_%.]engine%.([%a_][%w_]*)%s*%(") do
		if not seen[name] then
			seen[name] = true
			names[#names + 1] = name
		end
	end
	table.sort(names)
	return names
end

helpers.describe("llm_bridge: every engine call exists on the real prediction engine", function()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	local engine = helpers.load_with_stubs("modules.llm.prediction_engine")

	helpers.it("the real engine exports every function the bridge calls", function()
		-- Selected by the module header, not by path, so a move keeps the check.
		local source = helpers.read_driver_unit("--- modules/keymap/llm_bridge.lua\n")
		helpers.assert_true(source ~= nil, "modules/keymap/llm_bridge.lua source must be locatable")
		local names = engine_calls(source)
		-- A floor keeps a broken pattern or a renamed alias from passing on zero
		-- calls; the bridge made 45 distinct engine calls when this was written.
		helpers.assert_true(#names >= 40, "expected at least 40 distinct engine calls, found " .. #names)
		local missing = {}
		for _, name in ipairs(names) do
			if type(engine[name]) ~= "function" then missing[#missing + 1] = name end
		end
		helpers.assert_eq(table.concat(missing, ", "), "",
			"the bridge calls engine functions the real prediction engine does not export")
	end)
end)
