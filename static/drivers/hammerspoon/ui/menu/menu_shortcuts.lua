--- ui/menu/menu_shortcuts.lua

--- ==============================================================================
--- MODULE: Menu Shortcuts
--- DESCRIPTION:
--- Builds the shortcuts sub-menu for the Hammerspoon tray menu.
--- ==============================================================================

local M = {}
local hs = hs
local dialog        = require("lib.dialog_util")
local shortcuts_mod = require("modules.shortcuts")





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

M.DEFAULT_STATE = {
	chatgpt_url = shortcuts_mod.DEFAULT_STATE.chatgpt_url,
	shortcuts   = shortcuts_mod.DEFAULT_STATE.shortcuts,
}





-- ====================================
-- ====================================
-- ======= 2/ Menu Construction =======
-- ====================================
-- ====================================

--- Builds the shortcuts sub-menu.
--- @param ctx table Context.
--- @return table|nil

function M.build(ctx)
	local shortcuts = ctx.shortcuts
	if not shortcuts then return nil end

	local state  = ctx.state
	local paused = ctx.paused

	local item = {
		title   = "Raccourcis 🎯",
		checked = (state.shortcuts and not paused) or nil,
		fn      = function()
			state.shortcuts = not state.shortcuts
			if state.shortcuts then 
				if type(shortcuts.start) == "function" then pcall(shortcuts.start) end 
			else 
				if type(shortcuts.stop) == "function" then pcall(shortcuts.stop) end 
			end
			ctx.save_prefs()
			ctx.notify_feature("Raccourcis", state.shortcuts)
			ctx.updateMenu()
		end,
	}

	local function pretty_key(id)
		if id == "at_hash" then return "Touche @/#" end
		if id == "layer_scroll" or id == "layer+scroll" then return "Layer + Scroll" end

		local parts = {}
		for p in id:gmatch("[^_]+") do table.insert(parts, p) end
		if #parts == 0 then return id end
        
		local key = parts[#parts]
		if key == "star" or key == "asterisk" then key = state.trigger_char end
		if key == "period" then key = "." end
		if key == "quote"  then key = "'" end
        
		local mods = {}
		for i = 1, #parts - 1 do
			local p   = parts[i]
			local lbl = ({ ctrl="Ctrl", cmd="Cmd", alt="Alt", option="Alt", shift="Shift" })[p]
			table.insert(mods, lbl or (p:sub(1,1):upper() .. p:sub(2)))
		end
		return (#mods > 0 and table.concat(mods, " + ") .. " + " or "") .. key:upper()
	end

	local s_menu = {}
	local ctrl_shortcuts, cmd_shortcuts, other_shortcuts = {}, {}, {}
	local layer_scroll_item, screenshot_item, after_screenshot = nil, nil, false

	if type(shortcuts.list_shortcuts) == "function" then
		local ok, list = pcall(shortcuts.list_shortcuts)
		if ok and type(list) == "table" then
			for _, s in ipairs(list) do
				if type(s) == "table" and s.id then
					local is_ctrl = s.id:sub(1, 5) == "ctrl_"
					local is_cmd = s.id:sub(1, 4) == "cmd_"
					local is_layer_scroll = (s.id == "layer_scroll" or s.id == "layer+scroll")
					local is_screenshot = (s.id == "screenshot" or s.id == "capture_ecran" or s.label:lower():find("capture d’écran"))

					local is_on = type(shortcuts.is_enabled) == "function" and shortcuts.is_enabled(s.id) or s.enabled
					local desc  = ctx.applyTriggerChar((s.label or ""):gsub("^%s*(.-)%s*$", "%1"))
					local shortcut_item = {
						title    = pretty_key(s.id) .. (desc ~= "" and (" : " .. desc) or ""),
						checked  = (is_on and not paused) or nil,
						disabled = not state.shortcuts or paused or nil,
						fn       = (state.shortcuts and not paused) and (function(id) 
							return function()
								local on = type(shortcuts.is_enabled) == "function" and shortcuts.is_enabled(id) or false
								if on then 
									if type(shortcuts.disable) == "function" then pcall(shortcuts.disable, id) end 
								else 
									if type(shortcuts.enable) == "function" then pcall(shortcuts.enable, id) end 
								end
								ctx.save_prefs()
								ctx.notify_feature(pretty_key(id), not on)
								ctx.updateMenu()
							end 
						end)(s.id) or nil,
					}

					if is_layer_scroll then
						layer_scroll_item = shortcut_item
					elseif is_screenshot then
						screenshot_item = shortcut_item
					elseif is_ctrl then
						table.insert(ctrl_shortcuts, shortcut_item)
					elseif is_cmd then
						table.insert(cmd_shortcuts, shortcut_item)
					else
						table.insert(other_shortcuts, shortcut_item)
					end

					if s.id == "ctrl_g" then
						table.insert(ctrl_shortcuts, {
							title    = "   ↳ Modifier l’URL ChatGPT…",
							disabled = paused or nil,
							fn       = not paused and function()
								local ok_p, clicked, url = pcall(dialog.text_prompt, "URL ChatGPT",
									"URL ouverte par Ctrl+G :",
									state.chatgpt_url, "OK", "Annuler")
								if ok_p and clicked == "OK" and type(url) == "string" and url ~= "" then
									state.chatgpt_url = url
									ctx.save_prefs()
									ctx.updateMenu()
								end
							end or nil,
						})
					end
				end
			end
		end
	end

	-- Ajout dans l’ordre demandé : autres, capture d’écran, layer+scroll, ctrl, --, cmd
	for _, item in ipairs(other_shortcuts) do
		table.insert(s_menu, item)
		if screenshot_item and not after_screenshot and item == screenshot_item then
			table.insert(s_menu, layer_scroll_item)
			after_screenshot = true
		end
	end
	if screenshot_item and not after_screenshot then
		table.insert(s_menu, screenshot_item)
		table.insert(s_menu, layer_scroll_item)
		after_screenshot = true
	end

	-- Bloc Ctrl
	if #ctrl_shortcuts > 0 then
		table.insert(s_menu, { title = "-" })
		for _, item in ipairs(ctrl_shortcuts) do
			table.insert(s_menu, item)
		end
	end

	-- Bloc Cmd
	if #cmd_shortcuts > 0 then
		table.insert(s_menu, { title = "-" })
		for _, item in ipairs(cmd_shortcuts) do
			table.insert(s_menu, item)
		end
	end

	-- Ajout des 3 éléments du contrôle du script à la fin
	local script_control = ctx.script_control
	if script_control then
		local state = ctx.state
		local enabled = state.script_control_enabled
		local paused = ctx.paused
		local actions = type(script_control.ACTIONS) == "table" and script_control.ACTIONS or {}
		local act_labels = type(script_control.ACTION_LABELS) == "table" and script_control.ACTION_LABELS or {}
		local function get_label(act)
			return act_labels[act] or act
		end
		local function key_submenu(keyname)
			local current = state.script_control_shortcuts[keyname] or "none"
			local sub = {}
			for _, act in ipairs(actions) do
				table.insert(sub, {
					title    = get_label(act),
					checked  = ((current == act) and not paused) or nil,
					disabled = not enabled or paused or nil,
					fn       = (enabled and not paused) and (function(a) return function()
						state.script_control_shortcuts[keyname] = a
						if type(script_control.set_shortcut_action) == "function" then pcall(script_control.set_shortcut_action, keyname, a) end
						ctx.save_prefs()
						ctx.updateMenu()
					end end)(act) or nil,
				})
			end
			return sub
		end
		local cur_return = state.script_control_shortcuts.return_key or "none"
		local cur_back   = state.script_control_shortcuts.backspace  or "none"
		local cur_escape = state.script_control_shortcuts.escape     or "none"
		table.insert(s_menu, { title = "-" })
		table.insert(s_menu, {
			title    = "Option droite + ↩ : " .. get_label(cur_return),
			disabled = not enabled or paused or nil,
			menu     = key_submenu("return_key")
		})
		table.insert(s_menu, {
			title    = "Option droite + ⌫ : " .. get_label(cur_back),
			disabled = not enabled or paused or nil,
			menu     = key_submenu("backspace")
		})
		table.insert(s_menu, {
			title    = "Option droite + ⎋ : " .. get_label(cur_escape),
			disabled = not enabled or paused or nil,
			menu     = key_submenu("escape")
		})
		table.insert(s_menu, {
			title    = "Chemin du AHK…",
			disabled = paused or nil,
			fn       = not paused and function()
				local ok_p, btn, path = pcall(dialog.text_prompt, "Script AHK",
					"Chemin du fichier AHK source :",
					state.ahk_source_path, "OK", "Annuler")
				if ok_p and btn == "OK" and type(path) == "string" then
					state.ahk_source_path = path
					ctx.save_prefs()
					ctx.updateMenu()
				end
			end or nil
		})
	end

	item.menu = s_menu
	return item
end

return M
