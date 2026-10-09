--- tests/unit/modules/dynamic_hotstrings/test_personal_info_multifield_no_tab_desync.lua

--- ==============================================================================
--- MODULE: personal_info — multi-field navigation must stay out of logical text
--- DESCRIPTION:
--- A multi-field @-expansion emits Tab to move focus, but Tab inserts no text in
--- either form field. The CoreState result and logical telemetry must therefore
--- contain only the concatenated field values. Physical ownership is established
--- independently by immutable SyntheticInput tags; the behavioural test in
--- test_synth_echo_includes_tabs.lua proves that every value and Tab event carries
--- the same replacement generation.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src()
	-- Selected by a declaration unique to modules/dynamic_hotstrings/personal_info.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("local function parse_toml_section")
	helpers.assert_true(src ~= nil, "modules/dynamic_hotstrings/personal_info.lua source must be locatable")
	return src
end

helpers.describe("personal_info production path keeps navigation out of logical text", function()
	helpers.it("defines a tab-free `echoed` joined with no separator", function()
		local src = read_src()
		helpers.assert_true(src:find('echoed%s*=%s*table%.concat%(parts,%s*""%)') ~= nil,
			"must derive `echoed = table.concat(parts, \"\")` (values only, no inter-field tab)")
	end)

	helpers.it("passes the tab-free value to inject_dynamic as the buffer result", function()
		local src = read_src()
		helpers.assert_true(src:find("inject_dynamic(n_back, echoed", 1, true) ~= nil,
			"inject_dynamic's result_text must be `echoed` (tab-free) so CoreState.buffer holds no \\t")
		helpers.assert_true(src:find("inject_dynamic(n_back, emitted", 1, true) == nil,
			"inject_dynamic must NOT be armed with the \\t-joined `emitted` (re-introduces the desync)")
	end)

	helpers.it("emits fields and Tabs through SyntheticInput while returning tab-free logical text", function()
		local src = read_src()
		helpers.assert_true(src:find("SyntheticInput.emit_key_strokes(value)", 1, true) ~= nil,
			"field values must use the tagged synthetic-input adapter")
		helpers.assert_true(src:find('SyntheticInput.emit_key_stroke({}, "tab", 0)', 1, true) ~= nil,
			"inter-field navigation must use the same tagged synthetic-input adapter")
		helpers.assert_true(src:find("return c, emitted, echoed", 1, true) ~= nil,
			"the third return value must describe inserted text only, excluding focus navigation")
	end)
end)
