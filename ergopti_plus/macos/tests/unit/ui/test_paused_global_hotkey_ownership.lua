--- tests/unit/ui/test_paused_global_hotkey_ownership.lua

--- ==============================================================================
--- MODULE: Paused Global-Hotkey Ownership Regression
--- DESCRIPTION:
--- Exercises the real Hotstring Editor hotkey closure under the canonical pause
--- predicate, then inventories the whole direct hs.hotkey.new class. A raw native
--- handle without lifecycle ownership remains callable after feature layers stop.
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
	helpers.it("audit pause fence: blocks the real editor shortcut callback while paused", function()
		local captured_callback
		local native_hotkey = { enabled = false }
		function native_hotkey:enable() self.enabled = true; return self end
		function native_hotkey:disable() self.enabled = false; return self end
		function native_hotkey:delete() self.enabled = false end

		local paused = true
		package.loaded["modules.shortcuts.script_control"] = {
			is_paused = function() return paused end,
		}

		package.loaded["adapters.hotkey_registrar"] = nil
		local Editor = helpers.load_with_stubs("ui.hotstring_editor", {
			hotkey = {
				bind = function(_mods, _key, callback)
					captured_callback = callback
					native_hotkey:enable()
					return native_hotkey
				end,
			},
		})
		local Hotkeys = require("adapters.hotkey_registrar")
		Hotkeys.set_delivery_guard(function() return not paused end)

		local opens = 0
		Editor.open = function() opens = opens + 1 end
		Editor.set_shortcut({ "cmd", "alt" }, "h")
		helpers.assert_true(native_hotkey.enabled and type(captured_callback) == "function",
			"the positive-control hotkey must be armed with the production closure")

		if native_hotkey.enabled then captured_callback() end
		local opens_while_paused = opens
		paused = false
		if native_hotkey.enabled then captured_callback() end
		Editor.clear_shortcut()

		helpers.assert_eq(opens_while_paused, 0,
			"a native global shortcut must not open Ergopti UI during pause")
		helpers.assert_eq(opens, 1,
			"the same shortcut must remain functional after the pause predicate clears")
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
