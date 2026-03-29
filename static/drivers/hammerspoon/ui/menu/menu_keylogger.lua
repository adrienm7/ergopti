--- ui/menu/menu_keylogger.lua

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
--- 2. Mass Encryption Toggle: Employs local native Lua loops to encrypt or decrypt
---    massive historical log fragments asynchronously with real-time UI tracking.
--- 3. Strict Log Targeting: Specifically targets only `.log.gz` files for security operations,
---    leaving mathematical `.idx` fragments in plain text for fast dashboard loading.
--- 4. Standalone App Link: Provides a direct link to open the GUI of the Encryptor.
--- 5. Keybindings: Supports parsing and assigning dynamic shortcuts for metrics.
--- 6. Dynamic Registration: Registers the .enc file association dynamically on
---    the user's OS when encryption is explicitly enabled.
--- ==============================================================================

local M = {}
local hs = hs
local fs = require("hs.fs")

local AppPickerLib = require("lib.app_picker")

local _prog_canvas = nil
local _is_initialized = false





-- ===================================
-- ===================================
-- ======= 1/ Local Utilities ========
-- ===================================
-- ===================================

--- Retrieves a dynamic hardware identifier to act as the default fallback password.
--- @return string The hardware serial key or dynamic fallback.
local function get_mac_serial()
	local ok, serial = pcall(hs.execute, "ioreg -l | grep IOPlatformSerialNumber | sed 's/.*= \"//;s/\"//'")
	if ok and serial and serial ~= "" and not serial:find("UNKNOWN") then 
		return serial:gsub("%s+", "") 
	end
	
	-- Fallback dynamically to the root volume UUID
	local ok_uuid, uuid = pcall(hs.execute, "diskutil info / | awk '/Volume UUID/ {print $3}'")
	if ok_uuid and uuid and uuid ~= "" then
		return uuid:gsub("%s+", "")
	end
	
	-- Ultimate failsafe based on local username
	return os.getenv("USER") or "admin"
end

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

--- Processes a list of files sequentially without blocking the main UI thread.
--- Manages the encryption/decryption execution and original file cleanup.
--- @param files_to_process table Array of absolute file paths.
--- @param is_encrypt boolean True to encrypt, false to decrypt.
--- @param password string The security key to provide to OpenSSL.
local function process_files_locally(files_to_process, is_encrypt, password)
	local total_files = #files_to_process
	local current_index = 0
	local success_count = 0
	local error_count = 0
	local has_bad_password = false

	update_progress(0, total_files)

	local function process_next()
		if current_index >= total_files then
			if _prog_canvas then
				_prog_canvas:delete()
				_prog_canvas = nil
			end
			
			local alert_msg = string.format("Opération terminée.\n\nFichiers traités avec succès : %d\nErreurs rencontrées : %d", success_count, error_count)
			if has_bad_password then
				alert_msg = alert_msg .. "\n\n⚠️ Attention : Échec de déchiffrement détecté. Le mot de passe est potentiellement incorrect."
			end
			
			hs.dialog.blockAlert("Encryptor", alert_msg, "OK")
			return
		end

		current_index = current_index + 1
		local target_file = files_to_process[current_index]
		local safe_password = password:gsub("\"", "\\\"")

		if is_encrypt then
			local output_file = target_file .. ".enc"
			local shell_cmd = string.format("openssl enc -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" -in %q > %q 2>&1", safe_password, target_file, output_file)
			local output, status = hs.execute(shell_cmd)
			
			if status then
				os.remove(target_file)
				success_count = success_count + 1
			else
				os.remove(output_file)
				error_count = error_count + 1
			end
		else
			local output_file = target_file:gsub("%.enc$", "")
			local shell_cmd = string.format("openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" -in %q > %q 2>&1", safe_password, target_file, output_file)
			local output, status = hs.execute(shell_cmd)
			
			if status then
				os.remove(target_file)
				success_count = success_count + 1
			else
				os.remove(output_file)
				error_count = error_count + 1
				if output and output:match("bad decrypt") then
					has_bad_password = true
				end
			end
		end

		update_progress(current_index, total_files)
		hs.timer.doAfter(0.01, process_next)
	end

	-- Kickstart the async recursive loop
	hs.timer.doAfter(0.05, process_next)
end





-- ==============================
-- ==============================
-- ======= 2/ Factory API =======
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

	-- Safely auto-start the daemons once upon Hammerspoon reload
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
			
			Keylogger.start(script_control)
			
			if state.keylogger_menubar_wpm then 
				require("ui.wpm.wpm_menubar").start() 
			end
			if state.keylogger_float_wpm then 
				require("ui.wpm.wpm_widget").start(state.keylogger_float_graph) 
			end
		end
	end

	local menu = {}
	
	table.insert(menu, {
		title    = "Afficher les métriques",
		disabled = not state.keylogger_enabled,
		fn       = function() 
			local Keylogger = require("modules.keylogger")
			Keylogger.show_metrics()
		end
	})

	local sc_label = "Aucun"
	if type(state.metrics_shortcut) == "table" then
		local mods_cap = {}
		for _, m in ipairs(state.metrics_shortcut.mods or {}) do
			table.insert(mods_cap, m:sub(1,1):upper() .. m:sub(2))
		end
		local mods_str = table.concat(mods_cap, "+")
		sc_label = (mods_str ~= "" and (mods_str .. " + ") or "") .. string.upper(state.metrics_shortcut.key or "")
	end

	table.insert(menu, {
		title = "Raccourci : " .. sc_label,
		disabled = not state.keylogger_enabled,
		fn = function()
			local current_str = ""
			if type(state.metrics_shortcut) == "table" then
				current_str = table.concat(state.metrics_shortcut.mods or {}, "+") .. "+" .. (state.metrics_shortcut.key or "")
			end
			local ok_p, btn, raw = pcall(hs.dialog.textPrompt,
				"Raccourci métriques",
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

	table.insert(menu, { title = "-" })

	table.insert(menu, {
		title = "Afficher le MPM dans la barre des menus",
		checked = state.keylogger_menubar_wpm,
		disabled = not state.keylogger_enabled,
		fn = function()
			state.keylogger_menubar_wpm = not state.keylogger_menubar_wpm
			save_prefs()
			local WpmMenubar = require("ui.wpm.wpm_menubar")
			if state.keylogger_menubar_wpm then WpmMenubar.start() else WpmMenubar.stop() end
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
			if state.keylogger_float_wpm then WpmWidget.start(state.keylogger_float_graph) else WpmWidget.stop() end
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
			if state.keylogger_float_wpm then WpmWidget.start(state.keylogger_float_graph) end
			updateMenu()
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

	table.insert(menu, { title = "-" })



	-- =================================
	-- ===== 2.1) Encryption Logic =====
	-- =================================

	table.insert(menu, {
		title = "Chiffrer les logs sur le disque (Sécurité)",
		checked = state.keylogger_encrypt,
		fn = function()
			local log_dir = hs.configdir .. "/logs"
			local app_path = hs.configdir .. "/utils/encryptor/Encryptor.app"

			if not state.keylogger_encrypt then
				local alert_msg = "L’activation va chiffrer tous vos anciens logs pour qu’ils soient illisibles sur le disque.\n\nConfirmer ?"
				local res = hs.dialog.blockAlert("Protection des données", alert_msg, "Chiffrer", "Annuler")
				if res ~= "Chiffrer" then return end

				local ok_prompt, btn, pwd = pcall(hs.dialog.textPrompt, "Clé de sécurité", "Veuillez définir la clé de chiffrement (par défaut: numéro de série du Mac) :", get_mac_serial(), "OK", "Annuler")
				if not ok_prompt or btn ~= "OK" or type(pwd) ~= "string" or pwd == "" then return end

				-- Register the app dynamically to LaunchServices so double-clicking .enc files works natively
				if fs.attributes(app_path) then
					local lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
					hs.execute(string.format("%s -f %q", lsregister, app_path))
				end

				-- Strict targeting: Only select compressed .log.gz files to avoid encrypting indexes
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
					process_files_locally(files_to_process, true, pwd)
				end

			else
				local alert_msg = "Tous vos logs chiffrés vont être restaurés en clair sur le disque.\n\nConfirmer ?"
				local res = hs.dialog.blockAlert("Désactivation", alert_msg, "Déchiffrer", "Annuler")
				if res ~= "Déchiffrer" then return end
				
				local ok_prompt, btn, pwd = pcall(hs.dialog.textPrompt, "Clé de sécurité", "Entrez la clé de sécurité nécessaire au déchiffrement :", get_mac_serial(), "OK", "Annuler")
				if not ok_prompt or btn ~= "OK" or type(pwd) ~= "string" or pwd == "" then return end
				
				-- Ensure all encrypted files are fully wiped (.log.gz.enc, .idx.gz.enc, etc.)
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
					process_files_locally(files_to_process, false, pwd)
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
				hs.dialog.blockAlert("Erreur", "L’application est introuvable. Veuillez d’abord générer l’application avec le script Python.", "OK")
			end
		end
	})

	return {
		title   = "Métriques de frappe 📊",
		checked = state.keylogger_enabled,
		fn      = function()
			if not state.keylogger_enabled then
				local warnMsg = "ATTENTION : Vous êtes sur le point d’activer le keylogger.\n\nIl enregistre vos frappes au clavier à la milliseconde près.\nCes logs sont stockés dans le dossier Hammerspoon.\n\nBien que les champs de mots de passe soient ignorés automatiquement, il est recommandé de mettre le script en PAUSE lors de la saisie de données ultra-sensibles."
				local res = hs.dialog.blockAlert("Avertissement de Sécurité", warnMsg, "Activer", "Annuler", "warning")
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
