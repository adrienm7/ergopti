--- ui/menu/menu_script_control.lua

--- ==============================================================================
--- MODULE: Menu Script Control
--- DESCRIPTION:
--- Builds the script control sub-menu for the Hammerspoon tray menu.
--- ==============================================================================

local M = {}
local hs = hs
local dialog        = require("lib.dialog_util")
local shortcuts_mod = require("modules.shortcuts")
local i18n          = require("lib.i18n")





-- ================================
--- ================================
-- ======= 1/ Default State =======
--- ================================
-- ================================

M.DEFAULT_STATE = {
	script_control_enabled   = shortcuts_mod.DEFAULT_STATE.script_control_enabled,
	script_control_shortcuts = shortcuts_mod.DEFAULT_STATE.script_control_shortcuts,
}





-- ====================================
--- ====================================
-- ======= 2/ Menu Construction =======
--- ====================================
-- ====================================

--- Builds the script control sub-menu.
--- @param ctx table Context containing state, updateMenu, save_prefs, etc.
--- @return table|nil
function M.build(ctx)
	local sc_module = ctx.script_control
	if not sc_module then return nil end

	local state      = ctx.state
	local paused     = ctx.paused
	local actions    = type(sc_module.ACTIONS) == "table" and sc_module.ACTIONS or {}
	local enabled    = state.script_control_enabled

	local function get_label(act)
		if not act or act == "-" or act == "--" then return "-" end
		if act:match("^#") then return act:sub(2) end -- Category headers

		if ctx.gestures and type(ctx.gestures.get_action_label) == "function" then
			return ctx.gestures.get_action_label(act)
		end
		return act
	end

	local function key_submenu(keyname)
		local current = state.script_control_shortcuts[keyname] or "none"
		local sub = {}
		for _, act in ipairs(actions) do
			local label = get_label(act)
			
			if label == "-" then
				table.insert(sub, { title = "-" })
			elseif act:match("^#") then
				table.insert(sub, { title = "— " .. label .. " —", disabled = true })
			else
				table.insert(sub, {
					title    = label,
					checked  = ((current == act) and not paused) or nil,
					disabled = not enabled or paused or nil,
					fn       = (enabled and not paused) and (function(a) return function()
						state.script_control_shortcuts[keyname] = a
						if type(sc_module.set_shortcut_action) == "function" then pcall(sc_module.set_shortcut_action, keyname, a) end
						ctx.save_prefs()
						ctx.updateMenu()
					end end)(act) or nil,
				})
			end
		end
		return sub
	end

	local cur_return = state.script_control_shortcuts.return_key or "none"
	local cur_back   = state.script_control_shortcuts.backspace  or "none"
	local cur_escape = state.script_control_shortcuts.escape     or "none"

	return {
		title   = "i18n.get("menu.script_control.title")",
		checked = (enabled and not paused) or nil,
		fn      = function()
			state.script_control_enabled = not state.script_control_enabled
			if type(sc_module.set_shortcut_action) == "function" then
				if state.script_control_enabled then
					pcall(sc_module.set_shortcut_action, "return_key", state.script_control_shortcuts.return_key)
					pcall(sc_module.set_shortcut_action, "backspace",  state.script_control_shortcuts.backspace)
					pcall(sc_module.set_shortcut_action, "escape",     state.script_control_shortcuts.escape)
				else
					pcall(sc_module.set_shortcut_action, "return_key", "none")
					pcall(sc_module.set_shortcut_action, "backspace",  "none")
					pcall(sc_module.set_shortcut_action, "escape",     "none")
				end
			end
			ctx.save_prefs()
			ctx.notify_feature(i18n.get("notify.script_control"), state.script_control_enabled)
			ctx.updateMenu()
		end,
		menu = {
			{ title = string.format(i18n.get("menu.shortcuts.right_opt_return"), get_label(cur_return)),
			   disabled = not enabled or paused or nil, menu = key_submenu("return_key") },
			{ title = string.format(i18n.get("menu.shortcuts.right_opt_back"), get_label(cur_back)),
			   disabled = not enabled or paused or nil, menu = key_submenu("backspace") },
			{ title = string.format(i18n.get("menu.shortcuts.right_opt_escape"), get_label(cur_escape)),
			   disabled = not enabled or paused or nil, menu = key_submenu("escape") },
		},

	}
end

return M
