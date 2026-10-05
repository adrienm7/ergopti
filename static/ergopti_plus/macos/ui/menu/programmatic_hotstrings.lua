--- ui/menu/programmatic_hotstrings.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Menu (macOS Native Ports)
--- DESCRIPTION:
--- Supplies native dialogs, exact runtime preferences and editor opening to the
--- shared programmable-source menu. Opening a source never creates or loads it.
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
	local function apply(enabled, seconds)
		return User.set_user_code_time_activation(seconds) == true and User.set_user_code_enabled(enabled) == true
	end
	return Policy.build({ manifest = Manifest, i18n = I18n.get, get = get,
		master = function() return ctx.keymap.is_group_enabled("dynamichotstrings") == true end,
		paused = function() return ctx.paused == true end,
		set = function(enabled, seconds)
			local old_enabled, old_seconds = get()
			if apply(enabled, seconds) ~= true then return false end
			ctx.state.dynamichotstrings_user_code_enabled = enabled
			ctx.state.dynamichotstrings_user_code_time_activation_seconds = seconds
			if ctx.save_prefs() == true then return true end
			ctx.state.dynamichotstrings_user_code_enabled = old_enabled
			ctx.state.dynamichotstrings_user_code_time_activation_seconds = old_seconds
			if apply(old_enabled, old_seconds) ~= true then
				Logger.error("programmable_hotstrings", "Native preferences retain failed compensation ownership.")
			end
			return false
		end,
		changed = function() ctx.updateMenu() end,
		open = open, reload = User.reload_user_code, create = User.create_user_code_example,
		prompt = function(milliseconds)
			local button, value = Dialog.text_prompt(I18n.get("menu.hotstrings.user_code.title"),
				I18n.get("menu.hotstrings.delay_prompt"), tostring(milliseconds), I18n.get("common.ok"), I18n.get("common.cancel"))
			if button == I18n.get("common.ok") then return value end
		end,
		error = function(open_source)
			local open_label = I18n.get("menu.hotstrings.user_code.open_source")
			if Dialog.block_alert(I18n.get("common.error_title"), I18n.get("menu.hotstrings.user_code.error"),
				open_label, I18n.get("common.close"), "warning") == open_label then open_source() end
		end,
	})
end

return M
