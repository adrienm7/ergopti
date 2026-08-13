--- tests/unit/adapters/test_activation_return_contract.lua

--- ==============================================================================
--- MODULE: Activation return-value contract tests
--- DESCRIPTION:
--- Hammerspoon application activation/launch APIs return booleans, while
--- hs.window:focus returns the window object for chaining. These tests drive the
--- real adapters and user-triggered shortcut without conflating either contract.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================================
-- ===========================================================
-- ======= 1/ Adapter Return Values ===========================
-- ===========================================================
-- ===========================================================

helpers.describe("activation adapters: false native results remain failures", function()
	helpers.it("WindowManager.activate propagates application false", function()
		local adapter = helpers.load_with_stubs("adapters.window_manager", {
			application = {
				get = function()
					return { activate = function() return false end }
				end,
			},
		})
		helpers.assert_eq(false, adapter.activate("Safari"),
			"a found application is not activated until app:activate() says true")
	end)

	helpers.it("WindowManager.activate propagates window false", function()
		local adapter = helpers.load_with_stubs("adapters.window_manager", {
			window = {
				get = function()
					return { focus = function() return false end }
				end,
			},
		})
		helpers.assert_eq(false, adapter.activate(42),
			"a found window is not focused until win:focus() says true")
	end)

	helpers.it("WindowManager.activate accepts the documented window-object focus result", function()
		local manager = helpers.load_with_stubs("adapters.window_manager", {
			window = {
				get = function()
					local win = {}
					win.focus = function() return win end
					return win
				end,
			},
		})
		helpers.assert_eq(true, manager.activate(42),
			"hs.window:focus returns the window object, not literal true")
	end)
end)





-- ===========================================================
-- ===========================================================
-- ======= 2/ User Shortcut Fallback ==========================
-- ===========================================================
-- ===========================================================

helpers.describe("file-manager shortcut: a refused running app falls through", function()
	helpers.it("tries the next activation path after app:activate() false", function()
		local shell_opens = 0
		package.loaded["adapters.shell_runner"] = {
			open = function() shell_opens = shell_opens + 1; return true end,
		}
		package.loaded["adapters.window_manager"] = {
			activate = function() return false end,
		}
		package.loaded["adapters.app_launcher"] = {
			launch = function() return false end,
		}
		package.loaded["adapters.timer_scheduler"] = {
			after = function() return true end,
		}
		package.loaded["adapters.clipboard"] = {
			get_text = function() return "" end,
		}
		package.loaded["infra.config_paths"] = {
			get_config_dir = function() return "/tmp/ergopti" end,
		}
		package.loaded["infra.dialog_util"] = { alert = function() end }

		local actions = helpers.load_with_stubs("modules.shortcuts.actions.apps", {
			application = {
				runningApplications = function()
					return {
						{
							name = function() return "Finder" end,
							activate = function() return false end,
						},
					}
				end,
			},
		})
		actions.open_finder()

		helpers.assert_eq(1, shell_opens,
			"false activation must reach the final path-open fallback instead of being "
				.. "reported as a successful user action")
	end)
end)
