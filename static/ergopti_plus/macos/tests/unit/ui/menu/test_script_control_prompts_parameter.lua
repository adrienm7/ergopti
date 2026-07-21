--- tests/unit/ui/menu/test_script_control_prompts_parameter.lua

--- ==============================================================================
--- MODULE: Regression — a parameterized action must be configured before binding
--- DESCRIPTION:
--- Binding "Ouvrir un lien" or "Rechercher sur le web" to AltGr+Entrée from the
--- script-control picker produced a key that did nothing at all.
---
--- ROOT CAUSE ENCODED:
--- script_control.ACTIONS is GestActions.SG_NAMES — the FULL gesture action list,
--- open_url and search_web included. Those handlers read
--- get_action_parameter(binding, action) and return silently when it is empty:
---     sg("open_url", function(binding)
---         local url = M.get_action_parameter(binding, "open_url")
---         if M.validate_action_parameter("open_url", url) then open_url(url) end
---     end)
--- The gestures menu prompts for that value before assigning. The script-control
--- picker assigned straight away, so the parameter was never collected and the
--- binding was inert.
---
--- WHY IT WAS SILENT:
--- Every visible signal reported success — the checkmark moved, the preference
--- was saved, the menu rebuilt. Only pressing the key did nothing, and the
--- handler's own guard is what swallowed it: an empty parameter is
--- indistinguishable from "the user asked for nothing".
---
--- The parameter store is keyed by (binding, action) and is agnostic to what
--- `binding` is, so a script-control key name works exactly like a gesture slot —
--- the storage was never the obstacle, only the missing prompt.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ================================================
-- ================================================
-- ======= 1/ The Prompt Lives In One Place =======
-- ================================================
-- ================================================

helpers.describe("the parameter prompt is shared, not duplicated", function()
	helpers.it("shortcut_utils exposes prompt_action_parameter", function()
		package.loaded["ui.menu.shortcut_utils"] = nil
		local SU = helpers.load_with_stubs("ui.menu.shortcut_utils")

		helpers.assert_eq(type(SU.prompt_action_parameter), "function",
			"the prompt must live in the module that already owns shortcut dialogs, so the "
			.. "gestures menu and the script-control picker cannot drift apart on what counts "
			.. "as a valid parameter")
	end)

	helpers.it("stores the value against the binding it was given", function()
		package.loaded["ui.menu.shortcut_utils"] = nil
		local SU = helpers.load_with_stubs("ui.menu.shortcut_utils")

		local stored = {}
		local gestures = {
			get_action_label     = function(a) return a end,
			get_action_parameter = function() return "" end,
			validate_action_parameter = function(_a, v) return v == "https://example.com" end,
			set_action_parameter = function(binding, action, value)
				stored[#stored + 1] = { binding = binding, action = action, value = value }
			end,
		}

		-- dialog_util is stubbed by the harness; drive it to return a valid value.
		local dialog = package.loaded["lib.dialog_util"]
		if type(dialog) == "table" then
			dialog.text_prompt = function() return "Enregistrer", "https://example.com" end
		end

		local ok = SU.prompt_action_parameter(gestures, "return_key", "open_url", "url")

		helpers.assert_true(ok, "a valid value must be accepted")
		helpers.assert_eq(#stored, 1, "exactly one parameter must be stored")
		helpers.assert_eq(stored[1].binding, "return_key",
			"the parameter must be keyed by the SCRIPT-CONTROL key name, not by a gesture "
			.. "slot — the store is keyed by (binding, action) and never cared which kind of "
			.. "binding it was, which is why no new storage layer was needed")
	end)

	helpers.it("stores nothing when the user cancels", function()
		package.loaded["ui.menu.shortcut_utils"] = nil
		local SU = helpers.load_with_stubs("ui.menu.shortcut_utils")

		local stored = 0
		local gestures = {
			get_action_label     = function(a) return a end,
			get_action_parameter = function() return "" end,
			validate_action_parameter = function() return true end,
			set_action_parameter = function() stored = stored + 1 end,
		}
		local dialog = package.loaded["lib.dialog_util"]
		if type(dialog) == "table" then
			dialog.text_prompt = function() return "Annuler", nil end
		end

		local ok = SU.prompt_action_parameter(gestures, "return_key", "open_url", "url")

		helpers.assert_true(not ok, "cancelling must report failure")
		helpers.assert_eq(stored, 0, "cancelling must not store a parameter")
	end)
end)





-- ========================================================
-- ========================================================
-- ======= 2/ The Picker Gates The Assignment On It =======
-- ========================================================
-- ========================================================

helpers.describe("the script-control picker configures before it binds", function()
	helpers.it("asks for a parameter spec before assigning", function()
		-- Selected by a declaration unique to ui/menu/menu_shortcuts.lua rather than
		-- by path. Driving the picker behaviourally needs a full menu context plus a
		-- menubar; what is decidable is that the assignment is gated on the prompt.
		local src = helpers.read_driver_source("local function dyn_script_control")
		helpers.assert_true(src ~= nil, "menu_shortcuts source must be locatable")
		if not src then return end

		local at = src:find("script_control_shortcuts%[keyname%] = a")
		helpers.assert_true(at ~= nil, "the script-control assignment must be locatable")
		if not at then return end

		local window = src:sub(math.max(1, at - 200), at + 1400)
		helpers.assert_true(window:find("get_action_parameter_spec", 1, true) ~= nil,
			"the picker must ask whether the chosen action needs a parameter. Without it, "
			.. "open_url and search_web bind to a key that silently does nothing when pressed")
		helpers.assert_true(window:find("prompt_action_parameter", 1, true) ~= nil,
			"and it must collect that parameter through the shared prompt rather than "
			.. "reimplementing the validate/retry loop the gestures menu already has")
	end)

	helpers.it("does not assign when the prompt is declined", function()
		local src = helpers.read_driver_source("local function dyn_script_control")
		if not src then return end

		local at = src:find("prompt_action_parameter")
		helpers.assert_true(at ~= nil, "the prompt call must be locatable")
		if not at then return end

		local window = src:sub(at, at + 200)
		helpers.assert_true(window:find("if ShortcutUtils%.prompt_action_parameter") ~= nil
			or window:find("then%s*\n?%s*assign") ~= nil,
			"the assignment must sit INSIDE the prompt's success branch — assigning first "
			.. "and prompting after would leave the inert binding in place whenever the user "
			.. "cancels the dialog")
	end)
end)
