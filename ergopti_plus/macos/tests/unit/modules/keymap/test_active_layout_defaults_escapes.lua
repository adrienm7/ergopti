--- tests/unit/modules/keymap/test_active_layout_defaults_escapes.lua

--- ==============================================================================
--- MODULE: Active Layout Probe Decoding Regression
--- DESCRIPTION:
--- Replays what `defaults read com.apple.HIToolbox AppleEnabledInputSources`
--- prints through the real input-source parser: escaped layout names are
--- decoded before labeling and selecting, only keyboard layouts are kept, and a
--- malformed document publishes no partial record.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("active-layout-defaults-escapes", function()
	local function load_parser()
		return helpers.load_with_stubs("modules.keymap.input_sources").parse_active_layouts
	end

	helpers.it("decodes \\U escapes before labeling and selecting layouts", function()
		local parse = load_parser()
		local name = "Français"
		local records = parse('(\n        {\n        InputSourceKind = "Keyboard Layout";\n'
			.. '        "KeyboardLayout ID" = 20;\n        "KeyboardLayout Name" = "Fran\\U00e7ais";\n    }\n)\n', name)
		helpers.assert_type(records, "table")
		helpers.assert_eq(#records, 1)
		helpers.assert_eq(records[1].id, name)
		helpers.assert_eq(records[1].name, name)
		helpers.assert_true(records[1].selected)
	end)

	helpers.it("keeps escaped quotes and backslashes inside one layout name", function()
		local parse = load_parser()
		local name = 'Custom "quoted" \\ layout'
		local records = parse('({ "KeyboardLayout Name" = "Custom \\"quoted\\" \\\\ layout"; })', name)
		helpers.assert_type(records, "table")
		helpers.assert_eq(#records, 1)
		helpers.assert_eq(records[1].id, name)
		helpers.assert_true(records[1].selected)
	end)

	helpers.it("keeps keyboard layouts and drops input methods and palettes", function()
		local parse = load_parser()
		local records = parse(table.concat({
			"(",
			'    { InputSourceKind = "Keyboard Layout"; "KeyboardLayout ID" = 252; "KeyboardLayout Name" = ABC; },',
			'    { "Bundle ID" = "com.apple.CharacterPaletteIM"; InputSourceKind = "Non Keyboard Input Method"; },',
			'    { "Bundle ID" = "com.apple.PressAndHold"; InputSourceKind = "Non Keyboard Input Method"; },',
			'    { "KeyboardLayout ID" = -2; "KeyboardLayout Name" = "Ergopti_v2_2_2_plus"; }',
			")",
		}, "\n"), nil)
		helpers.assert_type(records, "table")
		helpers.assert_eq(#records, 2)
		helpers.assert_eq(records[1].id, "ABC")
		helpers.assert_eq(records[2].id, "Ergopti_v2_2_2_plus")
	end)

	helpers.it("rejects malformed or non-array documents without publishing partial records", function()
		local parse = load_parser()
		for _, raw in ipairs({
			'({ "KeyboardLayout Name" = French; }, 3)',
			'({ "KeyboardLayout Name" = French; }, ("nested"))',
			'({ "KeyboardLayout Name" = "French; })',
			'({ "KeyboardLayout Name" = French })',
			'{}',
			'["French"]',
			"The domain/default pair of (com.apple.HIToolbox, AppleEnabledInputSources) does not exist",
		}) do
			helpers.assert_nil(parse(raw), "invalid probe result: " .. raw)
		end
		helpers.assert_eq(#parse('()'), 0)
	end)
end)
