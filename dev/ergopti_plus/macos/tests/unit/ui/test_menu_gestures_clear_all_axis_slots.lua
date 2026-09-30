--- tests/unit/ui/test_menu_gestures_clear_all_axis_slots.lua

--- ==============================================================================
--- MODULE: Gestures « Tout effacer » Clears The Axis Slots Too
--- DESCRIPTION:
--- « ✕ Tout effacer (comportement du système) » promises that no gesture is left
--- to Ergopti. The command walked SINGLE_SLOTS only, so a horizontal axis slot
--- (swipe_3_horiz, swipe_4_horiz, swipe_5_horiz) kept its action and the
--- trackpad still answered to Ergopti after the clear. « Restaurer les valeurs
--- conseillées » must restore the recommendations, independently of neutral startup.
--- ==============================================================================

local helpers = require("tests.helpers")

local SINGLE = { "tap_3", "swipe_3_left" }
local AXIS   = { "swipe_3_horiz", "swipe_4_horiz" }

--- Builds the gestures menu with recording stubs and hands the registered
--- commands to `body`.
--- @param body function body(commands, assigned, saves)
local function with_commands(body)
	local names = {
		"modules.gestures", "ui.menu.menu_utils", "infra.dialog_util",
		"infra.i18n", "infra.manifest_menu", "ui.action_picker",
		"ui.menu.shortcut_utils", "infra.logger", "ui.menu.menu_gestures",
	}
	local saved = {}
	for _, name in ipairs(names) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end

	local assigned = {}
	local saves = { count = 0 }
	local runtime = {
		set_action = function(slot, action)
			assigned[slot] = action
			return true
		end,
		enable_all = function() return true end,
		disable_all = function() return true end,
	}
	package.loaded["modules.gestures"] = {
		DEFAULT_STATE = { gestures = true },
		SINGLE_SLOTS = SINGLE,
		AXIS_SLOTS = AXIS,
		DEFAULT_GESTURES = {
			tap_3 = "none", swipe_3_left = "none",
			swipe_3_horiz = "none", swipe_4_horiz = "none",
		},
		RECOMMENDED_GESTURES = {
			tap_3 = "left_click_toggle", swipe_3_left = "sel_word_prev",
			swipe_3_horiz = "words", swipe_4_horiz = "spaces",
		},
	}
	package.loaded["ui.menu.menu_utils"] = {}
	package.loaded["infra.dialog_util"] = {}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	local render_ctx = nil
	package.loaded["infra.manifest_menu"] = { build = function(_, _, _, _, ctx)
		render_ctx = ctx
		return {}
	end }
	package.loaded["ui.action_picker"] = {}
	package.loaded["ui.menu.shortcut_utils"] = {}
	package.loaded["infra.logger"] = helpers.make_logger_stub()

	local ok, err = xpcall(function()
		local MenuGestures = require("ui.menu.menu_gestures")
		MenuGestures.build({
			gestures = runtime,
			state = { gestures = true },
			paused = false,
			apply_gesture_scope = function(mode)
				saves.mode = mode
				return true
			end,
			save_prefs = function()
				saves.count = saves.count + 1
				return true
			end,
			updateMenu = function() end,
		})
		helpers.assert_type(render_ctx and render_ctx.commands, "table", "the menu must register its commands")
		body(render_ctx.commands, assigned, saves)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("menu_gestures: clear and restore cover every slot", function()
	helpers.it("« Tout effacer » unbinds the axis slots as well as the single ones", function()
		with_commands(function(commands, assigned, saves)
			helpers.assert_type(commands["scope_clear"], "function", "the clear command must be registered")
			helpers.assert_eq(commands["scope_clear"](), true)
			helpers.assert_eq(saves.mode, "clear")
			helpers.assert_eq(next(assigned), nil, "the menu must not bypass the transaction with direct slot writes")
			helpers.assert_eq(saves.count, 0, "only the scope owner publishes the complete sparse batch")
		end)
	end)

	helpers.it("« Restaurer les valeurs conseillées » puts every declared slot back", function()
		with_commands(function(commands, assigned, saves)
			helpers.assert_eq(commands["scope_restore"](), true)
			helpers.assert_eq(saves.mode, "recommended")
			helpers.assert_eq(next(assigned), nil)
			helpers.assert_eq(saves.count, 0)
		end)
	end)
end)
