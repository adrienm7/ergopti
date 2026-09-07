--- tests/unit/modules/keymap/test_active_layout_json_escapes.lua

--- ==============================================================================
--- MODULE: Active Layout JSON Escaping Regression
--- DESCRIPTION:
--- Replays the Python probe's escaped JSON through the real input-source parser.
--- The native decoder is represented by a pure decoder for these BMP vectors;
--- the default native stub deliberately implements only a limited JSON subset.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

helpers.describe("active-layout-json-escapes", function()
	local function load_parser()
		package.loaded["adapters.json_codec"] = nil
		return helpers.load_with_stubs("modules.keymap.input_sources", {
			json = { decode = json.decode },
		}).parse_active_layouts
	end

	helpers.it("decodes Python Unicode escapes before labeling and selecting layouts", function()
		local parse = load_parser()
		local name = "Français"
		local records = parse('["Fran\\u00e7ais"]\n', name)
		helpers.assert_type(records, "table")
		helpers.assert_eq(#records, 1)
		helpers.assert_eq(records[1].id, name)
		helpers.assert_eq(records[1].name, name)
		helpers.assert_true(records[1].selected)
	end)

	helpers.it("keeps escaped quotes and backslashes inside one layout name", function()
		local parse = load_parser()
		local name = 'Custom "quoted" \\ layout'
		local records = parse('["Custom \\"quoted\\" \\\\ layout"]', name)
		helpers.assert_type(records, "table")
		helpers.assert_eq(#records, 1)
		helpers.assert_eq(records[1].id, name)
		helpers.assert_true(records[1].selected)
	end)

	helpers.it("rejects malformed or non-string arrays without publishing partial records", function()
		local parse = load_parser()
		for _, raw in ipairs({ '["French",3]', '["French",{}]', '["French","', '{}' }) do
			helpers.assert_nil(parse(raw), "invalid probe result: " .. raw)
		end
		helpers.assert_eq(#parse('[]'), 0)
	end)
end)
