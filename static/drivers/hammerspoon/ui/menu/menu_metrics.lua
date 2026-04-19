--- ui/menu/menu_metrics.lua

--- ==============================================================================
--- MODULE: Keylogger Menu UI
--- DESCRIPTION:
--- This module constructs and manages the "Metrics & Keylogger" submenu within
--- the global Hammerspoon menubar. It acts as the primary user interface for
--- toggling privacy settings, encryption, and real-time visualization widgets.
---
--- FEATURES & RATIONALE:
--- 1. Orchestration: Bridges the isolated UI components (menubar, widget) and
---    starts/stops them cleanly upon user toggling.
--- 2. Standalone App Link: Provides a direct link to open the GUI of the Encryptor.
--- 3. Keybindings: Supports parsing and assigning dynamic shortcuts for metrics.
--- 4. Asynchronous GUI: Employs local native Lua loops for real-time UI tracking
---    during mass encryption routines handled by the core module.
--- ==============================================================================

local M = {}
local hs = hs
local fs = require("hs.fs")

local AppPickerLib = require("lib.app_picker")
local dialog       = require("lib.dialog_util")
local kl_mod       = require("modules.keylogger")

local _prog_canvas = nil
local _is_initialized = false





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

M.DEFAULT_STATE = {
	keylogger_enabled                = kl_mod.DEFAULT_STATE.keylogger_enabled,
	keylogger_disabled_apps          = kl_mod.DEFAULT_STATE.keylogger_disabled_apps,
	keylogger_encrypt                = kl_mod.DEFAULT_STATE.keylogger_encrypt,
	keylogger_menubar_wpm            = kl_mod.DEFAULT_STATE.keylogger_menubar_wpm,
	keylogger_menubar_colors         = kl_mod.DEFAULT_STATE.keylogger_menubar_colors,
	keylogger_float_wpm              = kl_mod.DEFAULT_STATE.keylogger_float_wpm,
	keylogger_float_graph            = kl_mod.DEFAULT_STATE.keylogger_float_graph,
	keylogger_float_colors           = kl_mod.DEFAULT_STATE.keylogger_float_colors,
	keylogger_private_filter_enabled     = kl_mod.DEFAULT_STATE.keylogger_private_filter_enabled,
	keylogger_secure_filter_enabled      = kl_mod.DEFAULT_STATE.keylogger_secure_filter_enabled,
	keylogger_system_auth_filter_enabled = kl_mod.DEFAULT_STATE.keylogger_system_auth_filter_enabled,
	metrics_shortcut                 = false,
	apps_time_shortcut               = false,
}





-- ==================================
-- ==================================
-- ======= 2/ Local Utilities =======
-- ==================================
-- ==================================

--- Draws or updates the floating progress bar during mass encryption/decryption.
--- @param current_index number Current file count.
--- @param total_files number Total file count.
local function update_progress(current_index, total_files)
	if not _prog_canvas then
		local screen_frame = hs.screen.mainScreen():frame()
		local canvas_width, canvas_height = 400, 80
		_prog_canvas = hs.canvas.new({ x = (screen_frame.w - canvas_width) / 2, y = (screen_frame.h - canvas_height) / 2, w = canvas_width, h = canvas_height })
		_prog_canvas:behavior({ "canJoinAllSpaces", "stationary" }):level(hs.drawing.windowLevels.overlay)
	end

	local is_dark_mode = hs.host.interfaceStyle() == "Dark"
	local palette = {
		bg_color       = is_dark_mode and { white = 0, alpha = 0.8 } or { white = 0.95, alpha = 0.9 },
		text_color     = is_dark_mode and { white = 1 } or { white = 0 },
		track_color    = is_dark_mode and { white = 0.2, alpha = 1 } or { white = 0.85, alpha = 1 },
		progress_color = { hex = "#007aff", alpha = 1 }
	}

	local percentage = total_files > 0 and (current_index / total_files) or 0
	local ui_label = string.format("Traitement en cours : %d / %d", current_index, total_files)

	_prog_canvas:replaceElements({
		{ type = "rectangle", action = "fill", fillColor = palette.bg_color, roundedRectRadii = { xRadius = 10, yRadius = 10 } },
		{ type = "text", text = ui_label, frame = { x = 20, y = 15, w = 360, h = 25 }, textSize = 14, textColor = palette.text_color },
		{ type = "rectangle", action = "fill", frame = { x = 20, y = 45, w = 360, h = 10 }, fillColor = palette.track_color, roundedRectRadii = { xRadius = 5, yRadius = 5 } },
		{ type = "rectangle", action = "fill", frame = { x = 20, y = 45, w = 360 * percentage, h = 10 }, fillColor = palette.progress_color, roundedRectRadii = { xRadius = 5, yRadius = 5 } }
	})
	_prog_canvas:show()
end

--- Wraps the backend processing loop to provide UI feedback.
--- @param files_to_process table Array of absolute file paths.
--- @param is_encrypt boolean True to encrypt, false to decrypt.
--- @param password string The security key to provide to OpenSSL.
local function process_files_with_ui(files_to_process, is_encrypt, password)
	local total_files = #files_to_process
	update_progress(0, total_files)

	local function on_progress(current_index)
		update_progress(current_index, total_files)
	end
	
	local function on_complete(success_count, error_count, has_bad_password)
		if _prog_canvas then
			_prog_canvas:delete()
			_prog_canvas = nil
		end

		local alert_msg = string.format("Opération terminée.\n\nFichiers traités avec succès : %d\nErreurs rencontrées : %d", success_count, error_count)
		if has_bad_password then
			alert_msg = alert_msg .. "\n\n⚠️ Attention : Échec de déchiffrement détecté. Le mot de passe est potentiellement incorrect."
		end

		dialog.block_alert("Encryptor", alert_msg, "OK")
	end

	local log_manager = require("modules.keylogger.log_manager")
	if type(log_manager.process_files_async) == "function" then
		log_manager.process_files_async(files_to_process, is_encrypt, password, on_progress, on_complete)
	end
end





-- ==============================
-- ==============================
-- ======= 3/ Factory API =======
-- ==============================
-- ==============================

--- Builds the Keylogger menu item and defines callbacks.
--- @param ctx table Context containing state, updateMenu, save_prefs, etc.
--- @return table The menu definition table.
function M.build(ctx)
	local state          = ctx.state
	local save_prefs     = ctx.save_prefs
	local updateMenu     = ctx.updateMenu
	local script_control = ctx.script_control

	if not _is_initialized then
		_is_initialized = true
		if state.keylogger_enabled then
			local Keylogger = require("modules.keylogger")
			if type(Keylogger.set_options) == "function" then
				Keylogger.set_options({ encrypt = state.keylogger_encrypt })
			end
			if type(Keylogger.set_disabled_apps) == "function" then
				Keylogger.set_disabled_apps(state.keylogger_disabled_apps or {})
			end
			if type(Keylogger.set_private_filter_enabled) == "function" then
				Keylogger.set_private_filter_enabled(state.keylogger_private_filter_enabled ~= false)
			end
			if type(Keylogger.set_secure_field_filter_enabled) == "function" then
				Keylogger.set_secure_field_filter_enabled(state.keylogger_secure_filter_enabled ~= false)
			end
			if type(Keylogger.set_system_auth_filter_enabled) == "function" then
				Keylogger.set_system_auth_filter_enabled(state.keylogger_system_auth_filter_enabled ~= false)
			end

			Keylogger.start(script_control)
			
			if state.keylogger_menubar_wpm then 
				local WpmMenubar = require("ui.wpm.wpm_menubar")
				if type(WpmMenubar.set_use_source_colors) == "function" then
					WpmMenubar.set_use_source_colors(state.keylogger_menubar_colors)
				end
				WpmMenubar.start()
			end
			if state.keylogger_float_wpm then 
				local WpmWidget = require("ui.wpm.wpm_widget")
				if type(WpmWidget.set_use_source_colors) == "function" then
					WpmWidget.set_use_source_colors(state.keylogger_float_colors)
				end
				WpmWidget.start(state.keylogger_float_graph)
			end
		end
	end

	local menu = {}
	
	table.insert(menu, {
		title    = "Afficher les métriques de frappe",
		disabled = not state.keylogger_enabled,
		fn       = function() 
			local Keylogger = require("modules.keylogger")
			Keylogger.show_metrics()
		end
	})

	local sc_label_metrics = "Aucun"
	if type(state.metrics_shortcut) == "table" then
		local mods_cap = {}
		for _, m in ipairs(state.metrics_shortcut.mods or {}) do
			table.insert(mods_cap, m:sub(1,1):upper() .. m:sub(2))
		end
		local mods_str = table.concat(mods_cap, "+")
		sc_label_metrics = (mods_str ~= "" and (mods_str .. " + ") or "") .. string.upper(state.metrics_shortcut.key or "")
	end

	table.insert(menu, {
		title = "↳ Raccourci : " .. sc_label_metrics,
		disabled = not state.keylogger_enabled,
		fn = function()
			local current_str = ""
			if type(state.metrics_shortcut) == "table" then
				current_str = table.concat(state.metrics_shortcut.mods or {}, "+") .. "+" .. (state.metrics_shortcut.key or "")
			end
			local ok_p, btn, raw = pcall(dialog.text_prompt,
				"Raccourci métriques de frappe",
				"Format : mods+touche  (ex : cmd+alt+m)\nMods disponibles : cmd, alt, ctrl, shift\nLaisser vide pour désactiver",
				current_str, "OK", "Annuler"
			)
			if not ok_p or btn ~= "OK" or type(raw) ~= "string" then return end
			raw = raw:match("^%s*(.-)%s*$"):lower()
			if raw == "" then 
				if type(ctx.apply_metrics_shortcut) == "function" then ctx.apply_metrics_shortcut(nil, nil) end
				return 
			end
			local parts = {}
			for part in raw:gmatch("[^+]+") do table.insert(parts, part) end
			if #parts < 1 then return end
			local key  = parts[#parts]
			local mods = {}
			for i = 1, #parts - 1 do
				local m = parts[i]
				if m == "option" then m = "alt" end
				table.insert(mods, m)
			end
			if #mods == 0 then mods = {"ctrl"} end
			if type(ctx.apply_metrics_shortcut) == "function" then ctx.apply_metrics_shortcut(mods, key) end
		end
	})

	table.insert(menu, {
		title    = "Afficher le temps sur les applications",
		disabled = not state.keylogger_enabled,
		fn       = function() 
			local ok, at = pcall(require, "ui.metrics_apps")
			if ok and type(at.show) == "function" then
				pcall(at.show, hs.configdir .. "/logs")
			end
		end
	})

	local sc_label_apps = "Aucun"
	if type(state.apps_time_shortcut) == "table" then
		local mods_cap = {}
		for _, m in ipairs(state.apps_time_shortcut.mods or {}) do
			table.insert(mods_cap, m:sub(1,1):upper() .. m:sub(2))
		end
		local mods_str = table.concat(mods_cap, "+")
		sc_label_apps = (mods_str ~= "" and (mods_str .. " + ") or "") .. string.upper(state.apps_time_shortcut.key or "")
	end

	table.insert(menu, {
		title = "↳ Raccourci : " .. sc_label_apps,
		disabled = not state.keylogger_enabled,
		fn = function()
			local current_str = ""
			if type(state.apps_time_shortcut) == "table" then
				current_str = table.concat(state.apps_time_shortcut.mods or {}, "+") .. "+" .. (state.apps_time_shortcut.key or "")
			end
			local ok_p, btn, raw = pcall(dialog.text_prompt,
				"Raccourci temps apps",
				"Format : mods+touche  (ex : cmd+alt+t)\nMods disponibles : cmd, alt, ctrl, shift\nLaisser vide pour désactiver",
				current_str, "OK", "Annuler"
			)
			if not ok_p or btn ~= "OK" or type(raw) ~= "string" then return end
			raw = raw:match("^%s*(.-)%s*$"):lower()
			if raw == "" then 
				if type(ctx.apply_apps_time_shortcut) == "function" then ctx.apply_apps_time_shortcut(nil, nil) end
				return 
			end
			local parts = {}
			for part in raw:gmatch("[^+]+") do table.insert(parts, part) end
			if #parts < 1 then return end
			local key  = parts[#parts]
			local mods = {}
			for i = 1, #parts - 1 do
				local m = parts[i]
				if m == "option" then m = "alt" end
				table.insert(mods, m)
			end
			if #mods == 0 then mods = {"ctrl"} end
			if type(ctx.apply_apps_time_shortcut) == "function" then ctx.apply_apps_time_shortcut(mods, key) end
		end
	})

	table.insert(menu, { title = "-" })
	table.insert(menu, { title = "-" })

	table.insert(menu, {
		title = "Afficher le MPM dans la barre des menus",
		checked = state.keylogger_menubar_wpm,
		disabled = not state.keylogger_enabled,
		fn = function()
			state.keylogger_menubar_wpm = not state.keylogger_menubar_wpm
			save_prefs()
			local WpmMenubar = require("ui.wpm.wpm_menubar")
			if type(WpmMenubar.set_use_source_colors) == "function" then
				WpmMenubar.set_use_source_colors(state.keylogger_menubar_colors)
			end
			if state.keylogger_menubar_wpm then WpmMenubar.start() else WpmMenubar.stop() end
			updateMenu()
		end
	})

	table.insert(menu, {
		title = "↳ Couleurs selon la source",
		checked = state.keylogger_menubar_colors,
		disabled = not state.keylogger_enabled or not state.keylogger_menubar_wpm,
		fn = function()
			state.keylogger_menubar_colors = not state.keylogger_menubar_colors
			save_prefs()
			local WpmMenubar = require("ui.wpm.wpm_menubar")
			if type(WpmMenubar.set_use_source_colors) == "function" then
				WpmMenubar.set_use_source_colors(state.keylogger_menubar_colors)
			end
			if state.keylogger_menubar_wpm then WpmMenubar.start() end
			updateMenu()
		end
	})

	table.insert(menu, {
		title = "Afficher le MPM dans un widget flottant",
		checked = state.keylogger_float_wpm,
		disabled = not state.keylogger_enabled,
		fn = function()
			state.keylogger_float_wpm = not state.keylogger_float_wpm
			save_prefs()
			local WpmWidget = require("ui.wpm.wpm_widget")
			if type(WpmWidget.set_use_source_colors) == "function" then
				WpmWidget.set_use_source_colors(state.keylogger_float_colors)
			end
			if state.keylogger_float_wpm then WpmWidget.start(state.keylogger_float_graph) else WpmWidget.stop() end
			updateMenu()
		end
	})

	table.insert(menu, {
		title = "↳ Couleurs selon la source",
		checked = state.keylogger_float_colors,
		disabled = not state.keylogger_enabled or not state.keylogger_float_wpm,
		fn = function()
			state.keylogger_float_colors = not state.keylogger_float_colors
			save_prefs()
			local WpmWidget = require("ui.wpm.wpm_widget")
			if type(WpmWidget.set_use_source_colors) == "function" then
				WpmWidget.set_use_source_colors(state.keylogger_float_colors)
			end
			if state.keylogger_float_wpm then WpmWidget.start(state.keylogger_float_graph) end
			updateMenu()
		end
	})

	table.insert(menu, {
		title = "↳ Inclure le graphique en temps réel",
		checked = state.keylogger_float_graph,
		disabled = not state.keylogger_enabled or not state.keylogger_float_wpm,
		fn = function()
			state.keylogger_float_graph = not state.keylogger_float_graph
			save_prefs()
			local WpmWidget = require("ui.wpm.wpm_widget")
			if type(WpmWidget.set_use_source_colors) == "function" then
				WpmWidget.set_use_source_colors(state.keylogger_float_colors)
			end
			if state.keylogger_float_wpm then WpmWidget.start(state.keylogger_float_graph) end
			updateMenu()
		end
	})

	table.insert(menu, { title = "-" })
	table.insert(menu, { title = "-" })
	table.insert(menu, { title = "— FILTRES DE CONFIDENTIALITÉ —", disabled = true })

	table.insert(menu, {
		title    = "Ignorer la navigation privée",
		checked  = state.keylogger_private_filter_enabled,
		disabled = not state.keylogger_enabled,
		fn       = function()
			state.keylogger_private_filter_enabled = not state.keylogger_private_filter_enabled
			local Keylogger = require("modules.keylogger")
			if type(Keylogger.set_private_filter_enabled) == "function" then
				pcall(Keylogger.set_private_filter_enabled, state.keylogger_private_filter_enabled)
			end
			save_prefs(); updateMenu()
		end
	})

	table.insert(menu, {
		title    = "Ignorer les champs mot de passe",
		checked  = state.keylogger_secure_filter_enabled,
		disabled = not state.keylogger_enabled,
		fn       = function()
			state.keylogger_secure_filter_enabled = not state.keylogger_secure_filter_enabled
			local Keylogger = require("modules.keylogger")
			if type(Keylogger.set_secure_field_filter_enabled) == "function" then
				pcall(Keylogger.set_secure_field_filter_enabled, state.keylogger_secure_filter_enabled)
			end
			save_prefs(); updateMenu()
		end
	})

	table.insert(menu, {
		title    = "Ignorer les boîtes de dialogue d'authentification système",
		checked  = state.keylogger_system_auth_filter_enabled,
		disabled = not state.keylogger_enabled,
		fn       = function()
			state.keylogger_system_auth_filter_enabled = not state.keylogger_system_auth_filter_enabled
			local Keylogger = require("modules.keylogger")
			if type(Keylogger.set_system_auth_filter_enabled) == "function" then
				pcall(Keylogger.set_system_auth_filter_enabled, state.keylogger_system_auth_filter_enabled)
			end
			save_prefs(); updateMenu()
		end
	})

	local disabled_count = #(type(state.keylogger_disabled_apps) == "table" and state.keylogger_disabled_apps or {})
	local label = "Désactivé dans" .. (disabled_count > 0 and (" " .. disabled_count .. " application" .. (disabled_count > 1 and "s" or "")) or " ces applications")

	local exclusion_menu = AppPickerLib.build_menu(
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

	table.insert(menu, {
		title    = label,
		disabled = not state.keylogger_enabled,
		menu     = exclusion_menu
	})

	table.insert(menu, { title = "-" })
	table.insert(menu, { title = "-" })



	-- =================================
	-- ===== 3.1) Encryption Logic =====
	-- =================================

	table.insert(menu, {
		title    = "Chiffrer les logs sur le disque (Sécurité)",
		checked  = state.keylogger_encrypt,
		disabled = not state.keylogger_enabled,
		fn = function()
			local log_manager = require("modules.keylogger.log_manager")
			local log_dir = hs.configdir .. "/logs"
			local default_pwd = "ERGOPTI_FALLBACK_KEY"
			if type(log_manager.get_mac_serial) == "function" then default_pwd = log_manager.get_mac_serial() end

			if not state.keylogger_encrypt then
				local alert_msg = "L’activation va chiffrer tous vos anciens logs pour qu’ils soient illisibles sur le disque.\n\nConfirmer ?"
				local res = dialog.block_alert("Protection des données", alert_msg, "Chiffrer", "Annuler")
				if res ~= "Chiffrer" then return end

				local ok_prompt, btn, pwd = pcall(dialog.text_prompt, "Clé de sécurité", "Veuillez définir la clé de chiffrement (par défaut: numéro de série du Mac) :", default_pwd, "OK", "Annuler")
				if not ok_prompt or btn ~= "OK" or type(pwd) ~= "string" or pwd == "" then return end

				if type(log_manager.register_encryptor_app) == "function" then
					pcall(log_manager.register_encryptor_app)
				end

				local files_to_process = {}
				for file in fs.dir(log_dir) do
					if file:match("%.log%.gz$") and not file:match("%.enc$") then
						table.insert(files_to_process, log_dir .. "/" .. file)
					end
				end

				state.keylogger_encrypt = true
				save_prefs()

				local Keylogger = require("modules.keylogger")
				if type(Keylogger.set_options) == "function" then
					Keylogger.set_options({ encrypt = state.keylogger_encrypt })
				end
				updateMenu()

				if #files_to_process > 0 then
					process_files_with_ui(files_to_process, true, pwd)
				end
			else
				local alert_msg = "Tous vos logs chiffrés vont être restaurés en clair sur le disque.\n\nConfirmer ?"
				local res = dialog.block_alert("Désactivation", alert_msg, "Déchiffrer", "Annuler")
				if res ~= "Déchiffrer" then return end

				local ok_prompt, btn, pwd = pcall(dialog.text_prompt, "Clé de sécurité", "Entrez la clé de sécurité nécessaire au déchiffrement :", default_pwd, "OK", "Annuler")
				if not ok_prompt or btn ~= "OK" or type(pwd) ~= "string" or pwd == "" then return end

				local files_to_process = {}
				for file in fs.dir(log_dir) do
					if file:match("%.enc$") then
						table.insert(files_to_process, log_dir .. "/" .. file)
					end
				end

				state.keylogger_encrypt = false
				save_prefs()

				local Keylogger = require("modules.keylogger")
				if type(Keylogger.set_options) == "function" then
					Keylogger.set_options({ encrypt = state.keylogger_encrypt })
				end
				updateMenu()

				if #files_to_process > 0 then
					process_files_with_ui(files_to_process, false, pwd)
				end
			end
		end
	})

	table.insert(menu, {
		title = "↳ Ouvrir l’Encryptor autonome...",
		fn = function()
			local app_path = hs.configdir .. "/utils/encryptor/Encryptor.app"
			if fs.attributes(app_path) then
				hs.execute(string.format("open %q", app_path))
			else
				dialog.block_alert("Erreur", "L’application est introuvable. Veuillez d’abord générer l’application avec le script Python.", "OK")
			end
		end
	})

	return {
		title   = "Métriques 📊",
		checked = state.keylogger_enabled,
		fn      = function()
			if not state.keylogger_enabled then
				local warnMsg = "ATTENTION : Vous êtes sur le point d’activer le keylogger.\n\nIl enregistre vos frappes au clavier à la milliseconde près.\nCes logs sont stockés dans le dossier Hammerspoon.\n\nBien que les champs de mots de passe soient ignorés automatiquement, il est recommandé de mettre le script en PAUSE lors de la saisie de données sensibles."
				local res = dialog.block_alert("Avertissement de Sécurité", warnMsg, "Activer", "Annuler", "warning")
				if res ~= "Activer" then return end
			end

			state.keylogger_enabled = not state.keylogger_enabled

			local Keylogger  = require("modules.keylogger")
			local WpmMenubar = require("ui.wpm.wpm_menubar")
			local WpmWidget  = require("ui.wpm.wpm_widget")

			if state.keylogger_enabled then
				if type(Keylogger.set_options) == "function" then
					Keylogger.set_options({ encrypt = state.keylogger_encrypt })
				end
				if type(Keylogger.set_disabled_apps) == "function" then
					Keylogger.set_disabled_apps(state.keylogger_disabled_apps or {})
				end

				Keylogger.start(script_control)

				if type(WpmMenubar.set_use_source_colors) == "function" then
					WpmMenubar.set_use_source_colors(state.keylogger_menubar_colors)
				end
				if type(WpmWidget.set_use_source_colors) == "function" then
					WpmWidget.set_use_source_colors(state.keylogger_float_colors)
				end

				if state.keylogger_menubar_wpm then WpmMenubar.start() end
				if state.keylogger_float_wpm then WpmWidget.start(state.keylogger_float_graph) end
			else
				Keylogger.stop()
				WpmMenubar.stop()
				WpmWidget.stop()
			end

			save_prefs()
			updateMenu()
		end,
		menu = menu
	}
end

return M
