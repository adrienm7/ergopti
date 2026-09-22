--- tests/unit/modules/shortcuts/test_script_actions.lua
--- Regression coverage for pause, reload, save-and-reload, and quit actions.

local helpers = require("tests.helpers")

helpers.describe("script lifecycle actions", function()

	local ScriptActions = helpers.load_module("modules.shortcuts.script_actions")

	helpers.it("pauses automation and clears transient text state", function()
		local calls = {}
		local function note(name)
			return function() calls[#calls + 1] = name end
		end
		local controller = ScriptActions.new({
			reset = note("reset"),
			reload = note("reload"),
			quit = note("quit"),
			hide_preview = note("preview"),
			hide_prediction = note("prediction"),
			cancel_prediction = note("cancel"),
		})

		helpers.assert_eq(controller.is_paused(), false)
		controller.handlers.script_pause_toggle()
		helpers.assert_eq(controller.is_paused(), true)
		helpers.assert_eq(calls, { "reset", "preview", "prediction", "cancel" },
			"pausing must discard every transient automation surface")

		controller.handlers.script_pause_toggle()
		helpers.assert_eq(controller.is_paused(), false)
		helpers.assert_eq(calls, { "reset", "preview", "prediction", "cancel" },
			"resuming must not clear state a second time")
	end)

	helpers.it("routes reload and quit with an auditable trigger", function()
		local reloads = {}
		local quits = {}
		local controller = ScriptActions.new({
			reset = function() end,
			reload = function(trigger) reloads[#reloads + 1] = trigger end,
			quit = function(trigger) quits[#quits + 1] = trigger end,
		})

		controller.handlers.script_reload()
		controller.handlers.script_save_reload()
		controller.handlers.script_quit()

		helpers.assert_eq(reloads, {
			"a gesture or shortcut",
			"a save-and-reload gesture or shortcut",
		})
		helpers.assert_eq(quits, { "gesture or shortcut quit" })
	end)

	helpers.it("tells the tray about every pause transition so the menu is rebuilt", function()
		local seen = {}
		local controller = ScriptActions.new({
			reset = function() end,
			reload = function() end,
			quit = function() end,
			on_pause_change = function(paused) seen[#seen + 1] = paused end,
		})
		controller.handlers.script_pause_toggle()
		controller.toggle_pause()
		helpers.assert_eq(seen, { true, false },
			"toggling pause used to leave the tray showing the previous state")
	end)

	helpers.it("lets only the script-control actions through while paused", function()
		local controller = ScriptActions.new({
			reset = function() end, reload = function() end, quit = function() end,
		})
		helpers.assert_true(controller.allows("select_line"), "everything runs while not paused")
		controller.toggle_pause()
		helpers.assert_true(not controller.allows("select_line"), "a feature action waits for resume")
		helpers.assert_true(controller.allows("script_pause_toggle"), "the resume action must stay live")
		helpers.assert_true(controller.allows("script_quit"))
		helpers.assert_true(ScriptActions.is_script_action("script_reload"))
		helpers.assert_true(not ScriptActions.is_script_action("open_url"))
	end)

	helpers.it("holds a user keyboard shortcut back while paused but still resumes", function()
		local storage_before = package.loaded["adapters.storage"]
		local module_before = package.loaded["modules.shortcuts.keyboard_shortcuts"]
		local gestures_before = package.loaded["modules.gestures.manager"]
		local executed = {}
		package.loaded["adapters.storage"] = require("tests.fakes").storage({ initial = {
			["shortcuts.keyboard.ctrl_j"] = "select_line",
			["shortcuts.keyboard.ctrl_k"] = "script_pause_toggle",
		} })
		package.loaded["modules.gestures.manager"] = {
			execute_action = function(action) executed[#executed + 1] = action return true end,
		}
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
		local shortcuts = require("modules.shortcuts.keyboard_shortcuts")
		shortcuts._reset()
		local held_back = shortcuts.dispatch({ key = "j", mods = { ctrl = true } }, { only_script = true })
		local resumed = shortcuts.dispatch({ key = "k", mods = { ctrl = true } }, { only_script = true })
		local chatgpt = shortcuts.dispatch({ key = "g", mods = { ctrl = true } }, { only_script = true })
		package.loaded["adapters.storage"] = storage_before
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = module_before
		package.loaded["modules.gestures.manager"] = gestures_before
		helpers.assert_true(not held_back, "Ctrl+J fired select_line while the script was paused")
		helpers.assert_true(resumed, "the resume shortcut must fire while paused")
		helpers.assert_true(not chatgpt, "the default Ctrl+G must wait for resume too")
		helpers.assert_eq(executed, { "script_pause_toggle" })
	end)

	helpers.it("holds a gesture back while paused but still resumes", function()
		local Gestures = helpers.load_module("modules.gestures.manager")
		local paused = true
		local toggles = 0
		Gestures.init({
			enabled = false, persist = false,
			is_paused = function() return paused end,
			action_handlers = { script_pause_toggle = function() toggles = toggles + 1 end },
		})
		Gestures._test_begin_reading({})
		helpers.assert_true(Gestures.enable(), "the test reader must permit enabling gestures")
		Gestures.set_action("swipe_3_left", "script_pause_toggle")
		Gestures.set_action("swipe_3_right", "select_line")
		helpers.assert_true(not Gestures.dispatch_gesture({ fingers = 3, direction = "right", tap = false }),
			"a feature gesture fired while the script was paused")
		helpers.assert_true(Gestures.dispatch_gesture({ fingers = 3, direction = "left", tap = false }),
			"the resume gesture must fire while paused")
		helpers.assert_eq(toggles, 1)
		Gestures.stop_reading()
	end)

	helpers.it("rejects a controller without lifecycle ownership", function()
		helpers.assert_throws(function()
			ScriptActions.new({ reset = function() end, reload = function() end })
		end, "quit")
	end)

end)
