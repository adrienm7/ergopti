--- ui/menu/programmatic_hotstrings.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Menu (macOS Native Ports)
--- DESCRIPTION:
--- Supplies the delay prompt, exact runtime preferences, editor opening and the
--- source problem to the shared programmable-source menu. Opening a source
--- never creates or loads it; a source problem is shown on the row, never a dialog.
--- ==============================================================================

local M = {}
local Policy = require("menu.programmable_hotstrings")
local Manifest = require("infra.manifest_menu")
local Dialog = require("infra.dialog_util")
local Shell = require("adapters.shell_runner")
local I18n = require("infra.i18n")
local User = require("modules.dynamic_hotstrings")
local Logger = require("infra.logger")
local Features = require("infra.manifest_reader")
local Publication = require("dynamic_hotstrings.menu_publication").new()

--- Builds declared rows around the currently owned menu state.
--- @param ctx table Menu state, exact preference save and refresh ports.
--- @return table menu Native menu rows.
function M.build(ctx)
	local function open()
		return Shell.run("/usr/bin/open", { "-e", User.user_code_source_path() }) == true
	end
	local function get()
		local enabled, seconds = ctx.state.dynamichotstrings_user_code_enabled,
			ctx.state.dynamichotstrings_user_code_time_activation_seconds
		if enabled == nil then enabled = Features.default_for("hotstrings.dynamic.user_code.enabled") end
		if seconds == nil then seconds = Features.default_for("hotstrings.dynamic.user_code.time_activation_seconds") end
		return enabled, seconds
	end
	return Policy.build({ manifest = Manifest, i18n = I18n.get, get = get,
		master = function() return ctx.keymap.is_group_enabled("dynamichotstrings") == true end,
		paused = function()
			if ctx.paused == true or type(ctx.script_control) ~= "table"
				or type(ctx.script_control.is_paused) ~= "function" then return true end
			local called, paused = pcall(ctx.script_control.is_paused)
			return not called or paused ~= false
		end,
		set = function(enabled, seconds)
			local old_enabled, old_seconds = ctx.state.dynamichotstrings_user_code_enabled,
				ctx.state.dynamichotstrings_user_code_time_activation_seconds
			local committed = Publication.commit(User, enabled, seconds, function()
				ctx.state.dynamichotstrings_user_code_enabled = enabled
				ctx.state.dynamichotstrings_user_code_time_activation_seconds = seconds
				local called, saved = pcall(ctx.save_prefs)
				if called and saved == true then return true end
				ctx.state.dynamichotstrings_user_code_enabled = old_enabled
				ctx.state.dynamichotstrings_user_code_time_activation_seconds = old_seconds
				return false
			end)
			if Publication.pending() then
				Logger.error("programmable_hotstrings", "Native preferences retain failed compensation ownership.")
			end
			return committed
		end,
		changed = function() ctx.updateMenu() end,
		open = open, reload = User.reload_user_code, create = User.create_user_code_example,
		problem = User.user_code_problem,
		prompt = function(milliseconds)
			local button, value = Dialog.text_prompt(I18n.get("menu.hotstrings.user_code.title"),
				I18n.get("menu.hotstrings.delay_prompt"), tostring(milliseconds), I18n.get("common.ok"), I18n.get("common.cancel"))
			if button == I18n.get("common.ok") then return value end
		end,
	})
end

return M
