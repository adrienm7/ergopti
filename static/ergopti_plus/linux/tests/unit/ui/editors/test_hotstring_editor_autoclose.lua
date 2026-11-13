--- tests/unit/ui/editors/test_hotstring_editor_autoclose.lua

--- ==============================================================================
--- MODULE: Hotstring Editor Shortcut Auto-Close
--- DESCRIPTION:
--- Drives the real Linux hotstring editor bridge with the shared page's
--- shortcut auto-close sequence: `save` then `close`, the latter sent without
--- reading the save's answer.
---
--- ROOT CAUSE ENCODED: `close` only logged and never called the manager's
--- epoch-bound close capability, so the page stayed open (audit LVB-001). A
--- close after a refused save must keep the draft open (audit MVB-002).
--- ==============================================================================

local helpers = require("tests.helpers")

local DRAFT = { sections_order = { "s" }, sections = { s = { description = "S", entries = { {
	trigger = "abc", output = "draft", is_word = true, auto_expand = false, is_case_sensitive = false,
	final_result = false, is_case_sensitive_strict = false,
} } } } }

--- Loads the real bridge against a writer answering `write`, then opens it.
--- @param write function Fake writer.write.
--- @param body function fn(handler, state, context, closes).
local function with_editor(write, body)
	local saved_writer = package.loaded["core.text.engine.toml_codec.writer"]
	local saved_manager = package.loaded["ui.webview_manager"]
	local real_writer = require("core.text.engine.toml_codec.writer")
	package.loaded["core.text.engine.toml_codec.writer"] = {
		read_classified = function() return nil, "absent" end,
		write = write,
		batch_write = real_writer.batch_write,
	}
	package.loaded["ui.webview_manager"] = {
		current_epoch = function() return 73 end,
		eval_js = function() return true end,
	}
	local ok, err = pcall(function()
		local handler = helpers.load_module("ui.hotstring_editor.bridge")
		local state = { config = {
			get_config_dir = function() return "/virtual/ergopti/hotstrings" end,
			reload = function() return 1, true end,
		} }
		local closes = { count = 0 }
		local context = { app_name = "hotstring_editor", epoch = 73, close_owned_window = function()
			closes.count = closes.count + 1
			return true
		end }
		helpers.assert_true(handler.push_init(state, context), "the test needs an accepted opening")
		body(handler, state, context, closes)
	end)
	package.loaded["core.text.engine.toml_codec.writer"] = saved_writer
	package.loaded["ui.webview_manager"] = saved_manager
	package.loaded["ui.hotstring_editor.bridge"] = nil
	if not ok then error(err, 0) end
end

helpers.describe("hotstring editor shortcut auto-close", function()
	helpers.it("closes the exact owned window after a committed save (lvb-001)", function()
		with_editor(function() return true, nil, "committed bytes" end, function(handler, state, context, closes)
			helpers.assert_eq(handler.on_message({ action = "save", data = DRAFT }, state, context), { saved = true })
			helpers.assert_eq(handler.on_message({ action = "close", data = {} }, state, context), { closed = true })
			helpers.assert_eq(closes.count, 1, "close must reach the manager's epoch-bound capability")
		end)
	end)

	helpers.it("reports a close the manager refused for a stale epoch (lvb-001)", function()
		with_editor(function() return true, nil, "committed bytes" end, function(handler, state, context)
			context.close_owned_window = function() return false end
			handler.on_message({ action = "save", data = DRAFT }, state, context)
			helpers.assert_eq(handler.on_message({ action = "close", data = {} }, state, context), { closed = false })
		end)
	end)

	helpers.it("keeps a refused draft open instead of closing it (lvb-001)", function()
		with_editor(function() return false, "conflict" end, function(handler, state, context, closes)
			helpers.assert_eq(handler.on_message({ action = "save", data = DRAFT }, state, context), { saved = false })
			helpers.assert_eq(handler.on_message({ action = "close", data = {} }, state, context), { closed = false })
			helpers.assert_eq(closes.count, 0, "the draft lives only in the page after a refused save")
		end)
	end)
end)
