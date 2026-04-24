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
local hs     = hs
local Logger = require("lib.logger")
local LOG    = "builder"





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

	-- Helper function to insert only valid components and log errors
	local function push_into(target, label, fn, arg)
		local result = Logger.build(LOG, label, fn, arg)
		if result then
			if type(result) == "table" and result[1] ~= nil then
				-- Result is a list (build_groups)
				for _, it in ipairs(result) do table.insert(target, it) end
			else
				table.insert(target, result)
			end
			Logger.debug(LOG, string.format("Component '%s' added successfully.", label))
		else
			Logger.warn(LOG, string.format("Component '%s' missing or in error — ignored.", label))
		end
	end

	local function push(label, fn, arg)
		push_into(items, label, fn, arg)
	end

	-- Hotstrings zone avec activation globale
	if type(menu_mods.hotstrings) == "table" then
		Logger.debug(LOG, "Building hotstrings submenu…")
		local hotstrings_menu = {}
		push_into(hotstrings_menu, "hotstrings.build_groups", menu_mods.hotstrings.build_groups, ctx)
		push_into(hotstrings_menu, "hotstrings.build_custom", menu_mods.hotstrings.build_custom, ctx)
		push_into(hotstrings_menu, "hotstrings.build_management", menu_mods.hotstrings.build_management, ctx)

		-- Détection de l’état global : toutes les hotstrings activées ?
		local all_enabled = true
		local any_enabled = false
		if ctx and ctx.hotfiles and type(ctx.hotfiles) == "table" then
			for _, f in ipairs(ctx.hotfiles) do
				local name = ctx.get_group_name and ctx.get_group_name(f) or f
				if name ~= "custom" and name ~= "personal" then
					local enabled = false
					if ctx.keymap and type(ctx.keymap.is_group_enabled) == "function" then
						enabled = ctx.keymap.is_group_enabled(name)
					elseif ctx.state and ctx.state.hotstrings then
						enabled = ctx.state.hotstrings[name] ~= false
					end
					if enabled then any_enabled = true else all_enabled = false end
				end
			end
		end

		local function toggle_all_hotstrings()
			if not ctx or not ctx.hotfiles or type(ctx.hotfiles) ~= "table" then return end
			local enable = not all_enabled
			for _, f in ipairs(ctx.hotfiles) do
				local name = ctx.get_group_name and ctx.get_group_name(f) or f
				if name ~= "custom" and name ~= "personal" then
					if ctx.keymap and type(ctx.keymap.enable_group) == "function" and type(ctx.keymap.disable_group) == "function" then
						if enable then pcall(ctx.keymap.enable_group, name) else pcall(ctx.keymap.disable_group, name) end
					end
					if ctx.state and ctx.state.hotstrings then ctx.state.hotstrings[name] = enable end
				end
			end
			ctx.save_prefs()
			ctx.notify_feature("Hotstrings", enable)
			ctx.updateMenu()
		end

		if #hotstrings_menu > 0 then
			table.insert(items, {
				title = "Hotstrings ⚡",
				menu = hotstrings_menu,
				checked = all_enabled and not ctx.paused or nil,
				fn = not ctx.paused and toggle_all_hotstrings or nil
			})
		else
			Logger.warn(LOG, "Hotstrings submenu is empty — ignored.")
		end
	else
		Logger.warn(LOG, "Hotstrings module missing — submenu ignored.")
	end

	-- AI zone
	if type(ctx.llm_handler) == "table" and type(ctx.llm_handler.build_item) == "function" then
		Logger.debug(LOG, "Building AI component…")
		local ok_b, llm_item = pcall(ctx.llm_handler.build_item)
		if ok_b and llm_item then
			table.insert(items, llm_item)
			Logger.debug(LOG, "AI component added successfully.")
		elseif not ok_b then
			Logger.error(LOG, string.format("Error building AI component: %s.", tostring(llm_item)))
		end
	else
		Logger.warn(LOG, "LLM handler missing or incomplete — AI component ignored.")
	end

	-- Metrics zone
	if type(menu_mods.keylogger) == "table" then
		push("keylogger.build", menu_mods.keylogger.build, ctx)
	else
		Logger.warn(LOG, "Keylogger module missing.")
	end

	if type(menu_mods.shortcuts) == "table" then
		push("shortcuts.build", menu_mods.shortcuts.build, ctx)
	end

	-- Karabiner then Gestures — keyboard first, then trackpad
	if type(menu_mods.karabiner) == "table" and type(menu_mods.karabiner.build) == "function" then
		push("karabiner.build", menu_mods.karabiner.build, ctx)
	end
	if type(menu_mods.gestures) == "table" then
		push("gestures.build", menu_mods.gestures.build, ctx)
	end


	table.insert(items, { title = "-" })
	table.insert(items, {
		title = "Actions globales",
		menu = {
			{ title = "☑ Activer toutes les fonctionnalités", fn = actions.enable_all },
			{ title = "☐ Désactiver toutes les fonctionnalités", fn = actions.disable_all },
			{ title = "↺ Réinitialiser les valeurs par défaut", fn = actions.reset_defaults }
		}
	})
	table.insert(items, { title = "Chemins des fichiers…", fn = actions.open_paths })
	table.insert(items, { title = "Console", fn = actions.open_console })
	table.insert(items, { title = "Ouvrir init.lua", fn = actions.open_init })
	table.insert(items, { title = "Recharger", fn = actions.reload })
	table.insert(items, { title = "Quitter", fn = actions.quit })

	-- Collect the download item now so it participates in canvas width calculation below
	local _dl_item = nil
	if type(ctx.llm_handler) == "table" and type(ctx.llm_handler.build_download_item) == "function" then
		_dl_item = ctx.llm_handler.build_download_item()
	end
	if _dl_item then
		table.insert(items, 1, { title = "-" })
		table.insert(items, 1, _dl_item)
	end

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
	local canvas_w = math.ceil(max_text_width)
	
	local paused = ctx and ctx.paused
	local display_text = paused and "Ergopti + (en pause)" or "Ergopti +"
	local ok, size = pcall(hs.drawing.getTextDrawingSize, display_text, { font = "Helvetica-Bold", size = 14 })
	local text_w = size.w
	
	-- Configure perfectly balanced padding for the pill
	local pad_x = 8
	local pad_y = 10
	local pill_w = math.ceil(text_w + (pad_x * 2))
	local pill_h = 14 + (pad_y * 2)
	
	-- Mathematically center the pill horizontally inside the transparent canvas
	local pill_x = (canvas_w - pill_w + 2 * pad_x) / 2
	
	local is_dark = hs.host.interfaceStyle() == "Dark"
	local bg_color   = is_dark and { white = 1 } or { white = 0.15 }
	local text_color = is_dark and { white = 0.1 } or { white = 1 }
	local menu_bg    = is_dark and { white = 0 } or { white = 1 }

	local paused = ctx and ctx.paused
	local orig_bg = bg_color
	local orig_text = text_color

	-- By default the pill uses bg_color; when paused we fill with the
	-- menubar background and add a thin border using a contrasting text color.
	local rect_fill = bg_color
	local rect_stroke = nil
	local rect_stroke_w = nil
	if paused then
		-- Fill with the menubar background so the pill blends in
		rect_fill = menu_bg
		-- Border/text should match the visible text color: white in Dark, black in Light.
		rect_stroke = is_dark and { white = 1 } or { white = 0 }
		text_color = rect_stroke
		rect_stroke_w = 1
	end
	
	local canvas_obj = hs.canvas.new({ x = 0, y = 0, w = canvas_w, h = pill_h })

	local rect_elem = {
		type             = "rectangle",
		action           = rect_stroke and "strokeAndFill" or "fill",
		fillColor        = rect_fill,
		roundedRectRadii = { xRadius = 8, yRadius = 8 },
		frame            = { x = pill_x, y = 0, w = pill_w, h = pill_h }
	}
	if rect_stroke then
		rect_elem.strokeColor = rect_stroke
		rect_elem.strokeWidth = rect_stroke_w
	end

	canvas_obj:appendElements(
		rect_elem,
		{
			type          = "text",
			text          = display_text,
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
		fn    = function()
			if ctx and ctx.script_control then
				if type(ctx.script_control.toggle_script_control) == "function" then pcall(ctx.script_control.toggle_script_control) end
				if type(ctx.script_control.toggle) == "function" then pcall(ctx.script_control.toggle) end
			end
		end,
	})
	table.insert(items, 2, { title = "-" })

	return items
end

return M
