--- tests/unit/ui/webview/test_webview_toggle.lua

--- ==============================================================================
--- The three-state toggle behind the shared `open_*` window actions: closed
--- opens, open but behind another window comes to the front, frontmost
--- closes. Driven through the real window pool with only the native GTK
--- edges (create, is-active, destroy) and the raise stubbed, then through the
--- gesture executor so every catalogue window action reaches the toggle.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ The window pool's toggle =======
-- ===========================================
-- ===========================================

helpers.describe("webview toggle (Linux)", function()
	local wm = require("ui.webview_manager")

	--- Runs `body` with the native edges stubbed and restores them after.
	--- @param body function Receives a table whose `active` field is the GTK focus.
	local function with_native(body)
		local real_create, real_raise, real_active, real_destroy =
			wm._create_gtk_window, wm.bring_to_front, wm._gtk_window_active, wm._destroy_gtk_window
		local native = { active = false, focused = 0 }
		wm._create_gtk_window = function() native.active = true; return true end
		-- The raise has its own native-currency tests; here it only records.
		wm.bring_to_front = function() native.focused = native.focused + 1; native.active = true; return true end
		wm._gtk_window_active = function() return native.active end
		wm._destroy_gtk_window = function() return true end
		local ok, err = pcall(body, native)
		if wm.current_epoch("changelog") ~= nil then wm.hide("changelog") end
		wm._create_gtk_window, wm.bring_to_front, wm._gtk_window_active, wm._destroy_gtk_window =
			real_create, real_raise, real_active, real_destroy
		if not ok then error(err, 0) end
	end

	helpers.it("opens a closed page, raises a covered one and closes a frontmost one", function()
		with_native(function(native)
			helpers.assert_true(wm.current_epoch("changelog") == nil, "the fixture starts closed")
			helpers.assert_true(wm.toggle("changelog"), "a closed page opens")
			helpers.assert_true(wm.is_visible("changelog"), "the opened page is visible")

			native.active = false
			helpers.assert_true(wm.toggle("changelog"), "a covered page is raised")
			helpers.assert_eq(native.focused, 1, "raising presents the existing window once")
			helpers.assert_true(wm.is_visible("changelog"), "a covered page is never closed")

			helpers.assert_true(wm.toggle("changelog"), "a frontmost page closes")
			helpers.assert_eq(wm.current_epoch("changelog"), nil, "the closed page leaves the pool")
		end)
	end)

	helpers.it("a closed page with its own opener opens through it, not show()", function()
		with_native(function()
			local calls = 0
			helpers.assert_true(wm.toggle("changelog", function() calls = calls + 1; return true end))
			helpers.assert_eq(calls, 1, "the page's opener runs exactly once")
			helpers.assert_eq(wm.current_epoch("changelog"), nil, "show() was not called behind the opener")
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 2/ Every window action toggles =======
-- ==============================================
-- ==============================================

helpers.describe("window actions reach the toggle (Linux)", function()
	local EXPECTED = {
		open_metrics_typing = "metrics_typing",
		open_metrics_apps = "metrics_apps",
		open_hotstrings_editor = "hotstring_editor",
		open_paths_editor = "paths_editor",
		open_hotstrings_settings = "hotstrings_config_window",
		open_layout_manager = "layout_manager",
		open_layer_editor = "layer_editor",
		open_model_browser = "model_browser",
		open_changelog = "changelog",
		open_healthcheck = "healthcheck",
	}

	helpers.it("each catalogue window action toggles its own page", function()
		local Catalogue = require("_generated.action_catalogue")
		local Gestures = require("modules.gestures.manager")
		local previous = package.loaded["ui.webview_manager"]
		local toggled = {}
		package.loaded["ui.webview_manager"] = {
			toggle = function(app_name, open_fn)
				toggled[#toggled + 1] = { app = app_name, has_opener = open_fn ~= nil }
				return true
			end,
		}
		local ok, err = pcall(function()
			for action_id, app_name in pairs(EXPECTED) do
				helpers.assert_true(Catalogue.actions[action_id] ~= nil,
					"the shared catalogue lists " .. action_id .. " on Linux")
				toggled = {}
				Gestures.execute_action(action_id, "test__slot")
				helpers.assert_eq(#toggled, 1, action_id .. " toggles exactly one window")
				helpers.assert_eq(toggled[1].app, app_name, action_id .. " toggles its own page")
				helpers.assert_eq(toggled[1].has_opener, app_name == "healthcheck",
					action_id .. ": only the diagnostics page opens through its bridge")
			end
		end)
		package.loaded["ui.webview_manager"] = previous
		if not ok then error(err, 0) end
	end)
end)
