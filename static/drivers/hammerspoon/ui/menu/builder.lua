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
	
	-- Helper local pour insérer uniquement les composants valides et loguer les erreurs
	local function push(label, fn, arg)
		local result = Logger.build(LOG, label, fn, arg)
		if result then
			if type(result) == "table" and result[1] ~= nil then
				-- Résultat est une liste (build_groups)
				for _, it in ipairs(result) do table.insert(items, it) end
			else
				table.insert(items, result)
			end
			Logger.debug(LOG, "Composant '%s' ajouté avec succès", label)
		else
			Logger.warn(LOG, "Composant '%s' absent ou en erreur — ignoré", label)
		end
	end

	-- Zone hotstrings
	if type(menu_mods.hotstrings) == "table" then
		Logger.debug(LOG, "Construction zone hotstrings")
		push("hotstrings.build_groups",     menu_mods.hotstrings.build_groups,     ctx)
		table.insert(items, { title = "-" })
		push("hotstrings.build_management", menu_mods.hotstrings.build_management, ctx)
		push("hotstrings.build_personal",   menu_mods.hotstrings.build_personal,   ctx)
		push("hotstrings.build_custom",     menu_mods.hotstrings.build_custom,     ctx)
	else
		Logger.warn(LOG, "Module hotstrings absent — zone ignorée")
	end

	table.insert(items, { title = "-" })

	-- Zone IA
	if type(ctx.llm_handler) == "table" and type(ctx.llm_handler.build_item) == "function" then
		Logger.debug(LOG, "Construction composant IA")
		local ok_b, llm_item = pcall(ctx.llm_handler.build_item)
		if ok_b and llm_item then
			table.insert(items, llm_item)
			Logger.debug(LOG, "Composant IA ajouté")
		elseif not ok_b then
			Logger.error(LOG, "Erreur construction composant IA : %s", tostring(llm_item))
		end
	else
		Logger.warn(LOG, "llm_handler absent ou incomplet — composant IA ignoré")
	end

	-- Zone métriques
	if type(menu_mods.keylogger) == "table" then
		push("keylogger.build", menu_mods.keylogger.build, ctx)
	else
		Logger.warn(LOG, "Module keylogger absent")
	end

	table.insert(items, { title = "-" })

	-- Zone gestes et raccourcis
	if type(menu_mods.gestures) == "table" then
		push("gestures.build", menu_mods.gestures.build, ctx)
	end
	if type(menu_mods.shortcuts) == "table" then
		push("shortcuts.build", menu_mods.shortcuts.build, ctx)
	end

	-- Zone script control (chargement dynamique)
	local ok_sc, script_control_mod = pcall(require, "ui.menu.menu_script_control")
	if ok_sc and type(script_control_mod) == "table" then
		push("script_control.build", script_control_mod.build, ctx)
	else
		Logger.debug(LOG, "Module script_control non disponible — ignoré")
	end

	table.insert(items, { title = "-" })
	table.insert(items, { title = "☑ Activer toutes les fonctionnalités", fn = actions.enable_all })
	table.insert(items, { title = "☐ Désactiver toutes les fonctionnalités", fn = actions.disable_all })
	table.insert(items, { title = "↺ Réinitialiser les valeurs par défaut", fn = actions.reset_defaults })
	
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
