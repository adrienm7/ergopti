--- tests/unit/ui/test_config_dir_write_failure_propagation.lua

--- ==============================================================================
--- MODULE: Config-Directory Write-Failure Propagation
--- DESCRIPTION:
--- Proves both UI callers honor ConfigPaths' confirmed-write contract.
---
--- ROOT CAUSE ENCODED:
--- The path editor discarded set_config_dir()'s failure reason, closed its last
--- copy of the user's input, and reloaded. The onboarding wrapper returned
--- nothing, while commit() checked only whether pcall itself raised; a normal
--- `false, reason` result therefore retargeted config.toml and completed the
--- wizard as though paths.toml had been saved.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real paths editor around a refusing ConfigPaths double and captures
--- the actual usercontent callback.
--- @return table menu_paths
--- @return table calls
local function load_refusing_editor()
	local calls = { reloads = 0, deletes = 0, dialogs = 0, errors = {}, callback = nil }
	local logger = helpers.make_logger_stub()
	logger.error = function(_, fmt, ...)
		calls.errors[#calls.errors + 1] = string.format(fmt, ...)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.config_paths"] = {
		is_initialized = function() return true end,
		get = function() return "/old/hammerspoon/config.toml" end,
		get_config_dir = function() return "/old/" end,
		get_default_config_dir = function() return "/default/" end,
		set_config_dir = function() return false, "permission denied" end,
	}
	package.loaded["infra.dialog_util"] = {
		block_alert = function() calls.dialogs = calls.dialogs + 1 end,
	}
	local webview = {
		delete = function() calls.deletes = calls.deletes + 1 end,
		evaluateJavaScript = function() return true end,
	}
	package.loaded["ui.ui_builder"] = {
		get_app_geometry = function() return { width = 620, height = 480 } end,
		get_centered_frame = function() return { x = 0, y = 0, w = 620, h = 300 } end,
		show_webview = function(opts)
			if type(opts.on_webview_created) == "function"
				and opts.on_webview_created(webview) ~= true then return nil end
			return webview
		end,
		force_focus = function() return true end,
	}

	local MenuPaths = helpers.load_with_stubs("ui.menu.menu_paths", {
		webview = {
			usercontent = {
				new = function()
					return {
						setCallback = function(_, callback)
							calls.callback = callback
							return true
						end,
					}
				end,
			},
			windowMasks = { titled = 1, closable = 2 },
		},
		screen = {
			mainScreen = function()
				return { frame = function() return { w = 1920, h = 1080 } end }
			end,
		},
	})
	helpers.assert_true(MenuPaths.init("/Applications/ErgoptiPlus.app/", function()
		calls.reloads = calls.reloads + 1
	end))
	helpers.assert_true(MenuPaths.open_editor())
	helpers.assert_type(calls.callback, "function")
	return MenuPaths, calls
end

helpers.describe("config-directory UIs stop on an unconfirmed bootstrap write", function()
	helpers.it("config-dir write: keeps the path editor open and never reloads", function()
		local _, calls = load_refusing_editor()
		calls.callback({ body = { action = "save", configDir = "/new/" } })

		helpers.assert_eq(calls.reloads, 0,
			"reload would erase the only visible evidence of the refused save")
		helpers.assert_eq(calls.deletes, 0,
			"the editor must retain the user's input so they can retry")
		helpers.assert_eq(calls.dialogs, 1,
			"the failure must be visible to the user, not only the file logger")
		helpers.assert_true(#calls.errors >= 1)
	end)

	helpers.it("config-dir write: treats onboarding's returned false like a raise", function()
		package.loaded["ui.onboarding"] = nil
		local Onboarding = helpers.load_with_stubs("ui.onboarding")
		local refusing = {
			persist_config_dir_for_wizard = function()
				return false, "permission denied"
			end,
		}
		local raising = {
			persist_config_dir_for_wizard = function()
				error("disk unavailable")
			end,
		}

		local ok_return, err_return = Onboarding._persist_config_dir(refusing, "/new/")
		helpers.assert_true(ok_return == false)
		helpers.assert_true(tostring(err_return):find("permission denied", 1, true) ~= nil)

		local ok_raise, err_raise = Onboarding._persist_config_dir(raising, "/new/")
		helpers.assert_true(ok_raise == false)
		helpers.assert_true(tostring(err_raise):find("disk unavailable", 1, true) ~= nil)
	end)

	helpers.it("config-dir write: accepts only an explicit confirmation", function()
		package.loaded["ui.onboarding"] = nil
		local Onboarding = helpers.load_with_stubs("ui.onboarding")
		local success = {
			persist_config_dir_for_wizard = function() return true, false end,
		}
		local silent = {
			persist_config_dir_for_wizard = function() return nil end,
		}

		helpers.assert_true(Onboarding._persist_config_dir(success, "/same/") == true,
			"an unchanged but durably confirmed path is a successful persistence")
		helpers.assert_true(Onboarding._persist_config_dir(silent, "/new/") == false,
			"nil is not proof that paths.toml was written")
	end)
end)
