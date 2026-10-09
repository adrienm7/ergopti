--- tests/unit/ui/menu/test_configured_gesture_label.lua

--- ==============================================================================
--- MODULE: Configured Gesture Menu Label Tests
--- DESCRIPTION:
--- Drives the real four-finger menu provider with the shipped translation and
--- a saved URL. A formatter-only test cannot detect a stale host call site.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

helpers.describe("configured gesture menu label", function()
	helpers.it("replaces the marker on the four-finger menu row", function()
		helpers.with_fresh_modules({ "ui.menu.menu_gestures", "modules.gestures", "ui.menu.menu_utils",
			"infra.dialog_util", "infra.i18n", "infra.manifest_menu", "ui.action_picker",
			"menu.renderer",
			"ui.menu.shortcut_utils", "infra.logger", "infra.deferred_work" }, function()
			local file = assert(io.open(helpers.shared("data/locales/fr.json"), "rb"))
			local strings = json.decode(file:read("*a"))
			file:close()
			local url = "https://apple.com/?q=[x]&part=50%"
			local gestures = {
				get_action = function() return "open_url" end,
				get_action_label = function() return strings["sg_actions.open_url"] end,
				get_action_parameter = function(slot, action)
					helpers.assert_eq(slot, "tap_4")
					helpers.assert_eq(action, "open_url")
					return url
				end,
				get_sg_names = function() return {} end,
			}
			package.loaded["modules.gestures"] = { DEFAULT_STATE = { gestures = true }, DEFAULT_GESTURES = {}, SINGLE_SLOTS = { "tap_4" } }
			package.loaded["ui.menu.menu_utils"] = {}
			package.loaded["infra.dialog_util"] = {}
			package.loaded["infra.i18n"] = { get = function(key) return strings[key] or key end, section = function(key) return key end }
			local renderer = assert(require("menu.renderer").new({
				platform = "hs",
				manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
				json_decode = json.decode,
				i18n = package.loaded["infra.i18n"], logger = helpers.make_logger_stub(),
			}))
			package.loaded["infra.manifest_menu"] = {
				template_rows = renderer.template_rows,
				get_root = function() return { gesture_slots = { ["4"] = { "tap_4" } } } end,
				build = function(_, _, _, _, _, providers) return providers.gesture_slots_4() end,
			}
			package.loaded["ui.action_picker"] = {}
			package.loaded["ui.menu.shortcut_utils"] = {}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.deferred_work"] = {}
			local menu = require("ui.menu.menu_gestures").build({ gestures = gestures, state = { gestures = true }, paused = false })
			local prefix = assert(strings["sg_actions.open_url"]:match("^(.-)%[[^%[%]]*%]$"))
			helpers.assert_true(menu.submenu[1].label:find(prefix .. "[" .. url .. "]", 1, true) ~= nil)
			helpers.assert_true(menu.submenu[1].label:find("[configurable]", 1, true) == nil)
		end)
	end)
end)
