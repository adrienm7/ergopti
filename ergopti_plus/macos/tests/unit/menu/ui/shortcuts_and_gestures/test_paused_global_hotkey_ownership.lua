--- tests/unit/menu/ui/shortcuts_and_gestures/test_paused_global_hotkey_ownership.lua

--- ==============================================================================
--- MODULE: Paused Global-Hotkey Ownership Regression
--- DESCRIPTION:
--- Checks that the hotstring editor owns no global hotkey, then inventories the
--- whole direct hs.hotkey.new class. A raw native handle without lifecycle
--- ownership remains callable after feature layers stop.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Removes full-line Lua comments before counting executable constructor sites.
--- @param source string Production source text.
--- @return string code Source without full-line comments.
local function strip_full_line_comments(source)
	local lines = {}
	for line in source:gmatch("[^\n]*") do
		if not line:match("^%s*%-%-") then lines[#lines + 1] = line end
	end
	return table.concat(lines, "\n")
end

--- Counts non-overlapping literal occurrences.
--- @param source string Haystack.
--- @param needle string Literal needle.
--- @return number count
local function count_occurrences(source, needle)
	local count = 0
	local offset = 1
	while true do
		local found = source:find(needle, offset, true)
		if not found then return count end
		count = count + 1
		offset = found + #needle
	end
end

helpers.describe("audit pause fence: global hotkey ownership", function()
	-- The editor's own global shortcut left on 2026-11-21: Ctrl+★ opening it is
	-- the secondary_star keyboard slot, fenced by the keyboard owner's pause.
	helpers.it("audit pause fence: the hotstring editor binds no global hotkey of its own", function()
		local Editor = helpers.load_with_stubs("hotstrings.ui.hotstring_editor")
		helpers.assert_nil(Editor.set_shortcut, "the editor owns no global shortcut")
		helpers.assert_nil(Editor.clear_shortcut, "the editor owns no global shortcut")
	end)

	helpers.it("audit pause fence: keeps the entire direct hs.hotkey.new class under explicit review", function()
		local source = helpers.read_driver_source()
		local llm_source, llm_error = helpers.read_driver_unit("function inst.bind_hotkey")
		local shortcuts_source = helpers.read_driver_source("local KeyboardShortcuts")
		helpers.assert_true(type(source) == "string" and source ~= "",
			"the inventory must read the production tree before asserting an absence")
		helpers.assert_true(type(llm_source) == "string" and llm_source ~= "", llm_error)
		helpers.assert_true(type(shortcuts_source) == "string" and shortcuts_source ~= "",
			"the shortcuts lifecycle source must be locatable")
		local direct_sites = count_occurrences(strip_full_line_comments(source), "hs.hotkey.new")
		local reviewed_sites = count_occurrences(strip_full_line_comments(llm_source), "hs.hotkey.new")

		-- The LLM trigger orchestrator is the one reviewed exemption: its callback
		-- reaches prediction_engine.perform_check(), whose live pause gate rejects it
		-- before any request or output. Editor and menu hotkeys need lifecycle ownership
		helpers.assert_true(reviewed_sites <= 1,
			"the reviewed LLM module must not grow a second direct constructor")
		helpers.assert_eq(direct_sites, reviewed_sites,
			"every direct hotkey must be the reviewed LLM trigger; editor/menu sites must "
				.. "use the pause-owned registration path")
		helpers.assert_true(shortcuts_source:find("HotkeyRegistrar.set_delivery_guard", 1, true) ~= nil,
			"the canonical shortcuts lifecycle must install the adapter-wide pause fence")
	end)
end)
