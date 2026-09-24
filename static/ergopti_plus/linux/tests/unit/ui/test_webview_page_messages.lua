--- tests/unit/ui/test_webview_page_messages.lua

--- ==============================================================================
--- MODULE: What A Page Says Reaches Its Bridge, And Back
--- DESCRIPTION:
--- Page messages that are objects ({action:'save', …}) were decoded only
--- through dkjson, which is neither shipped nor installed, so they arrived as
--- nil; replies were dropped for the same reason. The metrics windows stayed
--- empty and the prompt editor's Save, the numeric prompt and the model
--- browser's buttons did nothing. The bridge tests routed Lua tables directly
--- and never crossed this conversion.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- A WebKit JavaScriptCore value holding a posted object.
--- @param json string What JSON.stringify gives for it.
--- @return table
local function js_object(json)
	return {
		is_string = function() return false end,
		is_number = function() return false end,
		is_boolean = function() return false end,
		is_null = function() return false end,
		is_undefined = function() return false end,
		is_object = function() return true end,
		to_json = function() return json end,
	}
end

helpers.describe("webview pages: messages and replies cross the bridge", function()

	helpers.it("decodes an object a page posts", function()
		local wm = require("ui.webview_manager")
		local message = wm._js_value_to_lua_for_test(
			js_object('{"action":"save","edit_id":"user_1","batch":false,"prompt":"Écris la suite"}'))
		helpers.assert_true(type(message) == "table", "the object reaches the bridge as a table")
		helpers.assert_eq(message.action, "save")
		helpers.assert_eq(message.batch, false)
		helpers.assert_eq(message.prompt, "Écris la suite")
	end)

	helpers.it("sends a reply the page can decode", function()
		local wm = require("ui.webview_manager")
		local script
		local webview = { run_javascript = function(_, code) script = code end }
		local reply = { metrics_manifest = { today = { n = 3 } } }
		wm._send_response_to_js_for_test(webview, "metrics_typing_bridge", reply)
		helpers.assert_true(script ~= nil, "a reply is sent")
		local encoded = script:match("'metrics_typing_bridge',true,'([^']+)'")
		helpers.assert_eq(encoded, require("compat.base64").encode(Json.encode(reply)),
			"the page receives the reply as base64 JSON")
	end)

end)

helpers.describe("webview pages: shown in the interface's language", function()

	helpers.it("builds the page in the tray's locale when the caller names none", function()
		local built_with
		local previous = {
			host = package.loaded["ui.webkit_host"],
			manager = package.loaded["ui.webview_manager"],
			i18n = package.loaded["infra.i18n"],
		}
		local host = {}
		for key, value in pairs(require("ui.webkit_host")) do host[key] = value end
		host.build_app_html = function(_, _, locale) built_with = locale; return "" end
		package.loaded["ui.webkit_host"] = host
		package.loaded["infra.i18n"] = { get_locale = function() return "en" end, get = function(key) return key end }
		package.loaded["ui.webview_manager"] = nil
		local ok, err = pcall(function() require("ui.webview_manager").show("numeric_prompt") end)
		package.loaded["ui.webkit_host"] = previous.host
		package.loaded["ui.webview_manager"] = previous.manager
		package.loaded["infra.i18n"] = previous.i18n
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(built_with, "en", "every window used to be French")
	end)

end)
