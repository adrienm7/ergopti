-- ui/menu/menu_llm/init.lua

-- ===========================================================================
-- LLM Menu UI Module (Main Coordinator).
--
-- Orchestrates the Artificial Intelligence submenu by aggregating logic from:
--   - models_manager.lua   (Ollama, metadata, and installs)
--   - profiles_manager.lua (Prompt strategies and Editor)
--   - settings_manager.lua (Numeric configs and Dialogs)
--   - app_picker.lua       (Application exclusions)
-- ===========================================================================

local M = {}

local hs       = hs
local llm_mod  = require("modules.llm")

-- Sub-modules import
local Models   = require("ui.menu.menu_llm.models_manager")
local Profiles = require("ui.menu.menu_llm.profiles_manager")
local Settings = require("ui.menu.menu_llm.settings_manager")
local Apps     = require("ui.menu.menu_llm.app_picker")





-- ====================================
-- ====================================
-- ======= 1/ Constants & Utils =======
-- ====================================
-- ====================================

--- Formats a raw modifier string into visual macOS symbols for the menu
--- @param m_str string Modifier string (e.g. "cmd+shift")
--- @return string Formatted symbols
local function format_mod_string(m_str)
	if type(m_str) ~= "string" then return "⌃" end
	local dict = { ctrl="⌃", cmd="⌘", alt="⌥", shift="⇧" }
	local res = ""
	for p in m_str:gmatch("[^+]+") do res = res .. (dict[p] or p) end
	return res == "" and "⌃" or res
end

--- Helper to generate dynamic titles for shortcut menus
--- @param action string The action label (e.g. "Naviguer")
--- @param mods table Array of modifiers
--- @param none_label string Text to display if no modifiers are required
--- @param mod_label string Text to display next to the modifier symbol
--- @return string The combined title
local function format_shortcut_title(action, mods, none_label, mod_label)
	if not mods or (#mods == 1 and mods[1] == "none") then
		return action .. " : Désactivé"
	elseif #mods == 0 then
		return action .. " : " .. none_label
	else
		local sym = format_mod_string(table.concat(mods, "+"))
		return action .. " : " .. sym .. " " .. mod_label
	end
end





-- ==============================
-- ==============================
-- ======= 2/ Factory API =======
-- ==============================
-- ==============================

--- Creates the LLM menu handler
--- @param deps table Global project dependencies (state, keymap, etc.)
--- @return table The build_item and check_startup interface
function M.create(deps)
	if type(deps) ~= "table" then return {} end
	
	-- Initialize specialized managers
	local models_mgr   = Models.new(deps)
	local profiles_mgr = Profiles.new(deps, models_mgr)
	local settings_mgr = Settings.new(deps)
	local apps_mgr     = Apps.new(deps)

	local state        = deps.state
	local keymap       = deps.keymap
	local save_prefs   = deps.save_prefs
	local update_menu  = deps.update_menu
	local update_icon  = deps.update_icon

	if state.llm_num_predictions ~= nil and keymap and type(keymap.set_llm_num_predictions) == "function" then
		pcall(keymap.set_llm_num_predictions, state.llm_num_predictions)
	end
	if state.llm_max_words ~= nil and keymap and type(keymap.set_llm_max_words) == "function" then
		pcall(keymap.set_llm_max_words, state.llm_max_words)
	end



	-- =====================================
	-- ===== 2.1) Model Switcher Logic =====
	-- =====================================

	--- Handles model selection and intelligent profile recommendation prompting
	--- @param new_model string The identifier of the chosen model
	local function switch_model(new_model)
		models_mgr.check_requirements(new_model, function()
			state.llm_model = new_model
			if keymap and type(keymap.set_llm_model) == "function" then
				pcall(keymap.set_llm_model, new_model)
			end

			-- Strategy Recommendation based on model type and size
			local info = models_mgr.get_model_info(new_model)
			local rec_profile = "basic"
			local rec_label   = "●●○○ Basique — Prédiction simple"
			
			local current_preds = state.llm_num_predictions or 1
			local batch_suffix = current_preds > 1 and "s" or ""

			if info.type == "completion" then
				rec_profile = "raw"
				rec_label   = "●○○○ Raw — Aucun prompt, juste le contexte"
			elseif info.params and info.params > 0 then
				if info.params < 2 then
					rec_profile = "raw"
					rec_label   = "●○○○ Raw — Aucun prompt, juste le contexte"
				elseif info.params < 4 then
					rec_profile = "basic"
					rec_label   = "●●○○ Basique — Prédiction simple"
				elseif info.params < 7 then
					rec_profile = "advanced"
					rec_label   = "●●●○ Avancé — Correction + Prédiction"
				else
					rec_profile = "batch_advanced"
					rec_label   = string.format("●●●● Batch Avancé — 1 req. avancée avec %d prédiction%s", current_preds, batch_suffix)
				end
			end

			local cur_profile = state.llm_active_profile or "basic"
			
			-- Auto-migrate legacy profiles to maintain compatibility
			if cur_profile == "parallel" or cur_profile == "parallel_simple" then cur_profile = "basic" end
			if cur_profile == "batch" or cur_profile == "batch_simple" then cur_profile = "batch_advanced" end
			if cur_profile == "parallel_advanced" then cur_profile = "advanced" end
			if cur_profile == "base_completion" then cur_profile = "raw" end

			if cur_profile ~= rec_profile then
				-- Prompt user to accept the recommended profile
				hs.timer.doAfter(0.1, function()
					pcall(hs.focus)
					local msg = string.format("Le modèle '%s' est optimisé pour le profil de prompt :\n\n%s\n\nVoulez-vous basculer sur ce profil ?", new_model, rec_label)
					local ok, choice = pcall(hs.dialog.blockAlert, "Changement de modèle", msg, "Oui (Recommandé)", "Non (Garder l'actuel)", "informational")
					
					if ok and choice == "Oui (Recommandé)" then
						state.llm_active_profile = rec_profile
						llm_mod.set_active_profile(rec_profile)
					else
						state.llm_active_profile = cur_profile
						llm_mod.set_active_profile(cur_profile)
					end
					save_prefs()
					update_menu()
				end)
			else
				state.llm_active_profile = cur_profile
				llm_mod.set_active_profile(cur_profile)
				save_prefs()
				update_menu()
			end
		end)
	end



	-- ====================================
	-- ===== 2.2) Sub-menu Builders =======
	-- ====================================

	--- Constructs the model selection sub-menu mapping presets to options
	--- @return table The list of model menu items
	local function build_models_selection()
		local menu = {}
		local installed = models_mgr.get_installed_models()
		local presets = models_mgr.get_presets()

		for _, group in ipairs(presets) do
			local sub = {}
			for _, m in ipairs(group.models or {}) do
				local m_name = m.name
				
				-- Fetch rich info (emojis, type, params) and RAM from the manager
				local info = models_mgr.get_model_info(m_name)
				local ram = models_mgr.get_model_ram(m_name)
				
				-- Format the different elements for the UI
				local is_inst = installed[m_name] or installed[m_name .. ":latest"]
				local type_str = (info.type == "completion") and " [📝 Complétion]" or " [💬 Chat]"
				local params_str = (info.params and info.params > 0) and (" · " .. info.params) or ""
				local emojis_str = info.emojis or ""

				-- Recreate the exact rich title formatting
				local title = string.format("%s%s%s (~%d Go RAM%sB)%s",
					is_inst and "🟢 " or "  ",
					m_name, type_str, ram, params_str, emojis_str)

				table.insert(sub, {
					title   = title,
					checked = (state.llm_model == m_name),
					fn      = function() switch_model(m_name) end
				})
			end
			table.insert(menu, { title = group.label, menu = sub })
		end
		return menu
	end

	--- Constructs the parallel prediction array sub-menu
	--- @return table The list of prediction array menu items
	local function build_num_pred_menu()
		local m = {}
		for i = 1, 10 do
			table.insert(m, {
				title   = i .. " suggestion" .. (i > 1 and "s" or ""),
				checked = (state.llm_num_predictions == i),
				fn      = function()
					state.llm_num_predictions = i
					if keymap and type(keymap.set_llm_num_predictions) == "function" then
						pcall(keymap.set_llm_num_predictions, i)
					end
					save_prefs(); update_menu()
				end
			})
		end
		return m
	end



	-- ===================================
	-- ===================================
	-- ======= 3/ Main Menu Item =========
	-- ===================================
	-- ===================================

	--- Core builder for the entire Artificial Intelligence menu tree
	--- @return table The root menu item structure
	local function build_item()
		local paused = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false
		local main_menu = {}

		-- --- 1. MODEL & INSTALLATION ---
		local info = models_mgr.get_model_info(state.llm_model)
		local ram = models_mgr.get_model_ram(state.llm_model)
		local type_str = (info.type == "completion") and " [📝 Complétion]" or " [💬 Chat]"
		local params_str = (info.params and info.params > 0) and (" · " .. info.params) or ""
		local emojis_str = info.emojis or ""
		
		local rich_model_title = string.format("Modèle actif : %s%s (~%d Go RAM%sB)%s",
			tostring(state.llm_model), type_str, ram, params_str, emojis_str)
		
		table.insert(main_menu, {
			title    = rich_model_title,
			disabled = paused or nil,
			menu     = build_models_selection()
		})

		if info and info.emojis and info.emojis:find("🧠💭") then
			table.insert(main_menu, { title = "   ↳ Info : Modèle thinking (réflexion masquée)", disabled = true })
		end

		table.insert(main_menu, { title = "-" })

		-- --- 2. PERFORMANCE & STRATEGY ---
		table.insert(main_menu, { title = "— COMPORTEMENT & PERFORMANCES —", disabled = true })

		table.insert(main_menu, { title = "Nombre de suggestions : " .. (state.llm_num_predictions or 1), menu = build_num_pred_menu() })
		if state.llm_num_predictions ~= keymap.LLM_NUM_PREDICTIONS_DEFAULT then
			table.insert(main_menu, {
				title = "   ↳ Réinitialiser (défaut : " .. keymap.LLM_NUM_PREDICTIONS_DEFAULT .. ")",
				fn    = function()
					state.llm_num_predictions = keymap.LLM_NUM_PREDICTIONS_DEFAULT
					if keymap and type(keymap.set_llm_num_predictions) == "function" then pcall(keymap.set_llm_num_predictions, state.llm_num_predictions) end
					save_prefs(); update_menu()
				end
			})
		end
		
		-- --- PROFILES SUBMENU CONSTRUCTION ---
		table.insert(main_menu, profiles_mgr.get_menu_item())
		
		table.insert(main_menu, { title = "Temps d’attente avant suggestion : " .. math.floor(state.llm_debounce * 1000) .. " ms…", fn = settings_mgr.set_debounce })
		if state.llm_debounce ~= keymap.LLM_DEBOUNCE_DEFAULT then
			table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. math.floor(keymap.LLM_DEBOUNCE_DEFAULT * 1000) .. " ms)", fn = settings_mgr.reset_debounce })
		end

		table.insert(main_menu, { title = "Tokens max générés : " .. state.llm_max_predict, fn = settings_mgr.set_max_predict })
		if state.llm_max_predict ~= keymap.LLM_MAX_PREDICT_DEFAULT then
			table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. keymap.LLM_MAX_PREDICT_DEFAULT .. ")", fn = settings_mgr.reset_max_predict })
		end
		
		local max_words_display = (state.llm_max_words and state.llm_max_words > 0) and state.llm_max_words or "Illimité"
		table.insert(main_menu, { title = "Mots max par suggestion : " .. max_words_display, fn = settings_mgr.set_max_words })
		if state.llm_max_words ~= keymap.LLM_MAX_WORDS_DEFAULT then
			local def_w_disp = keymap.LLM_MAX_WORDS_DEFAULT > 0 and keymap.LLM_MAX_WORDS_DEFAULT or "Illimité"
			table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. def_w_disp .. ")", fn = settings_mgr.reset_max_words })
		end
		
		table.insert(main_menu, { title = "Température (Créativité) : " .. state.llm_temperature, fn = settings_mgr.set_temperature })
		if state.llm_temperature ~= keymap.LLM_TEMPERATURE_DEFAULT then
			table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. keymap.LLM_TEMPERATURE_DEFAULT .. ")", fn = settings_mgr.reset_temperature })
		end

		table.insert(main_menu, { title = "-" })

		-- --- 3. CONTEXT & EXCLUSIONS ---
		table.insert(main_menu, { title = "— CONTEXTE & EXCLUSIONS —", disabled = true })

		table.insert(main_menu, { title = "Taille du contexte : " .. state.llm_context_length .. " derniers caractères", fn = settings_mgr.set_context_length })
		if state.llm_context_length ~= keymap.LLM_CONTEXT_LENGTH_DEFAULT then
			table.insert(main_menu, { title = "   ↳ Réinitialiser (défaut : " .. keymap.LLM_CONTEXT_LENGTH_DEFAULT .. ")", fn = settings_mgr.reset_context_length })
		end
		
		table.insert(main_menu, {
			title   = "Vider le contexte sur clic/navigation",
			checked = state.llm_reset_on_nav,
			fn      = function()
				state.llm_reset_on_nav = not state.llm_reset_on_nav
				if keymap and type(keymap.set_llm_reset_on_nav) == "function" then pcall(keymap.set_llm_reset_on_nav, state.llm_reset_on_nav) end
				save_prefs(); update_menu()
			end
		})

		table.insert(main_menu, apps_mgr.get_menu_item())

		table.insert(main_menu, { title = "-" })

		-- --- 4. INTERFACE & SHORTCUTS ---
		table.insert(main_menu, { title = "— INTERFACE & RACCOURCIS —", disabled = true })

		table.insert(main_menu, {
			title   = "Afficher la barre d’info (modèle et latence)",
			checked = state.llm_show_info_bar,
			fn      = function()
				state.llm_show_info_bar = not state.llm_show_info_bar
				if keymap and type(keymap.set_llm_show_info_bar) == "function" then pcall(keymap.set_llm_show_info_bar, state.llm_show_info_bar) end
				save_prefs(); update_menu()
			end
		})

		-- Retrieve configurations and synchronize them with keymap.lua
		local nav_mods = hs.settings.get("llm_nav_modifiers")
		if nav_mods == nil then nav_mods = keymap and keymap.llm_nav_modifiers_default or {} end
		if keymap and type(keymap.set_llm_nav_modifiers) == "function" then pcall(keymap.set_llm_nav_modifiers, nav_mods) end
		
		local val_mods = hs.settings.get("llm_val_modifiers")
		if val_mods == nil then val_mods = keymap and keymap.llm_val_modifiers_default or {"alt"} end
		if keymap and type(keymap.set_llm_val_modifiers) == "function" then pcall(keymap.set_llm_val_modifiers, val_mods) end

		-- Formatting dynamic titles
		local num_preds_safe = state.llm_num_predictions or 1
		local nav_title = ""
		if num_preds_safe < 2 then
			nav_title = "Modificateur navigation (↑/← et ↓/→) : Désactivé (1 suggestion)"
		else
			nav_title = format_shortcut_title("Naviguer dans les suggestions (↑/← et ↓/→)", nav_mods, "Flèches seules", "Flèches")
		end

		table.insert(main_menu, {
			title    = nav_title,
			disabled = (num_preds_safe < 2),
			menu     = settings_mgr.build_nav_modifier_menu()
		})

		local val_title = ""
		if num_preds_safe < 2 then
			val_title = "Modificateur sélection (chiffres) : Désactivé (1 suggestion)"
		else
			local range_str = (num_preds_safe == 10) and "1-0" or ("1-" .. num_preds_safe)
			val_title = format_shortcut_title("Sélectionner la suggestion n° (" .. range_str .. ")", val_mods, "Chiffres seuls", "Chiffres")
		end

		table.insert(main_menu, {
			title    = val_title,
			disabled = (num_preds_safe < 2),
			menu     = settings_mgr.build_val_modifier_menu()
		})

		table.insert(main_menu, { title = "Indentation de la suggestion sélectionnée", menu = settings_mgr.build_indent_menu() })

		return {
			title   = "Intelligence Artificielle",
			checked = (state.llm_enabled and not paused) or nil,
			fn      = not paused and function()
				local function toggle_state()
					state.llm_enabled = not state.llm_enabled
					if keymap and type(keymap.set_llm_enabled) == "function" then pcall(keymap.set_llm_enabled, state.llm_enabled) end
					save_prefs(); update_menu()
					pcall(function() hs.notify.new({title = state.llm_enabled and "🟢 ACTIVÉ" or "🔴 DÉSACTIVÉ", informativeText = "Suggestions IA"}):send() end)
				end

				if not state.llm_enabled then
					-- Turning ON: Check if the model is downloaded first (triggers RAM/Disk dialog if needed)
					models_mgr.check_requirements(state.llm_model, toggle_state, nil)
				else
					-- Turning OFF: Just disable it
					toggle_state()
				end
			end or nil,
			menu    = main_menu
		}
	end

	--- Startup check logic to ensure Ollama is available if LLM is enabled
	local function check_startup()
		if not state.llm_enabled then return end
		
		local function disable_llm()
			state.llm_enabled = false
			if keymap and type(keymap.set_llm_enabled) == "function" then pcall(keymap.set_llm_enabled, false) end
			save_prefs(); update_menu()
		end

		-- Verify model. Prompts with RAM/Disk UI if missing.
		models_mgr.check_requirements(state.llm_model, function() 
			-- Model is ready, nothing to do.
		end, disable_llm)
	end

	return { 
		build_item    = build_item, 
		check_startup = check_startup 
	}
end

return M
