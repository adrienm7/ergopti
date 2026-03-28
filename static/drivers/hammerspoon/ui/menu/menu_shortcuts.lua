-- ui/menu/menu_shortcuts.lua

local M = {}
local hs = hs

--- Builds the shortcuts sub-menu.
--- @param ctx table Context
--- @return table|nil
function M.build(ctx)
	local shortcuts = ctx.shortcuts
	if not shortcuts then return nil end

	local state  = ctx.state
	local paused = ctx.paused

	local item = {
		title   = "Raccourcis",
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
		
		local mods = {}
		for i = 1, #parts - 1 do
			local p   = parts[i]
			local lbl = ({ ctrl="Ctrl", cmd="Cmd", alt="Alt", option="Alt", shift="Shift" })[p]
			table.insert(mods, lbl or (p:sub(1,1):upper() .. p:sub(2)))
		end
		return (#mods > 0 and table.concat(mods, " + ") .. " + " or "") .. key:upper()
	end

	local s_menu = {}
	local last_was_non_ctrl, separator_inserted = false, false
	
	if type(shortcuts.list_shortcuts) == "function" then
		local ok, list = pcall(shortcuts.list_shortcuts)
		if ok and type(list) == "table" then
			for _, s in ipairs(list) do
				if type(s) == "table" and s.id then
					local is_ctrl = s.id:sub(1, 5) == "ctrl_"
					if not separator_inserted and last_was_non_ctrl and is_ctrl then
						table.insert(s_menu, { title = "-" })
						separator_inserted = true
					end
					if not is_ctrl then last_was_non_ctrl = true end

					local is_on = type(shortcuts.is_enabled) == "function" and shortcuts.is_enabled(s.id) or s.enabled
					local desc  = ctx.applyTriggerChar((s.label or ""):gsub("^%s*(.-)%s*$", "%1"))
					
					-- Cas particulier pour Layer + Scroll
					if s.id == "layer_scroll" or s.id == "layer+scroll" then
						table.insert(s_menu, { title = "-" })
						-- Met une majuscule si c'est en minuscules
						desc = desc:gsub("^%l", string.upper)
					end
					
					table.insert(s_menu, {
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
					})
					
					if s.id == "ctrl_g" then
						table.insert(s_menu, {
							title    = "   ↳ Modifier l’URL ChatGPT…",
							disabled = paused or nil,
							fn       = not paused and function()
								local ok_p, clicked, url = pcall(hs.dialog.textPrompt, "URL ChatGPT",
									"URL ouverte par Ctrl+G :",
									state.chatgpt_url or "", "OK", "Annuler")
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
	
	item.menu = s_menu
	return item
end

return M
