--- tests/unit/modules/shortcuts/keyboard/test_script_actions.lua
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

	-- SCD-1: the pause admits the shared catalogue's paused_actions, the list
	-- Windows and macOS read, not every id with the script_ prefix.
	helpers.it("reads the shared paused_actions list, not the script_ prefix (scd1-paused-actions)", function()
		local controller = ScriptActions.new({
			reset = function() end, reload = function() end, quit = function() end,
		})
		controller.toggle_pause()
		helpers.assert_true(not controller.allows("script_save_reload"),
			"script_save_reload is not a paused action of the shared catalogue")
		helpers.assert_true(controller.allows("open_personal_shortcuts"),
			"open_personal_shortcuts is a paused action of the shared catalogue")
		helpers.assert_true(ScriptActions.runs_while_paused("script_reload"))
		helpers.assert_true(not ScriptActions.runs_while_paused("script_save_reload"))
	end)

	helpers.it("holds every keyboard slot back while paused, a script action included (scd1-slot-paused)", function()
		local storage_before = package.loaded["core.fs.adapters.storage"]
		local module_before = package.loaded["modules.shortcuts.keyboard_shortcuts"]
		local gestures_before = package.loaded["gestures.engine.manager"]
		local paths_before = package.loaded["settings.engine.paths"]
		local path = os.tmpname()
		require("tests.lua.settings.unused_keys_contract").sandbox.write_bytes(path,
			'[shortcuts.keyboard]\nprimary_j = "select_line"\nprimary_k = "script_pause_toggle"\n')
		package.loaded["settings.engine.paths"] = { config = function() return path end }
		local executed = {}
		package.loaded["core.fs.adapters.storage"] = require("tests.fakes").storage({ initial = {
			["shortcuts.keyboard.primary_j"] = "select_line",
			["shortcuts.keyboard.primary_k"] = "script_pause_toggle",
		} })
		package.loaded["gestures.engine.manager"] = {
			-- The loader keeps only the ids the catalogue offers; both stored ones are.
			is_assignable = function(action)
				return action == "select_line" or action == "script_pause_toggle"
			end,
			execute_action = function(action) executed[#executed + 1] = action return true end,
		}
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
		local shortcuts = require("modules.shortcuts.keyboard_shortcuts")
		shortcuts._reset()
		local held_back = shortcuts.dispatch({ key = "j", mods = { ctrl = true } }, { only_script = true })
		local running = shortcuts.dispatch({ key = "k", mods = { ctrl = true } }, { only_script = false })
		local resumed = shortcuts.dispatch({ key = "k", mods = { ctrl = true } }, { only_script = true })
		local chatgpt = shortcuts.dispatch({ key = "g", mods = { ctrl = true } }, { only_script = true })
		package.loaded["core.fs.adapters.storage"] = storage_before
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = module_before
		package.loaded["gestures.engine.manager"] = gestures_before
		package.loaded["settings.engine.paths"] = paths_before
		os.remove(path)
		helpers.assert_true(not held_back, "Ctrl+J fired select_line while the script was paused")
		helpers.assert_true(not resumed,
			"a keyboard slot bound to script_pause_toggle fired while paused, unlike Windows and macOS")
		helpers.assert_true(not chatgpt, "the default Ctrl+G must wait for resume too")
		helpers.assert_true(running, "the same slot runs while the driver runs")
		helpers.assert_eq(executed, { "script_pause_toggle" })
	end)

	helpers.it("holds a gesture back while paused but still resumes", function()
		local Gestures = helpers.load_module("gestures.engine.manager")
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


helpers.describe("pause transition acknowledgement", function()
	for _, result in ipairs({ "nil", "true", "false", "throw" }) do
		helpers.it("acknowledges a " .. result .. " listener result", function()
			local calls = 0
			local controller = require("modules.shortcuts.script_actions").new({ reset = function() end,
				reload = function() end, quit = function() end,
				on_pause_change = function()
					calls = calls + 1
					if result == "throw" then error("listener failed") end
					if result == "false" then return false end
					if result == "true" then return true end
				end })
			helpers.assert_eq(controller.toggle_pause(), result == "nil" or result == "true")
			helpers.assert_true(controller.is_paused())
			helpers.assert_eq(calls, 1, "acknowledgement does not apply a second transition")
		end)
	end
end)


-- A pause and a resume were silent on Linux while macOS announced both: a user
-- who hit the pause chord by accident had no sign the driver had stopped.
helpers.describe("pause and resume notices", function()
	local ScriptActions = helpers.load_module("modules.shortcuts.script_actions")

	local function controller_with(notices, on_pause_change)
		return ScriptActions.new({ reset = function() end, reload = function() end, quit = function() end,
			on_pause_change = on_pause_change,
			notify = function(key, level) notices[#notices + 1] = key .. "/" .. level end })
	end

	helpers.it("announces a pause as a warning and a resume as a success", function()
		local notices = {}
		local controller = controller_with(notices)
		helpers.assert_eq(controller.toggle_pause(), true)
		helpers.assert_eq(controller.toggle_pause(), true)
		helpers.assert_eq(notices, { "script_control.paused/warning", "script_control.resumed/success" })
	end)

	helpers.it("announces nothing when the transition listener refused", function()
		local notices = {}
		local controller = controller_with(notices, function() return false end)
		helpers.assert_eq(controller.toggle_pause(), false)
		helpers.assert_eq(notices, {}, "a refused transition must not claim it happened")
	end)

	helpers.it("keeps a committed transition when the notice itself fails", function()
		local controller = ScriptActions.new({ reset = function() end, reload = function() end,
			quit = function() end, notify = function() error("no desktop") end })
		helpers.assert_eq(controller.toggle_pause(), true)
		helpers.assert_true(controller.is_paused())
	end)

	helpers.it("is wired by the daemon to the application notifier with the notice level", function()
		local source = assert(helpers.read_driver_unit("local script_actions = ScriptActions.new({"))
		local construction = assert(source:match("local script_actions = ScriptActions%.new%(%{(.-)\n\t%}%)"))
		helpers.assert_true(construction:find(
			"notify = notifier and function(key, level)\n"
				.. "\t\t\treturn notifier.send(require(\"core.i18n.engine.i18n\").get(key), { level = level })", 1, true) ~= nil,
			"the daemon must pass the notice to the desktop, translated, at its level")
	end)

	helpers.it("uses the keys and levels macOS publishes, each translated in English", function()
		local path = helpers.driver_root() .. "/../macos/modules/shortcuts/script_control.lua"
		local handle = assert(io.open(path, "rb"))
		local mac = assert(handle:read("*a"))
		handle:close()
		local publish = assert(mac:match("local function publish_pause_state%(target_paused%)(.-)\nend\n"),
			"macOS publish_pause_state moved: re-pin the cross-driver notice contract")
		local catalogue_handle = assert(io.open(helpers.driver_root() .. "/../_shared/core/i18n/data/locales/en.json", "rb"))
		local catalogue = assert(catalogue_handle:read("*a"))
		catalogue_handle:close()
		for _, paused in ipairs({ true, false }) do
			local notice = ScriptActions.PAUSE_NOTICES[paused]
			helpers.assert_true(publish:find(string.format("notifications.notify(i18n.get(%q), nil, %q)",
				notice.key, notice.level), 1, true) ~= nil, "macOS and Linux disagree on " .. notice.key)
			helpers.assert_true(catalogue:find('"' .. notice.key .. '":', 1, true) ~= nil,
				notice.key .. " is missing from the shared en.json")
		end
	end)
end)
