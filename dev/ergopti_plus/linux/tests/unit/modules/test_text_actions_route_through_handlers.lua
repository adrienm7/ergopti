--- tests/unit/modules/test_text_actions_route_through_handlers.lua

--- ==============================================================================
--- MODULE: Text actions reach the shortcuts manager through the daemon handlers
--- DESCRIPTION:
--- A gesture or keyboard slot bound to a text action (selection, plain paste,
--- case) must run the shortcuts manager's implementation, the one the tray row
--- runs, through the handlers the daemon injects
--- (modules/shortcuts/action_handlers.lua), and do what the action says.
---
--- ROOT CAUSES ENCODED:
--- 1. select_word and paste_plain were tray-only: the catalogue did not offer
---    them on Linux, so no binding could run them.
--- 2. select_line was a second route in the gesture layer (a lazy require of
---    the shortcuts manager) instead of the injected handlers every other
---    daemon-owned action goes through.
--- 3. select_word pressed Ctrl+Shift+Left only, which selects from the caret
---    to the start of the word, not the word.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the gestures manager with the daemon's composed handlers over a
--- recording clipboard, key emitter and injector.
--- @return table gestures, table log
local function routed_gestures()
	local names = {
		clipboard = "adapters.clipboard",
		event_loop = "adapters.event_loop",
		combo = "modules.gestures.combo_emitter",
		injector = "modules.hotstrings.injector",
		keylogger = "modules.keylogger.keylogger",
	}
	local log = { presses = {}, injected = {}, transformed = {} }
	package.loaded[names.clipboard] = {
		transform_selection = function(transform)
			log.transformed[#log.transformed + 1] = transform("été")
			return true
		end,
		read_checked = function() return true, "plain clipboard", nil end,
	}
	package.loaded[names.event_loop] = { sleep_ms = function() return true end }
	package.loaded[names.combo] = {
		press = function(combo)
			log.presses[#log.presses + 1] = combo
			return true
		end,
	}
	package.loaded[names.injector] = {
		inject = function(_, text)
			log.injected[#log.injected + 1] = text
			return { ok = true }
		end,
	}
	package.loaded[names.keylogger] = { record_shortcut = function() return true end }
	package.loaded["modules.shortcuts.manager"] = nil

	local Shortcuts = require("modules.shortcuts.manager")
	local ScriptActions = helpers.load_module("modules.shortcuts.script_actions")
	local ActionHandlers = helpers.load_module("modules.shortcuts.action_handlers")
	local noop = function() end
	local Gestures = helpers.load_module("modules.gestures.manager")
	Gestures.init({
		enabled = false,
		persist = false,
		action_handlers = ActionHandlers.compose(
			ScriptActions.new({ reset = noop, reload = noop, quit = noop }).handlers, Shortcuts),
	})
	log.restore = function()
		for _, name in pairs(names) do package.loaded[name] = nil end
		package.loaded["modules.shortcuts.manager"] = nil
	end
	return Gestures, log
end

helpers.describe("Linux text actions route through the daemon handlers", function()
	helpers.it("select_word selects the whole word, select_line the line", function()
		local Gestures, log = routed_gestures()
		local ok, err = pcall(function()
			Gestures.execute_action("select_word", "keyboard__ctrl_j")
			helpers.assert_eq(table.concat(log.presses, " / "), "ctrl+Right / ctrl+shift+Left",
				"select_word must move to the end of the word, then select back to its start")
			log.presses = {}
			Gestures.execute_action("select_line", "swipe_3_up")
			helpers.assert_eq(table.concat(log.presses, " / "), "Home / shift+End")
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("paste_plain types the clipboard's plain text", function()
		local Gestures, log = routed_gestures()
		local ok, err = pcall(function()
			Gestures.execute_action("paste_plain", "keyboard__ctrl_shift_v")
			helpers.assert_eq(#log.injected, 1, "paste_plain must inject exactly once")
			helpers.assert_eq(log.injected[1], "plain clipboard")
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("the case actions transform the selection", function()
		local Gestures, log = routed_gestures()
		local ok, err = pcall(function()
			Gestures.execute_action("selection_uppercase", "tap_3")
			Gestures.execute_action("titlecase_selection", "tap_3")
			helpers.assert_eq(table.concat(log.transformed, " / "), "ÉTÉ / Été")
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("wrap_selection wraps with the pair stored for its binding", function()
		local Gestures, log = routed_gestures()
		local ok, err = pcall(function()
			helpers.assert_true(Gestures.set_action_parameter("tap_3", "wrap_selection", "«"))
			Gestures.execute_action("wrap_selection", "tap_3")
			helpers.assert_eq(table.concat(log.transformed, " / "), "« été »")
			Gestures.execute_action("wrap_selection", "tap_4")
			helpers.assert_eq(#log.transformed, 1,
				"a binding without a stored pair must not wrap anything")
			helpers.assert_eq(#log.injected, 0, "nor type a pair in place of a selection")
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("surround_parens wraps the current line, as on Windows", function()
		local Gestures, log = routed_gestures()
		local ok, err = pcall(function()
			Gestures.execute_action("surround_parens", "tap_3")
			helpers.assert_eq(table.concat(log.presses, " / "), "Home / End / Home")
			helpers.assert_eq(table.concat(log.injected, " / "), "( / )")
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("the text actions exist only through the injected handlers", function()
		local Gestures = helpers.load_module("modules.gestures.manager")
		Gestures.init({ enabled = false, persist = false })
		local runnable = {}
		for _, id in ipairs({ "select_line", "select_word", "paste_plain", "selection_uppercase" }) do
			if Gestures.is_runnable(id) then runnable[#runnable + 1] = id end
		end
		helpers.assert_eq(table.concat(runnable, ", "), "",
			"without the daemon's handlers no second copy may answer a text action")
	end)
end)
