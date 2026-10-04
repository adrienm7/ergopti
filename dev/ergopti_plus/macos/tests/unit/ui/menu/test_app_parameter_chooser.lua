--- tests/unit/ui/menu/test_app_parameter_chooser.lua

--- ==============================================================================
--- MODULE: The app parameter is picked, not typed (macOS)
--- DESCRIPTION:
--- Binding open_app from the gestures menu or the shortcut editors opens the
--- /Applications chooser (dialog_util.choose_application) instead of a text
--- prompt; the chosen bundle is validated and stored against the binding, and
--- a cancelled chooser stores nothing.
---
--- ROOT CAUSE ENCODED:
--- open_app needs an application: a free-text prompt would leave the user to
--- guess an application's exact name or bundle identifier.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- A gestures facade whose store records what it is given.
--- @param stored table Receives { binding, action, value } rows.
--- @return table
local function facade(stored)
	return {
		get_action_label = function(action) return action end,
		parameter_prompt = function() return "Application to open:" end,
		parameter_error = function() return "refused" end,
		get_action_parameter = function() return "" end,
		validate_action_parameter = function(_, value) return type(value) == "string" and value ~= "" end,
		set_action_parameter = function(binding, action, value)
			stored[#stored + 1] = { binding = binding, action = action, value = value }
			return true
		end,
	}
end

helpers.describe("open_app parameter chooser (macOS)", function()
	helpers.it("the chooser's application is stored against the binding", function()
		package.loaded["ui.menu.shortcut_utils"] = nil
		local SU = helpers.load_with_stubs("ui.menu.shortcut_utils")
		local dialog = package.loaded["infra.dialog_util"]
		local asked = {}
		local titles = {}
		dialog.choose_application = function(message, title)
			asked[#asked + 1] = message
			titles[#titles + 1] = title
			return "/Applications/Safari.app"
		end
		dialog.text_prompt = function() error("an application is never typed") end

		local stored = {}
		helpers.assert_eq(SU.prompt_action_parameter(facade(stored), "keyboard__cmd_1", "open_app", "app"), true)
		helpers.assert_eq(asked, { "Application to open:" })
		helpers.assert_eq(titles, { SU.action_parameter_title("open_app") }, "the parameter caption reaches the native owner")
		helpers.assert_eq(stored, { { binding = "keyboard__cmd_1", action = "open_app", value = "/Applications/Safari.app" } })
	end)

	helpers.it("choose_application opens /Applications on application bundles only", function()
		local calls, focuses = {}, 0
		local answer = "/Applications/Notes.app"
		local Dialog = helpers.load_with_stubs("infra.dialog_util", {
			focus = function() focuses = focuses + 1; return true end,
			osascript = { applescript = function(script)
				calls[#calls + 1] = script
				return true, answer, ""
			end },
		})
		helpers.assert_eq(Dialog.choose_application("Application to open:", "Configure application"), "/Applications/Notes.app")
		local script = calls[1]
		for _, command in ipairs({
			"set panel to current application's NSOpenPanel's openPanel()",
			[[panel's setTitle:"ErgoptiPlus — Configure application"]],
			[[panel's setMessage:"Application to open:"]],
			[[panel's setDirectoryURL:(current application's NSURL's fileURLWithPath:"/Applications")]],
			[[panel's setCanChooseFiles:true]], [[panel's setCanChooseDirectories:false]],
			[[panel's setAllowsMultipleSelection:false]], [[panel's setAllowedFileTypes:{"app"}]],
			[[panel's setResolvesAliases:true]],
			"set response to panel's runModal()",
			"if response is not (current application's NSModalResponseOK) then return missing value",
			"return (chosenURL's |path|()) as text",
		}) do
			helpers.assert_true(script:find(command, 1, true) ~= nil, command)
		end
		helpers.assert_eq(focuses, 2, "the existing native focus owner makes both synchronous focus requests")
		answer = nil
		helpers.assert_eq(Dialog.choose_application("Application to open:", "Configure application"), nil, "cancelled")
	end)

	helpers.it("a cancelled chooser stores nothing", function()
		package.loaded["ui.menu.shortcut_utils"] = nil
		local SU = helpers.load_with_stubs("ui.menu.shortcut_utils")
		package.loaded["infra.dialog_util"].choose_application = function() return nil end

		local stored = {}
		helpers.assert_eq(SU.prompt_action_parameter(facade(stored), "tap_3", "open_app", "app"), false)
		helpers.assert_eq(#stored, 0)
	end)
	helpers.it("forwards the existing parameter caption in all 21 languages", function()
		local locales = { "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
			"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }
		local label = 'Application "quoted" %s'
		for _, code in ipairs(locales) do
			local file = assert(io.open(helpers.shared("data/locales/" .. code .. ".json"), "r"))
			local strings = Json.decode(file:read("*a")); file:close()
			local template = strings["dialog.gestures.param_title"]
			local first = assert(template:find("{1}", 1, true))
			local expected = template:sub(1, first - 1) .. label .. template:sub(first + 3)
			helpers.with_stub_scope({ "ui.menu.shortcut_utils", "infra.dialog_util", "infra.i18n", "window_titles" }, function()
				local scripts = {}
				helpers.load_with_stubs("infra.dialog_util", { osascript = { applescript = function(script)
					scripts[#scripts + 1] = script
					return true, nil, ""
				end } })
				local SU = helpers.load_with_stubs("ui.menu.shortcut_utils")
				package.loaded["infra.i18n"].get = function(key) return strings[key] or key end
				local stored = {}
				local owner = facade(stored)
				owner.get_action_label = function() return label end
				helpers.assert_eq(SU.prompt_action_parameter(owner, "keyboard__cmd_1", "open_app", "app"), false)
				helpers.assert_eq(#scripts, 1, "the real caller reaches one actual native port")
				local escaped = expected:gsub("\\", "\\\\"):gsub('"', '\\"')
				helpers.assert_true(scripts[1]:find([[panel's setTitle:"ErgoptiPlus — ]] .. escaped .. '"', 1, true) ~= nil, code)
				helpers.assert_true(scripts[1]:find([[panel's setMessage:"Application to open:"]], 1, true) ~= nil, code)
				helpers.assert_eq(#stored, 0, "cancelled captioned chooser stores nothing")
			end)
		end
	end)

	helpers.it("uses the shared caption policy before escaping or removing the prefix", function()
		for _, policy in ipairs({ 'Other "product" C:\\', "" }) do
			helpers.with_stub_scope({ "infra.dialog_util", "window_titles" }, function()
				local observed = {}
				package.loaded["window_titles"] = { compose = function(title)
					observed[#observed + 1] = title
					return policy .. title
				end }
				local Dialog = helpers.load_with_stubs("infra.dialog_util")
				local script = Dialog.application_picker_script('Body "quoted" %s', 'App "quoted" %s')
				local expected = policy == "" and [[App \"quoted\" %s]] or [[Other \"product\" C:\\App \"quoted\" %s]]
				helpers.assert_eq(observed, { 'App "quoted" %s' }, "the policy receives the untranslated bare title once")
				helpers.assert_true(script:find('panel\'s setTitle:"' .. expected .. '"', 1, true) ~= nil, script)
				helpers.assert_true(script:find([[panel's setMessage:"Body \"quoted\" %s"]], 1, true) ~= nil, "the body is escaped independently")
			end)
		end
	end)

	helpers.it("refuses native execution failure instead of claiming cancellation or storing", function()
		local calls = 0
		local Dialog = helpers.load_with_stubs("infra.dialog_util", { osascript = { applescript = function()
			calls = calls + 1
			return false, nil, "private native failure payload"
		end } })
		local ok, err = pcall(Dialog.choose_application, "Application to open:", "Configure application")
		helpers.assert_eq(ok, false)
		helpers.assert_eq(calls, 1, "one actual native modal invocation")
		helpers.assert_true(tostring(err):find("the native application picker failed", 1, true) ~= nil)
		helpers.assert_nil(tostring(err):find("private native failure payload", 1, true), "native error details stay private")
	end)

end)
