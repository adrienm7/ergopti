--- tests/unit/core/ui/webview/test_reading_preferences.lua

--- ==============================================================================
--- MODULE: The Pages Carry the Reading Preferences (Linux)
--- DESCRIPTION:
--- Replays the shared reading-preference vectors and builds a real shared
--- page through core/ui/ui/webkit_host.lua: the reader's font and spacing
--- must reach the page before a11y_prefs.js, the font inlined because
--- WebKitGTK loads the page with no base URL.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("tests.lua.reading_preferences_contract")
Contract.register(helpers, helpers.driver_root() .. "/../_shared")

local WebkitHost = helpers.load_module("core.ui.ui.webkit_host")
Contract.register_host(helpers, "the Linux page builder", function()
	return WebkitHost.build_app_html(helpers.driver_root(), "action_picker", "en", { probe = "Probe" })
end)

helpers.describe("the Linux windows follow a reading choice at once (reading-preferences-live)", function()
	helpers.it("pushes the choice into every open window", function()
		local Manager = require("core.ui.ui.webview_manager")
		local saved_names, saved_eval = Manager.open_app_names, Manager.eval_js
		local pushed = {}
		Manager.open_app_names = function() return { "metrics_typing", "onboarding" } end
		Manager.eval_js = function(app_name, script)
			pushed[app_name] = script
			return app_name == "metrics_typing"
		end
		local ok, err = pcall(Contract.with_store,
			{ ["script.reading_font"] = "hyperlegible", ["script.reading_spacing"] = "wide" }, function()
				helpers.assert_eq(Manager.push_reading_preferences(), 1, "a window that refused the push is not counted")
			end)
		Manager.open_app_names, Manager.eval_js = saved_names, saved_eval
		assert(ok, err)
		for _, app_name in ipairs({ "metrics_typing", "onboarding" }) do
			local script = pushed[app_name]
			helpers.assert_true(type(script) == "string" and script:find("receiveHost", 1, true) ~= nil,
				app_name .. " is pushed the choice")
			helpers.assert_true(script:find('"font":"hyperlegible"', 1, true) ~= nil, app_name .. ": the font")
			helpers.assert_true(script:find("data:font/woff2;base64,", 1, true) ~= nil, app_name .. ": inline")
		end
	end)

	helpers.it("the Configuration menu pushes a saved choice, and only a saved one", function()
		local saved, pushes = {}, 0
		local row = require("settings.ui.menu.configuration").build({
			on_set_reading_preference = function(owner, value)
				saved[#saved + 1] = { owner = owner, value = value }
				return value == "dyslexic"
			end,
			webview = { push_reading_preferences = function() pushes = pushes + 1 end },
		})
		local choices = {}
		for _, item in ipairs(row.submenu) do
			for _, choice in ipairs(item.menu or {}) do choices[#choices + 1] = choice end
		end
		helpers.assert_eq(#choices, 5, "three fonts and two spacings")
		choices[3].fn()
		helpers.assert_eq(saved[1].owner, "core.ui.engine.webview.reading_font")
		helpers.assert_eq(saved[1].value, "dyslexic")
		helpers.assert_eq(pushes, 1, "a saved choice reaches the open windows")
		choices[5].fn()
		helpers.assert_eq(saved[2].owner, "core.ui.engine.webview.reading_spacing")
		helpers.assert_eq(pushes, 1, "a refused choice pushes nothing")
	end)
end)
