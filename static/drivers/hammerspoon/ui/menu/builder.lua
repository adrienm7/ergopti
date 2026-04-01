--- ui/menu/builder.lua

--- ==============================================================================
--- MODULE: Menu Builder
--- DESCRIPTION:
--- Constructs the visual hierarchy of the macOS menubar.
---
--- FEATURES & RATIONALE:
--- 1. Stateless Rendering: Consumes the context and returns pure UI tables.
--- 2. Delegation: Relies on specific menu_* submodules for component building.
--- 3. Dynamic Centering: Creates a transparent full-width canvas to center the badge.
--- ==============================================================================

local M = {}
local hs = hs





-- ==================================
-- ==================================
-- ======= 1/ Menu Generation =======
-- ==================================
-- ==================================

--- Generates the complete items list for the Hammerspoon menubar.
--- @param ctx table The global UI context.
--- @param menu_mods table The loaded menu submodules.
--- @param actions table Callbacks for global system actions.
--- @return table The assembled menu structure.
function M.generate(ctx, menu_mods, actions)
	local items = {}
	
	-- Build main elements first to allow width calculation later
	if type(menu_mods.hotstrings) == "table" then
		if type(menu_mods.hotstrings.build_groups) == "function" then
			local ok, groups = pcall(menu_mods.hotstrings.build_groups, ctx)
			if ok and type(groups) == "table" then
				for _, it in ipairs(groups) do table.insert(items, it) end
			end
		end
		
		table.insert(items, { title = "-" })
		
		if type(menu_mods.hotstrings.build_management) == "function" then
			local ok, mgmt = pcall(menu_mods.hotstrings.build_management, ctx)
			if ok and mgmt then table.insert(items, mgmt) end
		end
		
		if type(menu_mods.hotstrings.build_personal) == "function" then
			local ok, pers = pcall(menu_mods.hotstrings.build_personal, ctx)
			if ok and pers then table.insert(items, pers) end
		end
		
		if type(menu_mods.hotstrings.build_custom) == "function" then
			local ok, cust = pcall(menu_mods.hotstrings.build_custom, ctx)
			if ok and cust then table.insert(items, cust) end
		end
	end

	table.insert(items, { title = "-" })
	
	if type(ctx.llm_handler) == "table" and type(ctx.llm_handler.build_item) == "function" then
		local ok_b, llm_item = pcall(ctx.llm_handler.build_item)
		if ok_b and llm_item then
			table.insert(items, llm_item)
		elseif not ok_b then
			print("[builder] ERREUR build_item IA : " .. tostring(llm_item))
		end
	end
	
	if type(menu_mods.keylogger) == "table" and type(menu_mods.keylogger.build) == "function" then
		local ok, kl_item = pcall(menu_mods.keylogger.build, ctx)
		if ok and kl_item then table.insert(items, kl_item) end
	end

	table.insert(items, { title = "-" })
	
	if type(menu_mods.gestures) == "table" and type(menu_mods.gestures.build) == "function" then
		local ok, g_item = pcall(menu_mods.gestures.build, ctx)
		if ok and g_item then table.insert(items, g_item) end
	end
	
	if type(menu_mods.shortcuts) == "table" and type(menu_mods.shortcuts.build) == "function" then
		local ok, r_item = pcall(menu_mods.shortcuts.build, ctx)
		if ok and r_item then table.insert(items, r_item) end
	end

	local script_control_mod = pcall(require, "ui.menu.menu_script_control") and require("ui.menu.menu_script_control") or nil
	if type(script_control_mod) == "table" and type(script_control_mod.build) == "function" then
		local ok, sc_item = pcall(script_control_mod.build, ctx)
		if ok and sc_item then table.insert(items, sc_item) end
	end

	table.insert(items, { title = "-" })
	table.insert(items, { title = "☑ Activer toutes les fonctionnalités", fn = actions.enable_all })
	table.insert(items, { title = "☐ Désactiver toutes les fonctionnalités", fn = actions.disable_all })
	
	table.insert(items, { title = "-" })
	table.insert(items, { title = "Console", fn = actions.open_console })
	table.insert(items, { title = "Ouvrir init.lua", fn = actions.open_init })
	table.insert(items, { title = "Préférences", fn = actions.open_prefs })
	table.insert(items, { title = "Recharger", fn = actions.reload })
	table.insert(items, { title = "Quitter", fn = actions.quit })

	-- Calculate the required canvas width based on the longest root menu item
	local max_text_width = 0
	for _, item in ipairs(items) do
		if type(item.title) == "string" and item.title ~= "-" then
			local ok_s, size_s = pcall(hs.drawing.getTextDrawingSize, item.title, { font = ".AppleSystemUIFont", size = 14 })
			if ok_s and type(size_s) == "table" and size_s.w then
				local extra_width = (item.menu ~= nil) and 15 or 0
				if (size_s.w + extra_width) > max_text_width then
					max_text_width = size_s.w + extra_width
				end
			end
		end
	end
	
	-- Create a transparent canvas that spans the available menu width to force centering
	local canvas_w = math.max(math.ceil(max_text_width + 50), 250)
	
	local ok, size = pcall(hs.drawing.getTextDrawingSize, "Ergopti +", { font = "Helvetica-Bold", size = 14 })
	local text_w = (ok and type(size) == "table" and size.w) and size.w or 65
	
	-- Configure perfectly balanced padding for the pill
	local pad_x = 8
	local pad_y = 10
	local pill_w = math.ceil(text_w + (pad_x * 2))
	local pill_h = 14 + (pad_y * 2)
	
	-- Mathematically center the pill horizontally inside the transparent canvas
	local pill_x = (canvas_w - pill_w) / 2
	
	local is_dark = hs.host.interfaceStyle() == "Dark"
	local bg_color   = is_dark and { white = 1 } or { white = 0.15 }
	local text_color = is_dark and { white = 0.1 } or { white = 1 }
	
	local canvas_obj = hs.canvas.new({ x = 0, y = 0, w = canvas_w, h = pill_h })
	canvas_obj:appendElements(
		{
			type             = "rectangle",
			action           = "fill",
			fillColor        = bg_color,
			roundedRectRadii = { xRadius = 8, yRadius = 8 },
			frame            = { x = pill_x, y = 0, w = pill_w, h = pill_h }
		},
		{
			type          = "text",
			text          = "Ergopti +",
			textColor     = text_color,
			textAlignment = "center",
			textSize      = 14,
			textFont      = "Helvetica-Bold",
			-- Adjust Y slightly (pad_y - 2) to account for font baseline rendering
			frame         = { x = pill_x, y = pad_y - 2, w = pill_w, h = pill_h }
		}
	)
	
	table.insert(items, 1, {
		title = "",
		image = canvas_obj:imageFromCanvas(),
		fn    = function() end,
	})
	table.insert(items, 2, { title = "-" })

	return items
end

return M
