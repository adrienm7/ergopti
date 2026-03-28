-- ui/menu/menu_keylogger.lua

-- ===========================================================================
-- Keylogger Menu UI Module.
--
-- Orchestrates the Keylogger & Metrics submenu.
-- Handles the security warning dialogs and calls the keylogger module.
-- ===========================================================================

local M = {}
local hs = hs

local AppPickerLib = require("lib.app_picker")





-- ==============================
-- ==============================
-- ======= 1/ Factory API =======
-- ==============================
-- ==============================

--- Builds the Keylogger menu item
--- @param ctx table Context containing state, updateMenu, save_prefs, etc.
--- @return table The menu definition table
function M.build(ctx)
	local state          = ctx.state
	local save_prefs     = ctx.save_prefs
	local updateMenu     = ctx.updateMenu
	local script_control = ctx.script_control

	local menu = {}
	
	table.insert(menu, {
		title    = "Afficher les métriques",
		disabled = not state.keylogger_enabled,
		fn       = function() 
			local Keylogger = require("modules.keylogger")
			Keylogger.show_metrics()
		end
	})

	table.insert(menu, { title = "-" })

	local disabled_count = #(type(state.keylogger_disabled_apps) == "table" and state.keylogger_disabled_apps or {})
	local label = "Désactivé dans" .. (disabled_count > 0 and (" " .. disabled_count .. " application" .. (disabled_count > 1 and "s" or "")) or " ces applications")
	
	table.insert(menu, {
		title = label,
		menu  = AppPickerLib.build_menu(
			state.keylogger_disabled_apps,
			function(new_list)
				state.keylogger_disabled_apps = new_list
				local Keylogger = require("modules.keylogger")
				if type(Keylogger.set_disabled_apps) == "function" then
					pcall(Keylogger.set_disabled_apps, new_list)
				end
				pcall(save_prefs)
				pcall(updateMenu)
			end,
			"Exclure des métriques de frappe…"
		)
	})

	return {
		title   = "Métriques de frappe 📊",
		checked = state.keylogger_enabled,
		fn      = function()
			if not state.keylogger_enabled then
				local warnMsg = "ATTENTION : Vous êtes sur le point d’activer le keylogger.\n\n" ..
								"Il enregistre vos frappes au clavier à la milliseconde près.\n" ..
								"Ces logs sont stockés en clair dans le dossier Hammerspoon.\n\n" ..
								"Il est fortement recommandé de mettre le script en PAUSE lors de la saisie de mots de passe ou de données sensibles."
				local res = hs.dialog.blockAlert("Avertissement de Sécurité", warnMsg, "Activer", "Annuler", "warning")
				if res ~= "Activer" then return end
			end
			
			state.keylogger_enabled = not state.keylogger_enabled
			
			local Keylogger = require("modules.keylogger")
			if state.keylogger_enabled then
				if type(Keylogger.set_disabled_apps) == "function" then
					Keylogger.set_disabled_apps(state.keylogger_disabled_apps or {})
				end
				Keylogger.start(script_control)
			else
				Keylogger.stop()
			end

			save_prefs()
			updateMenu()
		end,
		menu = menu
	}
end

return M
