--- tests/unit/ui/test_menu_gesture_conflict_dialog.lua

--- ==============================================================================
--- MODULE: Gesture Conflict Dialog Regression
--- DESCRIPTION:
--- Exercises both action-picker paths through the real menu and deferred dialog.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a picker callback with deterministic native boundaries.
--- @param parameter boolean Whether the action needs a parameter.
--- @param clicked string The dialog button selected by the user.
--- @param refusal string|nil Simulated assignment refusal.
--- @param picked string|nil Parameter collected by the picker editor.
--- @return table observed Native effects.
local function choose(parameter, clicked, refusal, picked)
	local names = {
		"ui.menu.menu_gestures", "modules.gestures", "ui.menu.menu_utils", "infra.dialog_util",
		"infra.i18n", "infra.manifest_menu", "ui.action_picker", "ui.menu.shortcut_utils",
		"infra.logger", "infra.deferred_work", "adapters.storage", "ui.gesture_conflict_notice",
	}
	local saved, observed = {}, { queue = {}, opened = {}, dialogs = 0, refreshed = 0, settings = 0, prompts = 0 }
	local saved_shell = package.loaded["adapters.shell_runner"]
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local gestures = {
		DEFAULT_STATE = { gestures = true }, get_action = function() return "none" end,
		get_sg_names = function() return { "lookup" } end,
		get_action_label = function() return "Lookup" end,
		set_action = function(_, action)
			if action == "none" then return true end
			if refusal == "throw" then error("assignment refused") end
			if refusal == "nil" then return nil end
			return refusal ~= "false"
		end,
		on_action_changed = function() return { key = "tap_2", msg = "Conflict", url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension" } end,
		get_action_parameter_spec = function() return parameter and "link" or nil end,
		get_action_parameter = function() return "" end,
		parameter_prompt = function() return "URL" end,
		parameter_error = function() return "Invalid URL" end,
		validate_action_parameter = function() return true end,
		set_action_parameter = function(_, _, value) observed.parameter = value; return true end,
		system_gesture_conflicts = function() return { { label = "Two-finger secondary click" } } end,
		system_pinch_enabled = function() return true end,
		open_system_gestures = function() observed.settings = observed.settings + 1 end,
		refresh_system_gestures = function(done) observed.refreshed = observed.refreshed + 1; done(); return true end,
	}
	package.loaded["modules.gestures"] = gestures
	package.loaded["ui.menu.menu_utils"] = { section = function(label) return { label = label } end }
	package.loaded["infra.dialog_util"] = {
		text_prompt = function() observed.prompts = observed.prompts + 1; return "button.save", "https://example.com" end,
		block_alert = function() observed.dialogs = observed.dialogs + 1; return clicked end,
	}
	package.loaded["infra.i18n"] = { get = function(key)
		return key == "gestures.system.conflicts" and "{1} conflicts" or key
	end, section = function(key) return key end }
	package.loaded["infra.manifest_menu"] = {
		get_root = function() return { gesture_slots = { ["2"] = { "tap_2" } } } end,
		build = function(_, _, _, _, _, providers)
			observed.status = providers.system_gesture_status()
			return providers.gesture_slots_2()
		end,
	}
	package.loaded["ui.action_picker"] = { open = function(_, callback) callback("lookup", picked) end }
	package.loaded["ui.menu.shortcut_utils"] = {
		action_parameter_title = function(label) return label end,
		picker_parameter_fields = function() return {} end,
		-- The kind-aware ask of the real module, reduced to its text prompt.
		ask_parameter_value = function(_, _, _, title, prior)
			local button, typed = package.loaded["infra.dialog_util"].text_prompt(title, "", prior)
			if button ~= "button.save" then return nil end
			return typed
		end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.storage"] = { get = function() return false end }
	package.loaded["infra.deferred_work"] = { after = function(_, callback) observed.queue[#observed.queue + 1] = callback; return true end }
	package.loaded["adapters.shell_runner"] = { open = function(url) observed.opened[#observed.opened + 1] = url; return true end }
	local ok, err = xpcall(function()
		local menu = require("ui.menu.menu_gestures").build({
			gestures = gestures, state = { gestures = true }, save_prefs = function() return true end,
			updateMenu = function() end,
		})
		menu.submenu[1].items[1].action()
		while #observed.queue > 0 do table.remove(observed.queue, 1)() end
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	package.loaded["adapters.shell_runner"] = saved_shell
	if not ok then error(err, 0) end
	return observed
end

helpers.describe("gesture conflict dialog buttons (gesture-conflicts)", function()
	helpers.it("keeps the picker parameter while showing the conflict notice", function()
		local value = "https://example.com/?q=[test]&part=50%"
		local observed = choose(true, "OK", nil, value)
		helpers.assert_eq(observed.parameter, value)
		helpers.assert_eq(observed.prompts, 0, "the existing picker editor must not prompt twice")
		helpers.assert_eq(observed.dialogs, 1)
	end)
	helpers.it("builds a cached status submenu with explicit Settings and refresh actions", function()
		local observed = choose(false, "OK", "false")
		helpers.assert_eq(observed.refreshed, 0, "building the menu cannot start a probe")
		helpers.assert_eq(observed.settings, 0, "building the menu cannot open Settings")
		helpers.assert_eq(observed.status[1].label, "1 conflicts")
		helpers.assert_eq(#observed.status[1].items, 3)
		observed.status[1].items[1].action()
		helpers.assert_eq(observed.settings, 1)
		observed.status[1].items[3].action()
		helpers.assert_eq(observed.refreshed, 1)
	end)
	for _, parameter in ipairs({ false, true }) do
		for _, refusal in ipairs({ "false", "nil", "throw" }) do
			helpers.it("does not warn for a refused " .. (parameter and "parameter" or "plain") .. " assignment: " .. refusal, function()
				local observed = choose(parameter, "menu.gestures.open_settings", refusal)
				helpers.assert_eq(observed.dialogs, 0)
				helpers.assert_eq(#observed.opened, 0)
			end)
		end
		helpers.it("opens Settings from the " .. (parameter and "parameter" or "plain") .. " picker", function()
			local observed = choose(parameter, "menu.gestures.open_settings")
			helpers.assert_eq(observed.dialogs, 1)
			helpers.assert_eq(observed.opened, { "x-apple.systempreferences:com.apple.Trackpad-Settings.extension" })
		end)
		helpers.it("dismisses the " .. (parameter and "parameter" or "plain") .. " warning without opening Settings", function()
			local observed = choose(parameter, "OK")
			helpers.assert_eq(observed.dialogs, 1)
			helpers.assert_eq(#observed.opened, 0)
		end)
	end
end)
