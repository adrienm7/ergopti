--- tests/unit/ui/hotstring_windows/test_hotstring_editor_autoclose_refusal.lua

--- ==============================================================================
--- MODULE: Hotstring Editor Auto-Close After a Refused Save
--- DESCRIPTION:
--- Drives the real editor bridge in shortcut mode, where the shared page sends
--- `save` then `close` without waiting for an answer. A refused save must keep
--- the window, and with it the only copy of the draft, open.
---
--- ROOT CAUSE ENCODED: the close handler deleted the window unconditionally, so
--- a CAS conflict or a write refusal destroyed the draft (audit MVB-002).
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================
-- =====================================
-- ======= 1/ Behavioral Harness =======
-- =====================================
-- =====================================

--- Loads one editor instance whose writer answers `write_result`.
--- @param write function fn() -> written, error, committed_content.
--- @return table editor Real editor module.
--- @return function dispatch Sends one bridge message.
--- @return table state Observable side effects.
local function load_editor(write)
	local hs_stub = require("tests.stubs.hs")
	local dispatch
	local state = { notifications = 0, reloads = 0, deletes = 0 }
	hs_stub.webview.windowMasks = { titled = 1, closable = 2, resizable = 8, miniaturizable = 4 }
	hs_stub.webview.usercontent.new = function()
		return { setCallback = function(_, callback) dispatch = callback end }
	end
	_G.hs = hs_stub
	package.loaded["adapters.file_system"] = { read_with_status = function() return "original", "ok" end }
	package.loaded["infra.toml.writer"] = { write_if_unchanged = function() return write() end }
	package.loaded["core.text.engine.toml_codec.writer"] = nil
	package.loaded["infra.toml.reader"] = {
		parse = function() return { sections = {}, sections_order = {} }, true end,
	}
	package.loaded["infra.notifications"] = {
		notify = function() state.notifications = state.notifications + 1 end,
	}
	package.loaded["ui.ui_builder"] = {
		get_app_geometry = function() return { width = 800, height = 700 } end,
		get_centered_frame = function(width, height) return { w = width, h = height } end,
		force_focus = function() end,
		show_webview = function()
			return {
				evaluateJavaScript = function(self) return self end,
				delete = function() state.deletes = state.deletes + 1 end,
			}
		end,
	}
	package.loaded["ui.hotstring_editor"] = nil
	local editor = require("ui.hotstring_editor")
	editor.init("/virtual/personal_hotstrings.toml", {
		PERSONAL_GROUP_NAME = "personal",
		reload_toml = function() state.reloads = state.reloads + 1; return true end,
	}, function() end, 50)
	return editor, function(body)
		helpers.assert_type(dispatch, "function", "the real editor bridge must be installed")
		dispatch({ body = body })
	end, state
end

local DRAFT = { sections_order = { "s" }, sections = { s = { description = "S", entries = { {
	trigger = "abc", output = "draft", is_word = true, auto_expand = false, is_case_sensitive = false,
	final_result = false, is_case_sensitive_strict = false,
} } } } }





-- ======================================
-- ======================================
-- ======= 2/ Refused Saves Stay Open ===
-- ======================================
-- ======================================

helpers.describe("hotstring editor: shortcut auto-close keeps a refused draft (mvb-002)", function()
	for _, case in ipairs({
		{ name = "a CAS conflict", write = function() return false, "conflict" end },
		{ name = "a raised write", write = function() error("disk refused") end },
	}) do
		helpers.it("keeps the window open after " .. case.name .. " (mvb-002)", function()
			local editor, dispatch, state = load_editor(case.write)
			helpers.assert_true(editor.open("shortcut"))
			dispatch({ action = "ready" })
			dispatch({ action = "save", data = DRAFT })
			dispatch({ action = "close", data = {} })
			helpers.assert_eq(state.deletes, 0, "the page's automatic close must not delete a refused draft")
			helpers.assert_true(editor.is_open(), "the draft stays on screen for another save")
			helpers.assert_true(state.notifications >= 1, "the refusal itself stays loud")
			helpers.assert_true(editor.close() ~= nil)
			package.loaded["ui.hotstring_editor"] = nil
		end)
	end

	-- EDD-1 (maintainer, 2026-11-12): a pause stops typing, not configuration.
	helpers.it("commits a save while the driver is paused (edd1-paused-writes)", function()
	local paused_control = package.loaded["modules.shortcuts.script_control"]
	package.loaded["modules.shortcuts.script_control"] = { is_paused = function() return true end }
		local ok, failure = pcall(function()
			local saves = 0
			local editor, dispatch, state = load_editor(function() saves = saves + 1; return true, nil, "committed" end)
			helpers.assert_true(editor.open("shortcut"))
			dispatch({ action = "ready" })
			dispatch({ action = "save", data = DRAFT })
			helpers.assert_eq(saves, 1, "the paused driver still writes the hotstrings")
			helpers.assert_eq(state.reloads, 1)
			package.loaded["ui.hotstring_editor"] = nil
		end)
	package.loaded["modules.shortcuts.script_control"] = paused_control
		assert(ok, failure)
	end)

	helpers.it("still closes after a committed save, and after a later successful retry (mvb-002)", function()
		local refuse = true
		local editor, dispatch, state = load_editor(function()
			if refuse then return false, "conflict" end
			return true, nil, "committed"
		end)
		helpers.assert_true(editor.open("shortcut"))
		dispatch({ action = "ready" })
		dispatch({ action = "save", data = DRAFT })
		dispatch({ action = "close", data = {} })
		helpers.assert_eq(state.deletes, 0)
		refuse = false
		dispatch({ action = "save", data = DRAFT })
		dispatch({ action = "close", data = {} })
		helpers.assert_eq(state.reloads, 1)
		helpers.assert_eq(state.deletes, 1, "a committed save keeps the automatic close")
		package.loaded["ui.hotstring_editor"] = nil
	end)
end)
