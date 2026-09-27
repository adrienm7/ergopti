--- tests/unit/ui/menu/test_menu_metrics_modifier_key_shortcut.lua

--- ==============================================================================
--- MODULE: Metrics Shortcut Refuses A Modifier Key
--- DESCRIPTION:
--- A metrics shortcut typed as "ctrl+rightcmd" names a modifier key as its key.
--- macOS reports such a key only as a flag change, so the hotkey registered
--- without complaint and never fired, while the prompt saved it as the
--- shortcut. Windows refuses these keys with a reason. The prompt now refuses
--- them before anything is saved and says why.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.hotkey_registrar",
	"hs.fs",
	"infra.app_picker",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.manifest_menu",
	"infra.text_utils",
	"modules.keylogger",
	"ui.menu.menu_metrics",
}

-- Each prompt row, with the menu context callback it commits through.
local PROMPTS = {
	{ handler = "shortcut_typing", apply = "apply_metrics_shortcut" },
	{ handler = "shortcut_apps", apply = "apply_apps_time_shortcut" },
}

--- Runs one shortcut prompt of the real metrics menu on a typed answer.
--- @param prompt table PROMPTS entry.
--- @param answer string What the user types in the prompt.
--- @return table observations { applied = {…}, alerts = {…} }
local function run_prompt(prompt, answer)
	local saved = {}
	for _, name in ipairs(MODULES) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end

	local observations = { applied = {}, alerts = {} }
	local handlers
	package.loaded["hs.fs"] = {}
	package.loaded["infra.app_picker"] = { build_menu = function() return {} end }
	package.loaded["infra.dialog_util"] = {
		text_prompt = function() return "OK", answer end,
		block_alert = function(title, body)
			observations.alerts[#observations.alerts + 1] = { title = title, body = body }
			return "OK"
		end,
	}
	package.loaded["infra.i18n"] = {
		get = function(key) return key end,
		format = function(key, ...) return key .. ":" .. table.concat({ ... }, ",") end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.manifest_menu"] = {
		build = function(_, _, _, _, _, list_providers)
			handlers = list_providers
			return {}
		end,
		resolve_disabled_when = function() return false end,
	}
	package.loaded["infra.text_utils"] = {}
	package.loaded["modules.keylogger"] = { DEFAULT_STATE = { keylogger_disabled_apps = {} } }

	local ok, err = xpcall(function()
		local MenuMetrics = require("ui.menu.menu_metrics")
		local ctx = {
			state = { keylogger_disabled_apps = {}, metrics_shortcut = false, apps_time_shortcut = false },
			save_prefs = function() return true end,
			updateMenu = function() return true end,
		}
		ctx[prompt.apply] = function(mods, key)
			observations.applied[#observations.applied + 1] = { mods = mods, key = key }
			return true
		end
		MenuMetrics.build(ctx)
		handlers[prompt.handler](ctx)[1].action()
	end, debug.traceback)
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
	return observations
end

helpers.describe("the metrics shortcut prompts refuse a modifier key (shortcut-key-is-modifier)", function()
	for _, prompt in ipairs(PROMPTS) do
		helpers.it(prompt.handler .. " refuses every modifier-key name and says why", function()
			for _, key in ipairs({ "rightcmd", "rightalt", "rightctrl", "rightshift", "capslock" }) do
				local observations = run_prompt(prompt, "ctrl+" .. key)
				helpers.assert_eq(#observations.applied, 0,
					prompt.handler .. ": ctrl+" .. key .. " must not be saved as a shortcut")
				helpers.assert_eq(#observations.alerts, 1, prompt.handler .. ": the user must be told why")
				helpers.assert_eq(observations.alerts[1].body, "menu.metrics.shortcut_modifier_key:" .. key,
					prompt.handler .. ": the alert must name the refused key")
			end
		end)

		helpers.it(prompt.handler .. " still saves an ordinary key", function()
			local observations = run_prompt(prompt, "ctrl+m")
			helpers.assert_eq(#observations.alerts, 0, prompt.handler .. ": no alert for an ordinary key")
			helpers.assert_eq(#observations.applied, 1, prompt.handler .. ": ctrl+m must be saved")
			helpers.assert_eq(observations.applied[1].key, "m")
		end)
	end
end)
