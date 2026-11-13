--- tests/unit/gestures/engine/actions/test_system_layer_actions.lua

--- ==============================================================================
--- MODULE: Shortcut-layer system functions exposed as catalogue actions
--- DESCRIPTION:
--- The emoji picker, display mirroring and keep-awake existed only as fixed
--- shortcut-layer hotkeys (Ctrl+., Ctrl+P, Ctrl+M), so no gesture or keyboard
--- slot could bind them. The emoji picker and the mirror toggle run in the
--- parent-scoped mouse owner under the dispatching parent; keep-awake is one
--- session toggle whatever triggered it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gestures.actions_fixture")
local it = Fixture.it

helpers.describe("gesture actions reach the shortcut layer's system functions", function()
	it("runs the emoji picker and the mirror toggle under the dispatching parent", function(fresh_actions)
		local actions, calls = fresh_actions()
		for action_id, method in pairs({
			open_emoji_picker = "open_emoji_picker",
			display_mirror_toggle = "toggle_display_mirror",
		}) do
			helpers.assert_eq(actions.execute_single(action_id), true,
				action_id .. " must be a registered gesture action")
			local last = calls.mouse_actions[#calls.mouse_actions]
			helpers.assert_eq(last.name, method)
			helpers.assert_eq(last.parent, "gestures")
			helpers.assert_eq(actions.execute_single(action_id, "keyboard__primary_1"), true)
			helpers.assert_eq(calls.mouse_actions[#calls.mouse_actions].parent, "shortcut_bindings")
		end
	end)

	it("toggles keep-awake through the shortcut layer's session", function(fresh_actions)
		local saved = package.loaded["shortcuts.engine.actions.system"]
		local toggles = 0
		package.loaded["shortcuts.engine.actions.system"] = {
			toggle_awake = function() toggles = toggles + 1; return true end,
		}
		local ok, err = pcall(function()
			local actions = fresh_actions()
			helpers.assert_eq(actions.execute_single("activity_simulation"), true)
			helpers.assert_eq(toggles, 1, "activity_simulation must toggle the keep-awake session")
		end)
		package.loaded["shortcuts.engine.actions.system"] = saved
		helpers.assert_true(ok, tostring(err))
	end)

	it("opens the Ctrl+G page under the dispatching parent (action-parity-open-chatgpt)", function(fresh_actions)
		-- open_chatgpt existed on Windows and Linux only; macOS had just its
		-- Ctrl+G shortcut, whose URL owner the action must share.
		-- fresh_actions() installs the fixture's owners; these replace two of
		-- them for this case and are put back before the fixture restores its own.
		local actions = fresh_actions()
		local saved_bindings = package.loaded["shortcuts.engine.bindings"]
		local saved_apps = package.loaded["shortcuts.engine.actions.apps"]
		local opened = {}
		package.loaded["shortcuts.engine.bindings"] = {
			get_chatgpt_url = function() return "https://chat.example.test/" end,
		}
		package.loaded["shortcuts.engine.actions.apps"] = {
			open_chatgpt = function(url, parent)
				opened[#opened + 1] = { url = url, parent = parent }
				return true
			end,
		}
		local ok, err = pcall(function()
			helpers.assert_eq(actions.execute_single("open_chatgpt"), true, "open_chatgpt must be registered")
			helpers.assert_eq(actions.execute_single("open_chatgpt", "keyboard__primary_1"), true)
			helpers.assert_eq(opened, {
				{ url = "https://chat.example.test/", parent = "gestures" },
				{ url = "https://chat.example.test/", parent = "shortcut_bindings" },
			})
		end)
		package.loaded["shortcuts.engine.bindings"] = saved_bindings
		package.loaded["shortcuts.engine.actions.apps"] = saved_apps
		helpers.assert_true(ok, tostring(err))
	end)
end)
