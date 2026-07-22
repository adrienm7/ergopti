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
local i18n          = require("lib.i18n")
local dialog        = require("lib.dialog_util")
local ProfileLabel  = require("ui.menu.menu_llm.profile_label")

local LOG = "menu_llm.profiles"

local ok_pe, prompt_editor = pcall(require, "ui.prompt_editor")
if not ok_pe then prompt_editor = nil end

-- Monotone counter to make profile ids unique even when two clones are
-- created within the same second (os.time() resolution = 1s).
local _profile_seq = 0





-- ================================
-- ================================
-- ======= 1/ Profile Logic =======
-- ================================
-- ================================

--- Synchronizes the internal state of the LLM module with current preferences.
--- @param state table Shared menu state.
local function sync_profiles(state)
	if type(state) ~= "table" then return end
	llm_mod.set_active_profile(state.llm_active_profile or "basic")
	llm_mod.user_profiles = type(state.llm_user_profiles) == "table" and state.llm_user_profiles or {}
end

--- Activates a profile by id: prefers the injected deps.set_llm_profile path,
--- otherwise mutates state, syncs the engine, persists and rebuilds the menu.
--- Single source of truth for "select this profile" so the built-in rows
--- (single click) and the user-profile submenu share identical behaviour.
--- @param deps table Global dependencies.
--- @param state table Shared menu state.
--- @param pid string Profile id to activate.
local function select_profile(deps, state, pid)
	if type(deps.set_llm_profile) == "function" then
		deps.set_llm_profile(pid)
		return
	end
	state.llm_active_profile = pid
	llm_mod.set_active_profile(pid)
	sync_profiles(state)
	pcall(deps.save_prefs)
	pcall(deps.update_menu)
end

--- Clones a built-in profile into an editable user profile and opens the editor.
--- The built-in profiles in profiles.json ship with the driver and are read-only
--- by design (any local edit would be overwritten on the next update), so cloning
--- into a user profile is the supported way to customise their prompt. Mirrors the
--- AHK twin's LLM_Menu_CloneActiveBuiltinProfile helper.
--- @param deps table Global dependencies.
--- @param state table Shared menu state.
--- @param src table The built-in profile to clone.
local function clone_builtin_profile(deps, state, src)
	if type(src) ~= "table" then return end
	-- Unique id: seq suffix prevents collision when two profiles are cloned
	-- within the same second (os.time() resolution = 1s).
	_profile_seq = _profile_seq + 1
	local copy = {
		id                    = "user_" .. (src.id or "profile") .. "_" .. tostring(os.time()) .. "_" .. _profile_seq,
		label                 = (src.label or src.id) .. " " .. i18n.get("menu.profiles.copy_suffix"),
		system_single         = src.system_single or "",
		system_multi          = src.system_multi or "",
		system_multi_template = src.system_multi_template or "",
		batch                 = src.batch == true,
	}
	state.llm_user_profiles = state.llm_user_profiles or {}
	table.insert(state.llm_user_profiles, copy)
	state.llm_active_profile = copy.id
	sync_profiles(state)
	pcall(deps.save_prefs)
	pcall(deps.update_menu)
	-- Open the edit dialog immediately so the user lands in the prompt they can
	-- edit, not back in the menu.
	if prompt_editor and type(prompt_editor.open) == "function" then
		hs.timer.doAfter(0.1, function()
			pcall(prompt_editor.open, copy, function(updated)
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
				end
			end)
		end)
	end
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
			return ProfileLabel.format(p.label, state.llm_num_predictions) 
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
		title    = i18n.get("menu.profiles.auto_detect"),
		disabled = paused or nil,
		fn       = not paused and function()
			if type(deps.apply_recommended_prompt_profile) == "function" then
				deps.apply_recommended_prompt_profile({ dialog_title = i18n.get("menu.profiles.recommended_profile"), force_dialog = true })
				return
			end

			local model_name = state.llm_model
			if type(model_name) ~= "string" or model_name == "" or not models_mgr then return end

			pcall(notifications.notify, i18n.get("menu.profiles.recommended_unavailable_title"), i18n.get("menu.profiles.recommended_unavailable_body"), "warning")
		end or nil,
	})
	table.insert(menu, { title = "-" })

	-- Native profiles section
	table.insert(menu, { title = i18n.section("menu.profiles.header_default_profiles"), disabled = true })
	for _, profile in ipairs(llm_mod.BUILTIN_PROFILES or {}) do
		local pid = profile.id
		
		local info = models_mgr and models_mgr.get_model_info(state.llm_model) or {}
		local is_thinking = info.emojis and info.emojis:find("🧠💭")
		
		local extra = ""
		if (pid == "basic" or pid == "advanced") and is_thinking then
			extra = i18n.get("menu.profiles.not_recommended")
		end

		local display_label = ProfileLabel.format(profile.label, state.llm_num_predictions)

		-- A single click selects the profile directly — no nested "use this
		-- profile" sub-item. Mirrors the AHK tray where clicking a built-in row
		-- activates it (ui/menu/menu_llm/menu_profiles.ahk). Customising a built-in is
		-- still reachable via the "Clone active profile…" entry further down.
		table.insert(menu, {
			title    = display_label .. (profile.description and ("  —  " .. profile.description) or "") .. extra,
			checked  = (state.llm_active_profile == pid) or nil,
			disabled = paused or nil,
			fn       = not paused and function() select_profile(deps, state, pid) end or nil,
		})
	end

	-- Custom profiles section
	local user_profiles = state.llm_user_profiles or {}
	if type(user_profiles) == "table" and #user_profiles > 0 then
		table.insert(menu, { title = "-" })
		table.insert(menu, { title = i18n.section("menu.profiles.header_custom_profiles"), disabled = true })
		for i, profile in ipairs(user_profiles) do
			local pid = profile.id
			local display_label = ProfileLabel.format(profile.label or (i18n.get("menu.profiles.custom_profile_label") .. " " .. i), state.llm_num_predictions)
			local profile_shortcut = type(state.llm_profile_shortcuts) == "table" and state.llm_profile_shortcuts[pid] or nil
			local item = {
				title    = display_label,
				checked  = (state.llm_active_profile == pid) or nil,
				disabled = paused or nil,
			}
			
			-- User profiles get a sub-menu for Editing/Deleting
			item.menu = {
				{
					title    = i18n.get("menu.profiles.use_profile"),
					checked  = (state.llm_active_profile == pid) or nil,
					disabled = paused or nil,
					fn       = not paused and function() select_profile(deps, state, pid) end or nil,
				},
				{
					title    = i18n.get("menu.profiles.shortcut_prefix"),
					disabled = paused or nil,
					fn       = not paused and function()
						shortcut_ui.prompt_shortcut({
							title = i18n.get("menu.profiles.shortcut_title"),
							message = i18n.get("menu.profiles.shortcut_prompt"),
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
					title    = i18n.get("menu.profiles.edit_profile"),
					disabled = paused or nil,
					fn       = not paused and function()
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
										pcall(notifications.notify, i18n.get("profiles.updated_title"), ProfileLabel.format(updated.label, state.llm_num_predictions), "success")
									end
								end)
							end)
						end
					end or nil,
				},
				{
					title    = i18n.get("menu.profiles.delete_profile"),
					disabled = paused or nil,
					fn       = not paused and function()
						local ok_c, choice = pcall(dialog.block_alert,
							string.format(i18n.get("menu.profiles.delete_confirm_title"), display_label),
							i18n.get("menu.profiles.delete_confirm_body"),
							i18n.get("button.delete"), i18n.get("common.cancel"), "critical")

						if ok_c and choice == i18n.get("button.delete") then
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
						end
					end or nil,
				},
			}
			table.insert(menu, item)
		end
	end

	-- "Clone active profile…" — built-ins ship with the driver and are read-only,
	-- so cloning the active one into an editable user profile is the supported way
	-- to customise its prompt. Only shown when the active profile is a built-in
	-- (user profiles already expose Edit in their own submenu). Replaces the former
	-- per-row "Clone & edit" sub-item that the single-click selection removed, and
	-- mirrors the AHK tray's single clone entry (LLM_Menu_CloneActiveBuiltinProfile).
	local active_builtin = nil
	for _, p in ipairs(llm_mod.BUILTIN_PROFILES or {}) do
		if type(p) == "table" and p.id == state.llm_active_profile then
			active_builtin = p
			break
		end
	end
	if active_builtin and not paused then
		table.insert(menu, { title = "-" })
		table.insert(menu, {
			title = i18n.get("menu.profiles.clone_builtin"),
			fn    = function() clone_builtin_profile(deps, state, active_builtin) end,
		})
	end

	table.insert(menu, { title = "-" })
	table.insert(menu, {
		title = i18n.get("menu.profiles.create_profile"),
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
							pcall(notifications.notify, i18n.get("profiles.created_title"), ProfileLabel.format(new_profile.label, state.llm_num_predictions), "success")
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
			title = string.format(i18n.get("menu.profiles.profile_label_prefix"), label) .. warning,
			menu  = build_profile_menu(deps, models_mgr)
		}
	end

	return obj
end

return M
