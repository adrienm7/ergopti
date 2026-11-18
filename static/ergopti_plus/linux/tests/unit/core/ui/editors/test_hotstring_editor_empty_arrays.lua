--- tests/unit/core/ui/editors/test_hotstring_editor_empty_arrays.lua

--- ==============================================================================
--- MODULE: Hotstring Editor Payload Keeps Empty Arrays
--- DESCRIPTION:
--- Pushes the real Linux hotstring editor payload for an absent personal file
--- and for a personal section without entries, and reads the JSON the page
--- receives through window.initData.
---
--- ROOT CAUSE ENCODED: the shared JSON encoder writes an empty Lua table as {}.
--- The page calls D.sections.findIndex and entries.forEach, so an absent file
--- (every new user) or an empty section made render() throw: the rows after it
--- were never drawn and the shortcut's add-entry form never opened. Found by
--- tests/hardware/run_editor_receiving_webkit.lua in real WebKit.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

--- Pushes the payload for one classified personal source; returns the decoded initData argument.
--- @param content string|nil Personal file bytes, nil for an absent file.
--- @return string encoded The raw JSON argument handed to the page.
local function pushed_payload(content)
	local saved_writer = package.loaded["core.text.engine.toml_codec.writer"]
	local saved_manager = package.loaded["core.ui.ui.webview_manager"]
	local real_writer = require("core.text.engine.toml_codec.writer")
	package.loaded["core.text.engine.toml_codec.writer"] = {
		read_classified = function()
			if content == nil then return nil, "absent" end
			return content, "ok"
		end,
		write = real_writer.write,
	}
	local pushed = nil
	package.loaded["core.ui.ui.webview_manager"] = {
		current_epoch = function() return 41 end,
		eval_js = function(_, code) pushed = code; return true end,
	}
	local ok, err = pcall(function()
		local handler = helpers.load_module("hotstrings.ui.hotstring_editor.bridge")
		local state = { config = { get_config_dir = function() return "/virtual/ergopti/hotstrings" end } }
		helpers.assert_true(handler.push_init(state, { app_name = "hotstring_editor", epoch = 41 }),
			"the opening must be pushed")
	end)
	package.loaded["core.text.engine.toml_codec.writer"] = saved_writer
	package.loaded["core.ui.ui.webview_manager"] = saved_manager
	package.loaded["hotstrings.ui.hotstring_editor.bridge"] = nil
	if not ok then error(err, 0) end
	local encoded = type(pushed) == "string" and pushed:match("window%.initData%((.*)%)$") or nil
	helpers.assert_true(type(encoded) == "string", "the push must call window.initData with a JSON argument")
	return encoded
end

helpers.describe("hotstring editor payload arrays", function()
	helpers.it("sends an absent personal file's sections as an empty JSON array", function()
		local encoded = pushed_payload(nil)
		helpers.assert_true(encoded:find('"sections":[]', 1, true) ~= nil,
			"an absent file must reach the page as sections: [] — got " .. encoded)
		helpers.assert_true(type(Json.decode(encoded)) == "table", "the payload must stay valid JSON")
	end)

	helpers.it("sends a section without entries with an empty JSON entries array", function()
		local encoded = pushed_payload("[[Empty]]\n\n[[Full]]\n\"abc\" = { output = \"alphabet\" }\n")
		helpers.assert_true(encoded:find('"entries":[]', 1, true) ~= nil,
			"an empty section must reach the page as entries: [] — got " .. encoded)
		helpers.assert_true(encoded:find('"alphabet"', 1, true) ~= nil,
			"control: the section with an entry still carries it")
	end)
end)
