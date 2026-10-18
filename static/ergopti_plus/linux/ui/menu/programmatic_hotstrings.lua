--- ui/menu/programmatic_hotstrings.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Menu (Linux Native Ports)
--- DESCRIPTION:
--- Supplies canonical preference receipts, native source actions and the
--- source problem to the shared menu. Factory evaluation belongs only to
--- explicit enable/reload; a source problem is shown on the row, never a dialog.
--- ==============================================================================

local M = {}
local Policy = require("menu.programmable_hotstrings")
local Manifest = require("infra.manifest_menu")
local Preferences = require("infra.hotstring_preferences")
local Shell = require("adapters.shell_runner")
local Prompt = require("ui.text_prompt")
local I18n = require("infra.i18n")
local Logger = require("logger.shim")
local ENABLED = "hotstrings.dynamic.user_code.enabled"
local TIME = "hotstrings.dynamic.user_code.time_activation_seconds"
local Publication = require("dynamic_hotstrings.menu_publication").new()

--- Builds declared controls for the daemon's exact programmable runtime.
--- @param ctx table Menu context with dynamic owner and refresh callback.
--- @return table menu Native renderer output.
function M.build(ctx)
	local native = ctx.dyn_hotstrings
	local function current() return ctx.dyn_hotstrings == native end
	local function get() return Preferences.get(ENABLED), Preferences.get(TIME) end
	local function open()
		if not current() then return false end
		return Shell.run("xdg-open " .. Shell.quote(native.user_code_source_path()) .. " >/dev/null 2>&1 &") == true
	end
	return Policy.build({ manifest = Manifest, i18n = I18n.get, get = get,
		master = function() return current() and native.is_enabled() == true end,
		paused = function()
			return ctx.paused == true or type(ctx.is_paused) ~= "function" or ctx.is_paused() ~= false
		end,
		set = function(enabled, seconds)
			if not current() then return false end
			local committed = Publication.commit(native, enabled, seconds, function()
				return current() and Preferences.set_many({ [ENABLED] = enabled, [TIME] = seconds }) == true
			end)
			if Publication.pending() then
				Logger.error("programmable_hotstrings", "Native preferences retain failed compensation ownership.")
			end
			return committed
		end,
		changed = function() if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end end,
		open = open,
		reload = function() return current() and native.reload_user_code() == true end,
		create = function() return current() and native.create_user_code_example() == true end,
		problem = function() return current() and native.user_code_problem() or nil end,
		prompt = function(milliseconds)
			return Prompt.ask(I18n.get("menu.hotstrings.user_code.title"), I18n.get("menu.hotstrings.delay_prompt"), tostring(milliseconds))
		end,
	})
end

return M
