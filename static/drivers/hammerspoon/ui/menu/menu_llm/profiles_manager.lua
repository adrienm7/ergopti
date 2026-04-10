--- ui/menu/menu_llm/profiles_manager.lua

--- ==============================================================================
--- MODULE: LLM Profiles Manager
--- DESCRIPTION:
--- Logic for handling prompt strategies. Manages built-in and user-defined 
--- profiles, handles compatibility warnings for reasoning models, and 
--- integrates with the Prompt Editor UI for CRUD operations.
--- ==============================================================================

local M = {}

local hs            = hs
local notifications = require("lib.notifications")
local llm_mod       = require("modules.llm")
local shortcut_ui   = require("ui.menu.shortcut_utils")
local Logger        = require("lib.logger")

local LOG = "menu_llm.profiles"

local ok_pe, prompt_editor = pcall(require, "ui.prompt_editor")
if not ok_pe then prompt_editor = nil end





-- ================================
-- ================================
-- ======= 1/ Profile Logic =======
-- ================================
-- ================================

--- Formats a profile label dynamically replacing placeholders.
--- @param label string The raw label containing placeholders.
--- @param num_preds number The number of predictions currently configured.
--- @return string The formatted label ready for UI display.
local function format_dynamic_label(label, num_preds)
	if type(label) ~= "string" then return "" end
	local n = tonumber(num_preds) or 1
	local s = (n > 1) and "s" or ""
	return label:gsub("{n}", tostring(n)):gsub("{s}", s)
end

--- Synchronizes the internal state of the LLM module with current preferences.
--- @param state table Shared menu state.
local function sync_profiles(state)
	if type(state) ~= "table" then return end
	llm_mod.set_active_profile(state.llm_active_profile or "basic")
	llm_mod.user_profiles = type(state.llm_user_profiles) == "table" and state.llm_user_profiles or {}
end

--- Aggregates built-in and user-created profiles into a single list.
--- @param state table Shared menu state.
--- @return table List of all profile definitions.
local function get_all_profiles(state)
	local all = {}
	for _, p in ipairs(llm_mod.BUILTIN_PROFILES or {}) do table.insert(all, p) end
	local user_p = (type(state) == "table" and type(state.llm_user_profiles) == "table") and state.llm_user_profiles or {}
	for _, p in ipairs(user_p) do table.insert(all, p) end
	return all
end

--- Retrieves the human-readable label of the currently selected strategy.
--- @param state table Shared menu state.
--- @return string The display label dynamically formatted.
local function active_profile_label(state)
	local id = type(state) == "table" and state.llm_active_profile or "basic"
	local all = get_all_profiles(state)
	for _, p in ipairs(all) do
		if type(p) == "table" and p.id == id then 
			return format_dynamic_label(p.label, state.llm_num_predictions) 
		end
	end
	return tostring(id)
end





-- ====================================
-- ====================================
-- ======= 2/ Menu Construction =======
-- ====================================
-- ====================================

--- Builds the strategy selection submenu with support for custom profiles.
--- @param deps table Global dependencies.
--- @param models_mgr table Manager reference to handle auto-detection heuristics.
--- @return table The Hammerspoon menu structure.
local function build_profile_menu(deps, models_mgr)
	local state  = deps.state
	local paused = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false
	local menu   = {}

	-- Auto-detect recommendation logic
	table.insert(menu, {
		title    = "✨ Détection automatique du meilleur profil",
		disabled = paused or nil,
		fn       = not paused and function()
			if type(deps.apply_recommended_prompt_profile) == "function" then
				deps.apply_recommended_prompt_profile({ dialog_title = "Profil recommandé", force_dialog = true })
				return
			end

			local model_name = state.llm_model
			if type(model_name) ~= "string" or model_name == "" or not models_mgr then return end

			if info.type == "completion" then
				rec_profile = "raw"
			elseif info.params and info.params > 0 then
				if info.params < 2 then rec_profile = "raw"
				elseif info.params < 4 then rec_profile = "basic"
				elseif info.params < 7 then rec_profile = "advanced"
				else rec_profile = "batch_advanced" end
			end
			
			Logger.info(LOG, string.format("Auto-detecting profile %s for model %s.", rec_profile, model_name))
			state.llm_active_profile = rec_profile
			llm_mod.set_active_profile(rec_profile)
			sync_profiles(state)
			pcall(deps.save_prefs)
			pcall(deps.update_menu)
			pcall(notifications.notify, "✨ Profil auto-détecté", "Le profil optimal a été sélectionné pour " .. model_name)
		end or nil,
	})
	table.insert(menu, { title = "-" })

	-- Native profiles section
	table.insert(menu, { title = "— PROFILS PAR DÉFAUT —", disabled = true })
	for _, profile in ipairs(llm_mod.BUILTIN_PROFILES or {}) do
		local pid = profile.id
		
		local info = models_mgr and models_mgr.get_model_info(state.llm_model) or {}
		local is_thinking = info.emojis and info.emojis:find("🧠💭")
		
		local extra = ""
		if (pid == "basic" or pid == "advanced") and is_thinking then
			extra = "  ⚠️ Non recommandé (Thinking)"
		end

		local display_label = format_dynamic_label(profile.label, state.llm_num_predictions)

		table.insert(menu, {
			title    = display_label .. (profile.description and ("  —  " .. profile.description) or "") .. extra,
			checked  = (state.llm_active_profile == pid) or nil,
			disabled = paused or nil,
			fn       = not paused and function()
				if type(deps.set_llm_profile) == "function" then
					deps.set_llm_profile(pid)
				else
					state.llm_active_profile = pid
					llm_mod.set_active_profile(pid)
					sync_profiles(state)
					pcall(deps.save_prefs)
					pcall(deps.update_menu)
				end
			end or nil,
		})
	end

	-- Custom profiles section
	local user_profiles = state.llm_user_profiles or {}
	if type(user_profiles) == "table" and #user_profiles > 0 then
		table.insert(menu, { title = "-" })
		table.insert(menu, { title = "— PROFILS PERSONNALISÉS —", disabled = true })
		for i, profile in ipairs(user_profiles) do
			local pid = profile.id
			local display_label = format_dynamic_label(profile.label or ("Profil personnalisé " .. i), state.llm_num_predictions)
			local profile_shortcut = type(state.llm_profile_shortcuts) == "table" and state.llm_profile_shortcuts[pid] or nil
			local item = {
				title    = display_label,
				checked  = (state.llm_active_profile == pid) or nil,
				disabled = paused or nil,
			}
			
			-- User profiles get a sub-menu for Editing/Deleting
			item.menu = {
				{
					title    = "Utiliser ce profil",
					checked  = (state.llm_active_profile == pid) or nil,
					disabled = paused or nil,
					fn       = not paused and function()
						if type(deps.set_llm_profile) == "function" then
							deps.set_llm_profile(pid)
						else
							state.llm_active_profile = pid
							llm_mod.set_active_profile(pid)
							sync_profiles(state)
							pcall(deps.save_prefs)
							pcall(deps.update_menu)
						end
					end or nil,
				},
				{
					title    = "Raccourci : " .. shortcut_ui.shortcut_to_label(profile_shortcut, "Aucun"),
					disabled = paused or nil,
					fn       = not paused and function()
						shortcut_ui.prompt_shortcut({
							title = "Raccourci du profil",
							message = "Format : mods+touche  (ex : cmd+shift+b)\nMods disponibles : cmd, alt, ctrl, shift\nLaisser vide pour désactiver",
							current_shortcut = type(state.llm_profile_shortcuts) == "table" and state.llm_profile_shortcuts[pid] or nil,
							default_mods = {"ctrl"},
							on_apply = function(mods, key)
								if type(deps.apply_llm_profile_shortcut) == "function" then
									deps.apply_llm_profile_shortcut(pid, mods, key)
								end
							end,
						})
					end or nil,
				},
				{ title = "-" },
				{
					title = "✏️ Modifier…",
					fn    = function()
						if prompt_editor and type(prompt_editor.open) == "function" then
							hs.timer.doAfter(0.1, function()
								pcall(prompt_editor.open, profile, function(updated)
									if type(updated) == "table" then
										for j, p in ipairs(state.llm_user_profiles) do
											if type(p) == "table" and p.id == updated.id then
												state.llm_user_profiles[j] = updated
												break
											end
										end
										sync_profiles(state)
										pcall(deps.save_prefs)
										pcall(deps.update_menu)
										pcall(notifications.notify, "✅ Profil modifié", format_dynamic_label(updated.label, state.llm_num_predictions))
									end
								end)
							end)
						end
					end,
				},
				{
					title = "🗑️ Supprimer…",
					fn    = function()
						pcall(hs.focus)
						local ok_c, choice = pcall(hs.dialog.blockAlert, 
							"Supprimer « " .. display_label .. " » ?", 
							"Ce profil personnalisé sera supprimé définitivement.", 
							"Supprimer", "Annuler", "critical")
							
						if ok_c and choice == "Supprimer" then
							if type(deps.apply_llm_profile_shortcut) == "function" then
								deps.apply_llm_profile_shortcut(pid, nil, nil, { silent = true })
							end
							local kept = {}
							for _, p in ipairs(state.llm_user_profiles) do
								if type(p) == "table" and p.id ~= pid then table.insert(kept, p) end
							end
							state.llm_user_profiles = kept
							if state.llm_active_profile == pid then 
								state.llm_active_profile = "basic"
								llm_mod.set_active_profile("basic")
							end
							sync_profiles(state)
							pcall(deps.save_prefs)
							pcall(deps.update_menu)
							Logger.info(LOG, string.format("Custom profile %s deleted.", pid))
						end
					end,
				},
			}
			table.insert(menu, item)
		end
	end

	table.insert(menu, { title = "-" })
	table.insert(menu, {
		title = "Créer un profil personnalisé…",
		fn    = not paused and function()
			if prompt_editor and type(prompt_editor.open) == "function" then
				hs.timer.doAfter(0.1, function()
					pcall(prompt_editor.open, nil, function(new_profile)
						if type(new_profile) == "table" then
							if type(state.llm_user_profiles) ~= "table" then state.llm_user_profiles = {} end
							table.insert(state.llm_user_profiles, new_profile)
							state.llm_active_profile = new_profile.id
							llm_mod.set_active_profile(new_profile.id)
							sync_profiles(state)
							pcall(deps.save_prefs)
							pcall(deps.update_menu)
							pcall(notifications.notify, "✅ Profil créé", format_dynamic_label(new_profile.label, state.llm_num_predictions))
							Logger.info(LOG, string.format("Custom profile %s created.", new_profile.id))
						end
					end)
				end)
			end
		end or nil,
	})
	
	return menu
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Instantiates the profiles manager.
--- @param deps table Global dependencies.
--- @param models_mgr table Manager reference to handle auto-detection heuristics.
--- @return table The profiles manager instance.
function M.new(deps, models_mgr)
	local obj = { deps = deps }
	sync_profiles(deps.state)

	--- Returns the main menu entry for Strategy selection.
	function obj.get_menu_item()
		local label = active_profile_label(deps.state)
		
		local info = models_mgr and models_mgr.get_model_info(deps.state.llm_model) or {}
		local is_thinking = info.emojis and info.emojis:find("🧠💭")
		local warning = (is_thinking and (deps.state.llm_active_profile == "basic" or deps.state.llm_active_profile == "advanced")) and "  ⚠️" or ""

		return {
			title = "Profil : " .. label .. warning,
			menu  = build_profile_menu(deps, models_mgr)
		}
	end

	return obj
end

return M
