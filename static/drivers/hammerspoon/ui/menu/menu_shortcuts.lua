--- ui/menu/menu_shortcuts.lua

--- ==============================================================================
--- MODULE: Menu Shortcuts
--- DESCRIPTION:
--- Builds the shortcuts sub-menu for the Hammerspoon tray menu.
---
--- FEATURES & RATIONALE:
--- 1. Grouped Layout: Top-level items (screenshot, volume, wrap) appear first;
---    Ctrl, Cmd, and script-control shortcuts are nested in labelled submenus,
---    mirroring the AHK tray menu structure for consistency across platforms.
--- ==============================================================================

local M = {}
local hs = hs
local dialog        = require("lib.dialog_util")
local shortcuts_mod = require("modules.shortcuts")
local i18n          = require("lib.i18n")




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

--- Translates a shortcut identifier into a human-readable trigger label.
--- @param id string The shortcut identifier (e.g. "ctrl_a", "layer_scroll").
--- @param state table The current state table (used for trigger_char substitution).
--- @return string Display label for the trigger key(s).
local function pretty_key(id, state)
	if id == "at_hash" then return "Touche @/#" end
	if id == "layer_scroll" or id == "layer+scroll" then return "Layer + Scroll" end
	if id == "wrap_text_if_selected" then return "AltGr + symbole" end

	local parts = {}
	for p in id:gmatch("[^_]+") do table.insert(parts, p) end
	if #parts == 0 then return id end

	local key = parts[#parts]
	if key == "star" or key == "asterisk" then key = (state and state.trigger_char) or "★" end
	if key == "period"   then key = "." end
	if key == "quote"    then key = "'" end
	if key == "capslock" then key = "CapsLock" end

	local mods = {}
	for i = 1, #parts - 1 do
		local p   = parts[i]
		local lbl = ({ ctrl = "Ctrl", cmd = "Cmd", alt = "Alt", option = "Alt", shift = "Shift" })[p]
		table.insert(mods, lbl or (p:sub(1, 1):upper() .. p:sub(2)))
	end
	return (#mods > 0 and table.concat(mods, " + ") .. " + " or "") .. key:upper()
end

--- Builds a toggle menu item for a named shortcut.
--- @param s table Shortcut descriptor {id, label, enabled}.
--- @param shortcuts table The shortcuts module reference.
--- @param ctx table The menu context.
--- @return table hs.menubar-compatible item table.
local function make_shortcut_item(s, shortcuts, ctx)
	local state  = ctx.state
	local paused = ctx.paused
	local is_on  = type(shortcuts.is_enabled) == "function" and shortcuts.is_enabled(s.id) or s.enabled
	local desc   = ctx.applyTriggerChar((s.label or ""):gsub("^%s*(.-)%s*$", "%1"))
	local pk     = pretty_key(s.id, state)
	return {
		title    = pk .. (desc ~= "" and (" : " .. desc) or ""),
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
				ctx.notify_feature(pretty_key(id, state), not on)
				ctx.updateMenu()
			end
		end)(s.id) or nil,
	}
end

--- Builds the shortcuts sub-menu.
--- @param ctx table Context.
--- @return table|nil
function M.build(ctx)
	local shortcuts = ctx.shortcuts
	if not shortcuts then return nil end

	local state  = ctx.state
	local paused = ctx.paused

	local item = {
		title   = i18n.get("menu.shortcuts.title"),
		checked = (state.shortcuts and not paused) or nil,
		fn      = function()
			state.shortcuts = not state.shortcuts
			if state.shortcuts then
				if type(shortcuts.start) == "function" then pcall(shortcuts.start) end
			else
				if type(shortcuts.stop) == "function" then pcall(shortcuts.stop) end
			end
			ctx.save_prefs()
			ctx.notify_feature(i18n.get("menu.shortcuts.title"), state.shortcuts)
			ctx.updateMenu()
		end,
	}

	-- Buckets for each display group
	local top_items  = {}   -- at_hash, layer_scroll, wrap_text_if_selected (in order)
	local ctrl_items = {}
	local cmd_items  = {}

	-- Preserve insertion order for top-level items
	local TOP_ORDER = { "at_hash", "layer_scroll", "wrap_text_if_selected" }
	local top_map   = {}

	if type(shortcuts.list_shortcuts) == "function" then
		local ok, list = pcall(shortcuts.list_shortcuts)
		if ok and type(list) == "table" then
			for _, s in ipairs(list) do
				if type(s) == "table" and s.id then
					local mi = make_shortcut_item(s, shortcuts, ctx)

					if s.id == "at_hash" or s.id == "layer_scroll" or s.id == "wrap_text_if_selected" then
						top_map[s.id] = mi

					elseif s.id:sub(1, 5) == "ctrl_" then
						table.insert(ctrl_items, mi)
						-- Inject ChatGPT URL editor inline below ctrl_g
						if s.id == "ctrl_g" then
							table.insert(ctrl_items, {
								title    = i18n.get("menu.shortcuts.chatgpt_url_item"),
								disabled = paused or nil,
								fn       = not paused and function()
									local ok_p, clicked, url = pcall(dialog.text_prompt, i18n.get("dialog.shortcuts.chatgpt_title"),
										i18n.get("dialog.shortcuts.chatgpt_prompt"),
										state.chatgpt_url, i18n.get("button.ok"), i18n.get("button.cancel"))
									if ok_p and clicked == i18n.get("button.ok") and type(url) == "string" and url ~= "" then
										state.chatgpt_url = url
										ctx.save_prefs()
										ctx.updateMenu()
									end
								end or nil,
							})
						end

					elseif s.id:sub(1, 4) == "cmd_" then
						table.insert(cmd_items, mi)
					end
				end
			end
		end
	end

	-- Assemble top items in canonical order
	for _, id in ipairs(TOP_ORDER) do
		if top_map[id] then table.insert(top_items, top_map[id]) end
	end

	-- Build the final menu
	local s_menu = {}

	for _, mi in ipairs(top_items) do
		table.insert(s_menu, mi)
	end

	-- Ctrl submenu
	if #ctrl_items > 0 then
		table.insert(s_menu, { title = "-" })
		table.insert(s_menu, {
			title    = "Ctrl",
			disabled = not state.shortcuts or paused or nil,
			menu     = ctrl_items,
		})
	end

	-- Cmd submenu
	if #cmd_items > 0 then
		table.insert(s_menu, {
			title    = "Cmd",
			disabled = not state.shortcuts or paused or nil,
			menu     = cmd_items,
		})
	end

	-- Script control submenu
	local script_control = ctx.script_control
	if script_control then
		local enabled = state.script_control_enabled
		local actions = type(script_control.ACTIONS) == "table" and script_control.ACTIONS or {}

		local function get_label(act)
			if not act or act == "-" or act == "--" then return "-" end
			if act:match("^#") then return act:sub(2) end
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
					table.insert(sub, { title = label, disabled = true })
				else
					table.insert(sub, {
						title    = label,
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
			end
			return sub
		end

		local cur_return = state.script_control_shortcuts.return_key or "none"
		local cur_back   = state.script_control_shortcuts.backspace  or "none"
		local cur_escape = state.script_control_shortcuts.escape     or "none"

		local script_items = {
			{
				title    = "Option droite + ↩ : " .. get_label(cur_return),
				disabled = not enabled or paused or nil,
				menu     = key_submenu("return_key"),
			},
			{
				title    = "Option droite + ⌫ : " .. get_label(cur_back),
				disabled = not enabled or paused or nil,
				menu     = key_submenu("backspace"),
			},
			{
				title    = "Option droite + ⎋ : " .. get_label(cur_escape),
				disabled = not enabled or paused or nil,
				menu     = key_submenu("escape"),
			},
		}

		table.insert(s_menu, { title = "-" })
		table.insert(s_menu, {
			title    = i18n.get("menu.shortcuts.script_shortcuts"),
			disabled = not enabled or paused or nil,
			menu     = script_items,
		})
	end

	item.menu = s_menu
	return item
end

return M
