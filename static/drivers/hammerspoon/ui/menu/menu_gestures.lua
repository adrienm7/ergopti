--- ui/menu/menu_gestures.lua

--- ==============================================================================
--- MODULE: Menu Gestures
--- DESCRIPTION:
--- Orchestrates the gestures submenu interface.
--- ==============================================================================

local M = {}
local hs = hs

local gestures_mod = require("modules.gestures")
local dialog       = require("lib.dialog_util")





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

M.DEFAULT_STATE = {
	gestures = gestures_mod.DEFAULT_STATE.gestures
}





-- ====================================
-- ====================================
-- ======= 2/ Menu Construction =======
-- ====================================
-- ====================================

local SLOT_LABELS = {
	tap_2                = "Tap 2 doigts",
	tap_3                = "Tap 3 doigts",
	tap_4                = "Tap 4 doigts",
	tap_5                = "Tap 5 doigts",

	swipe_2_left         = "Swipe 2 doigts ←",
	swipe_2_right        = "Swipe 2 doigts →",
	swipe_2_up           = "Swipe 2 doigts ↑",
	swipe_2_down         = "Swipe 2 doigts ↓",
	swipe_2_left_up      = "Swipe 2 doigts ↖",
	swipe_2_right_up     = "Swipe 2 doigts ↗",
	swipe_2_left_down    = "Swipe 2 doigts ↙",
	swipe_2_right_down   = "Swipe 2 doigts ↘",

	swipe_3_left         = "Swipe 3 doigts ←",
	swipe_3_right        = "Swipe 3 doigts →",
	swipe_3_up           = "Swipe 3 doigts ↑",
	swipe_3_down         = "Swipe 3 doigts ↓",
	swipe_3_left_up      = "Swipe 3 doigts ↖",
	swipe_3_right_up     = "Swipe 3 doigts ↗",
	swipe_3_left_down    = "Swipe 3 doigts ↙",
	swipe_3_right_down   = "Swipe 3 doigts ↘",

	swipe_4_left         = "Swipe 4 doigts ←",
	swipe_4_right        = "Swipe 4 doigts →",
	swipe_4_up           = "Swipe 4 doigts ↑",
	swipe_4_down         = "Swipe 4 doigts ↓",
	swipe_4_left_up      = "Swipe 4 doigts ↖",
	swipe_4_right_up     = "Swipe 4 doigts ↗",
	swipe_4_left_down    = "Swipe 4 doigts ↙",
	swipe_4_right_down   = "Swipe 4 doigts ↘",

	swipe_5_left         = "Swipe 5 doigts ←",
	swipe_5_right        = "Swipe 5 doigts →",
	swipe_5_up           = "Swipe 5 doigts ↑",
	swipe_5_down         = "Swipe 5 doigts ↓",
	swipe_5_left_up      = "Swipe 5 doigts ↖",
	swipe_5_right_up     = "Swipe 5 doigts ↗",
	swipe_5_left_down    = "Swipe 5 doigts ↙",
	swipe_5_right_down   = "Swipe 5 doigts ↘",
}

local DISABLED_GESTURE_ACTION = "none"

--- Builds the gestures sub-menu.
--- @param ctx table Context containing state, updateMenu, save_prefs, etc.
--- @return table|nil The menu definition table.
function M.build(ctx)
	local gestures = ctx.gestures
	if not gestures then return nil end

	local state  = ctx.state
	local paused = ctx.paused

	local item = {
		title   = "🖐️ Gestes",
		checked = (state.gestures and not paused) or nil,
		fn      = function()
			local new_state = not state.gestures
			if new_state then
				-- Show warning when activating gestures
				local warnMsg = "⚠️ Attention : L'activation des gestes trackpad peut interférer avec les gestes système.\n\nPour éviter les conflits, désactiver les options macOS suivantes :\n\n• Gestes trackpad 2 doigts : désactiver le défilement et les balayages si vous voulez les utiliser dans Hammerspoon.\n• Gestes trackpad 3 doigts pour bouger les fenêtres et la sélection\n• Tap 3 doigts pour chercher le mot dans le dictionnaire\n• Swipe 3 doigts horizontal/vertical pour changer de spaces, activer App Exposé ou Mission Control\n• Swipe 4 doigts horizontal/vertical pour changer de spaces, activer App Exposé ou Mission Control\n\nIl est important de désactiver les gestes système utilisant 4 doigts afin de pouvoir définir des gestes à 5 doigts. Autrement, macOS ne ferait pas de distinction entre les deux et empêcherait les gestes à 5 doigts de fonctionner. C’est pourquoi les gestes à 4 doigts par défaut son redéfinis dans le module Gestes pour retrouver les fonctions système sans conflit avec les gestes à 5 doigts."
				local res = dialog.block_alert("Avertissement Gestes", warnMsg, "Activer", "Annuler", "warning")
				if res ~= "Activer" then return end
			end
			state.gestures = new_state
			if gestures then
				if state.gestures then 
					if type(gestures.enable_all) == "function" then pcall(gestures.enable_all) end 
				else 
					if type(gestures.disable_all) == "function" then pcall(gestures.disable_all) end 
				end
			end
			ctx.save_prefs()
			ctx.notify_feature("Gestes", state.gestures)
			ctx.updateMenu()
		end,
	}



	-- =================================
	-- ===== 2.1) Helper Functions =====
	-- =================================

	--- Generates a menu item for a specific gesture slot.
	--- @param slot string The internal slot identifier.
	--- @return table The slot menu definition.
	local function slotItem(slot)
		local current     = type(gestures.get_action) == "function" and gestures.get_action(slot) or nil
		local currentMode = type(gestures.get_mode) == "function" and gestures.get_mode(slot) or "x1"
		local currentSens = type(gestures.get_sensitivity) == "function" and gestures.get_sensitivity(slot) or 3.5
		
		local slotLbl   = SLOT_LABELS[slot] or slot
		local actionLbl = type(gestures.get_action_label) == "function" and gestures.get_action_label(current) or "Inconnu"
		
		local names     = gestures.SG_NAMES
		local actionsSubmenu   = {}

		if type(names) == "table" then
			for _, aname in ipairs(names) do
				if aname == "-" or aname == "--" then
					table.insert(actionsSubmenu, { title = "-" })
				elseif aname:sub(1, 1) == "#" then
					table.insert(actionsSubmenu, { title = aname:sub(2), disabled = true })
				else
					table.insert(actionsSubmenu, {
						title    = type(gestures.get_action_label) == "function" and gestures.get_action_label(aname) or aname,
						checked  = ((current == aname) and not paused) or nil,
						disabled = not state.gestures or paused or nil,
						fn       = (state.gestures and not paused) and (function(a) return function()
							if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, a) end
							local conflict = type(gestures.on_action_changed) == "function" and gestures.on_action_changed(slot, a) or nil
							ctx.save_prefs()
							ctx.updateMenu()
							if type(conflict) == "table" then
								hs.timer.doAfter(0.3, function()
									local ok_c, clicked = pcall(dialog.block_alert,
										"⚠️ Conflit potentiel", conflict.msg or "",
										"Ouvrir Réglages", "OK", "warning")
									if ok_c and clicked == "Ouvrir Réglages" then
										pcall(hs.execute, string.format("open \"%s\"", conflict.url or ""))
									end
								end)
							end
						end end)(aname) or nil,
					})
				end
			end
		end

		local modeSubmenu = {
			{
				title = "Action unique (x1)",
				checked = (currentMode == "x1") or nil,
				fn = function()
					if type(gestures.set_mode) == "function" then pcall(gestures.set_mode, slot, "x1") end
					ctx.save_prefs()
					ctx.updateMenu()
				end
			},
			{
				title = "Envoi incrémental (distance)",
				checked = (currentMode == "incremental") or nil,
				fn = function()
					if type(gestures.set_mode) == "function" then pcall(gestures.set_mode, slot, "incremental") end
					ctx.save_prefs()
					ctx.updateMenu()
				end
			}
		}

		local sensSubmenu = {
			{ title = "Distance par action (Sensibilité) :", disabled = true },
			{ title = "(Plus petit = Plus sensible/réactif)", disabled = true },
			{ title = "-" },
		}
		local sensitivities = { 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 6.0, 7.0, 8.0, 10.0, 12.0, 15.0, 20.0, 25.0, 30.0 }
		for _, s in ipairs(sensitivities) do
			local label = string.format("%.1f", s)
			if s == 3.5 then label = label .. " (Défaut général)" end

			table.insert(sensSubmenu, {
				title = label,
				checked = (currentSens == s) or nil,				fn = function()
					if type(gestures.set_sensitivity) == "function" then pcall(gestures.set_sensitivity, slot, s) end
					ctx.save_prefs()
					ctx.updateMenu()
				end
			})
		end

		local finalSubmenu = {
			{ title = "Action : " .. actionLbl, menu = actionsSubmenu },
		}
		
		if slot:match("swipe") then
			table.insert(finalSubmenu, { title = "Mode : " .. (currentMode == "incremental" and "Incrémental" or "Unique"), menu = modeSubmenu })
			table.insert(finalSubmenu, { title = "Sensibilité : " .. string.format("%.1f", currentSens), menu = sensSubmenu, disabled = (currentMode ~= "incremental") or nil })
		end

		return {
			title    = slotLbl .. " : " .. actionLbl,
			disabled = not state.gestures or paused or nil,
			menu     = finalSubmenu,
		}
	end

	--- Generates a section of gesture items.
	--- @param slots table List of slot identifiers.
	--- @return table The section menu items.
	local function section(slots)
		local its = {}
		for _, slot in ipairs(slots) do table.insert(its, slotItem(slot)) end
		return its
	end

	local gm = {}

	-- Quick-action buttons at the top, mirroring the karabiner menu pattern
	table.insert(gm, {
		title = "✕ Désactiver tous les gestes",
		fn    = function()
			local gestures_enabled = state.gestures == true
			local all_slots = gestures_mod.SINGLE_SLOTS or {}
			for _, slot in ipairs(all_slots) do
				if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, DISABLED_GESTURE_ACTION) end
			end
			state.gestures = gestures_enabled
			if gestures_enabled then
				if type(gestures.enable_all) == "function" then pcall(gestures.enable_all) end
			else
				if type(gestures.disable_all) == "function" then pcall(gestures.disable_all) end
			end
			ctx.save_prefs()
			ctx.updateMenu()
		end,
	})
	table.insert(gm, {
		title = "↩ Restaurer les valeurs par défaut",
		fn    = function()
			local defaults = gestures_mod.DEFAULT_GESTURES or {}
			for slot, action in pairs(defaults) do
				if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, action) end
			end
			ctx.save_prefs()
			ctx.updateMenu()
		end,
	})
	table.insert(gm, { title = "-" })

	-- Global Settings
	table.insert(gm, {
		title = "Navigation circulaire des Spaces (1 ↔ N)",
		checked = (type(gestures.get_space_wrap) == "function" and gestures.get_space_wrap()) or nil,
		disabled = not state.gestures or paused or nil,
		fn = function()
			if type(gestures.get_space_wrap) == "function" and type(gestures.set_space_wrap) == "function" then
				pcall(gestures.set_space_wrap, not gestures.get_space_wrap())
				ctx.save_prefs()
				ctx.updateMenu()
			end
		end
	})
	table.insert(gm, { title = "-" })

	-- 2 Fingers
	table.insert(gm, slotItem("tap_2"))
	for _, it in ipairs(section({"swipe_2_left", "swipe_2_right", "swipe_2_up", "swipe_2_down"})) do table.insert(gm, it) end
	for _, it in ipairs(section({"swipe_2_left_up", "swipe_2_right_up", "swipe_2_left_down", "swipe_2_right_down"})) do table.insert(gm, it) end
	table.insert(gm, { title = "-" })

	-- 3 Fingers
	table.insert(gm, slotItem("tap_3"))
	for _, it in ipairs(section({"swipe_3_left", "swipe_3_right", "swipe_3_up", "swipe_3_down"})) do table.insert(gm, it) end
	for _, it in ipairs(section({"swipe_3_left_up", "swipe_3_right_up", "swipe_3_left_down", "swipe_3_right_down"})) do table.insert(gm, it) end
	table.insert(gm, { title = "-" })
	
	-- 4 Fingers
	table.insert(gm, slotItem("tap_4"))
	for _, it in ipairs(section({"swipe_4_left", "swipe_4_right", "swipe_4_up", "swipe_4_down"})) do table.insert(gm, it) end
	for _, it in ipairs(section({"swipe_4_left_up", "swipe_4_right_up", "swipe_4_left_down", "swipe_4_right_down"})) do table.insert(gm, it) end
	table.insert(gm, { title = "-" })
	
	-- 5 Fingers
	table.insert(gm, slotItem("tap_5"))
	for _, it in ipairs(section({"swipe_5_left", "swipe_5_right", "swipe_5_up", "swipe_5_down"})) do table.insert(gm, it) end
	for _, it in ipairs(section({"swipe_5_left_up", "swipe_5_right_up", "swipe_5_left_down", "swipe_5_right_down"})) do table.insert(gm, it) end
	
	item.menu = gm
	return item
end

return M
