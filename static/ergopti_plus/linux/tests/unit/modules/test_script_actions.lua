--- tests/unit/modules/test_script_actions.lua
--- Regression coverage for pause, reload, save-and-reload, and quit actions.

local helpers = require("tests.helpers")

helpers.describe("script lifecycle actions", function()

	local ScriptActions = helpers.load_module("modules.runtime.script_actions")

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

	helpers.it("rejects a controller without lifecycle ownership", function()
		helpers.assert_throws(function()
			ScriptActions.new({ reset = function() end, reload = function() end })
		end, "quit")
	end)

end)
