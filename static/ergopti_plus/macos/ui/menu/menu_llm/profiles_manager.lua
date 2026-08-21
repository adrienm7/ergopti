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
local notifications = require("infra.notifications")
local llm_mod       = require("modules.llm")
local shortcut_ui   = require("ui.menu.shortcut_utils")
local Logger        = require("infra.logger")
local i18n          = require("infra.i18n")
local dialog        = require("infra.dialog_util")
local ProfileLabel  = require("ui.menu.menu_llm.profile_label")
local ManifestMenu  = require("infra.manifest_menu")

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
--- @return boolean settled
local function sync_profiles(state)
	if type(state) ~= "table" then return false end
	local profiles = type(state.llm_user_profiles) == "table" and state.llm_user_profiles or {}
	local profiles_ok, profiles_result = xpcall(
		llm_mod.set_user_profiles,
		debug.traceback,
		profiles
	)
	if not profiles_ok or profiles_result ~= true then
		Logger.error(LOG, "User-profile runtime synchronization refused: %s.",
			tostring(profiles_result))
		return false
	end
	state.llm_user_profiles = profiles
	local active_ok, active_result = xpcall(
		llm_mod.set_active_profile,
		debug.traceback,
		state.llm_active_profile or "basic"
	)
	if not active_ok or active_result == false then
		Logger.error(LOG, "Active-profile runtime synchronization refused: %s.",
			tostring(active_result))
		return false
	end
	return true
end

--- Settles a retained Delete rollback before a sibling profile mutation.
--- @param deps table Global dependencies.
--- @return boolean settled
local function settle_profile_delete_recovery(deps)
	local callback = type(deps) == "table" and deps.settle_profile_delete_recovery or nil
	if callback == nil then return true end
	if type(callback) ~= "function" then
		Logger.error(LOG, "Profile mutation refused because its Delete recovery gate is invalid.")
		return false
	end
	local ok, result = xpcall(callback, debug.traceback)
	if not ok or result ~= true then
		Logger.error(LOG, "Profile mutation refused while Delete rollback remains unsettled: %s.",
			tostring(result))
		return false
	end
	return true
end

--- Settles retained ModelSwitcher compensation before direct profile CRUD that
--- bypasses its setter. This callback must not point back through ProfilesManager.
--- @param deps table Global dependencies.
--- @return boolean settled
local function settle_profile_switcher_recovery(deps)
	local callback = type(deps) == "table" and deps.settle_llm_switcher_recovery or nil
	if callback == nil then return true end
	if type(callback) ~= "function" then
		Logger.error(LOG, "Profile mutation refused because its switcher recovery gate is invalid.")
		return false
	end
	local ok, result = xpcall(callback, debug.traceback)
	if not ok or result ~= true then
		Logger.error(LOG, "Profile mutation refused while switcher rollback remains unsettled: %s.",
			tostring(result))
		return false
	end
	return true
end

--- Settles every owner that may still reference the profile registry.
--- @param deps table Global dependencies.
--- @param opts table|nil Optional internal skip controls.
--- @return boolean settled
local function settle_profile_mutation_recovery(deps, opts)
	opts = type(opts) == "table" and opts or {}
	if opts.skip_delete_recovery ~= true
		and not settle_profile_delete_recovery(deps) then
		return false
	end
	return settle_profile_switcher_recovery(deps)
end

--- Activates a profile by id: prefers the injected deps.set_llm_profile path,
--- otherwise mutates state, syncs the engine, persists and rebuilds the menu.
--- Single source of truth for "select this profile" so the built-in rows
--- (single click) and the user-profile submenu share identical behaviour.
--- @param deps table Global dependencies.
--- @param state table Shared menu state.
--- @param pid string Profile id to activate.
--- @param opts table|nil Optional parent-transaction controls.
--- @return boolean committed
--- @return table|nil intent_lease Deferred intent lease from the real owner.
local function select_profile(deps, state, pid, opts)
	opts = type(opts) == "table" and opts or {}
	if not settle_profile_mutation_recovery(deps, opts) then
		return false
	end
	if type(deps.set_llm_profile) == "function" then
		local ok, result, intent_lease = xpcall(
			deps.set_llm_profile,
			debug.traceback,
			pid,
			opts
		)
		if not ok or result ~= true then
			Logger.error(LOG, "Profile selection refused for '%s': %s.", pid, tostring(result))
			return false
		end
		return true, intent_lease
	end
	state.llm_active_profile = pid
	if sync_profiles(state) ~= true then return false end
	if opts.persist ~= false then
		local save_ok, save_result = xpcall(deps.save_prefs, debug.traceback)
		if not save_ok or save_result ~= true then return false end
	end
	if opts.update_menu == false then return true, nil end
	local menu_ok, menu_result = xpcall(deps.update_menu, debug.traceback)
	return menu_ok and menu_result ~= false, nil
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
	if not settle_profile_mutation_recovery(deps) then return false end
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
	if select_profile(deps, state, copy.id) ~= true then return false end
	-- Open the edit dialog immediately so the user lands in the prompt they can
	-- edit, not back in the menu.
	if prompt_editor and type(prompt_editor.open) == "function" then
		hs.timer.doAfter(0.1, function()
			pcall(prompt_editor.open, copy, function(updated)
				if type(updated) == "table" then
					if not settle_profile_mutation_recovery(deps) then return false end
					for j, p in ipairs(state.llm_user_profiles) do
						if type(p) == "table" and p.id == updated.id then
							state.llm_user_profiles[j] = updated
							break
						end
					end
					sync_profiles(state)
					if deps.save_prefs() ~= true then return false end
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

--- Invokes one required profile-deletion boundary with exact settlement.
--- @param label string Boundary label.
--- @param callback function|nil Boundary callback.
--- @param ... any Arguments forwarded to callback.
--- @return boolean settled
local function invoke_delete_boundary(label, callback, ...)
	if type(callback) ~= "function" then
		Logger.error(LOG, "%s refused because its callback is unavailable.", label)
		return false
	end
	local ok, result = xpcall(callback, debug.traceback, ...)
	if not ok or result ~= true then
		Logger.error(LOG, "%s refused: %s.", label, tostring(result))
		return false
	end
	return true
end

--- Creates the exact multi-owner transaction used by confirmed profile Delete.
--- @param deps table Global dependencies.
--- @return function delete_profile Transaction callback.
local function make_profile_deleter(deps)
	local state = deps.state
	local recovery_debt = nil

	--- Restores a rejected deletion while the shortcut lease fences re-entrant
	--- preference rollback callbacks.
	--- @param debt table Mutable deletion ledger.
	--- @return boolean settled
	local function restore_deletion(debt)
		local failures = {}
		if debt.intent_pending then
			if invoke_delete_boundary("Profile deletion intent cancellation",
				debt.intent_lease and debt.intent_lease.cancel) then
				debt.intent_pending = false
			else
				failures[#failures + 1] = "profile intent"
			end
		end
		state.llm_user_profiles = debt.old_profiles
		if debt.registry_touched then
			if not invoke_delete_boundary("Profile registry runtime rollback",
				llm_mod.set_user_profiles, debt.old_profiles) then
				failures[#failures + 1] = "runtime registry"
			end
		end

		if not invoke_delete_boundary("Profile shortcut native rollback",
			debt.shortcut_lease.restore) then
			failures[#failures + 1] = "shortcut owner"
		end

		if debt.active_published and not select_profile(deps, state, debt.old_active, {
			persist = false,
			update_menu = false,
			record_intent = false,
			skip_delete_recovery = true,
		}) then
			failures[#failures + 1] = "active profile"
		end
		state.llm_active_profile = debt.old_active

		if debt.persistence_touched
			and not invoke_delete_boundary("Profile deletion preference rollback", deps.save_prefs) then
			failures[#failures + 1] = "preferences"
		end

		-- A failed outer preference rollback may restore the last committed deletion
		-- snapshot. Reassert every live boundary while the shortcut fence is held
		state.llm_user_profiles = debt.old_profiles
		if debt.registry_touched then
			if not invoke_delete_boundary("Profile registry rollback reassertion",
				llm_mod.set_user_profiles, debt.old_profiles) then
				failures[#failures + 1] = "runtime registry reassertion"
			end
		end
		if not invoke_delete_boundary("Profile shortcut rollback reassertion",
			debt.shortcut_lease.restore) then
			failures[#failures + 1] = "shortcut reassertion"
		end
		if debt.active_published and not select_profile(deps, state, debt.old_active, {
			persist = false,
			update_menu = false,
			record_intent = false,
			skip_delete_recovery = true,
		}) then
			failures[#failures + 1] = "active profile reassertion"
		end
		state.llm_active_profile = debt.old_active

		if debt.menu_touched then
			local menu_ok, menu_result = xpcall(deps.update_menu, debug.traceback)
			if not menu_ok or menu_result == false then
				failures[#failures + 1] = "menu"
			end
		end

		if #failures == 0 and invoke_delete_boundary(
			"Profile shortcut rollback fence release",
			debt.shortcut_lease.finish_rollback) then
			recovery_debt = nil
			return true
		end
		if #failures == 0 then failures[#failures + 1] = "shortcut fence" end
		recovery_debt = debt
		Logger.error(LOG, "Profile deletion rollback remains pending at: %s.",
			table.concat(failures, ", "))
		return false
	end

	--- Retries retained deletion compensation before another destructive action.
	--- @return boolean settled
	local function settle_recovery()
		if not recovery_debt then return true end
		Logger.warn(LOG, "Retrying retained profile deletion rollback.")
		return restore_deletion(recovery_debt)
	end

	--- Deletes one user profile only after every parent boundary commits.
	--- @param profile_id string User profile id.
	--- @return boolean committed
	local function delete_profile(profile_id)
		if not settle_recovery() then return false end
		if not settle_profile_switcher_recovery(deps) then return false end
		if type(profile_id) ~= "string" or profile_id == "" then return false end
		if type(state.llm_user_profiles) ~= "table" then return false end

		local old_profiles = state.llm_user_profiles
		local kept = {}
		local found = false
		for _, profile in ipairs(old_profiles) do
			if type(profile) == "table" and profile.id == profile_id then
				found = true
			else
				kept[#kept + 1] = profile
			end
		end
		if not found then return false end

		local lease_ok, shortcut_lease = xpcall(
			deps.apply_llm_profile_shortcut,
			debug.traceback,
			profile_id,
			nil,
			nil,
			{defer = true}
		)
		if not lease_ok or type(shortcut_lease) ~= "table"
			or type(shortcut_lease.publish) ~= "function"
			or type(shortcut_lease.commit) ~= "function"
			or type(shortcut_lease.restore) ~= "function"
			or type(shortcut_lease.finish_rollback) ~= "function" then
			Logger.error(LOG, "Profile deletion could not acquire the exact shortcut lease: %s.",
				tostring(shortcut_lease))
			return false
		end

		local debt = {
			active_changed = state.llm_active_profile == profile_id,
			active_published = false,
			intent_lease = nil,
			intent_pending = false,
			menu_touched = false,
			old_active = state.llm_active_profile,
			old_profiles = old_profiles,
			persistence_touched = false,
			registry_touched = false,
			shortcut_lease = shortcut_lease,
		}
		--- Rejects the candidate deletion and runs every acquired compensation.
		--- @param boundary string Boundary that refused.
		--- @return boolean committed Always false.
		local function reject_deletion(boundary)
			Logger.error(LOG, "Profile deletion failed at '%s'; restoring exact prior owners.",
				boundary)
			recovery_debt = debt
			restore_deletion(debt)
			return false
		end

		if debt.active_changed then
			local fallback_ok, intent_lease = select_profile(deps, state, "basic", {
				persist = false,
				update_menu = false,
				defer_intent = true,
				skip_delete_recovery = true,
			})
			debt.active_published = fallback_ok == true
			if fallback_ok ~= true then
				return reject_deletion("active-profile fallback")
			end
			if type(intent_lease) ~= "table"
				or type(intent_lease.commit) ~= "function"
				or type(intent_lease.cancel) ~= "function" then
				return reject_deletion("active-profile intent lease")
			end
			debt.intent_lease = intent_lease
			debt.intent_pending = true
		end
		debt.registry_touched = true
		if not invoke_delete_boundary("Profile registry runtime publication",
			llm_mod.set_user_profiles, kept) then
			return reject_deletion("runtime registry")
		end
		state.llm_user_profiles = kept
		if not invoke_delete_boundary("Profile shortcut preference publication",
			shortcut_lease.publish) then
			return reject_deletion("shortcut preference")
		end
		debt.persistence_touched = true
		if not invoke_delete_boundary("Profile deletion preference commit", deps.save_prefs) then
			return reject_deletion("preferences")
		end
		debt.menu_touched = true
		local menu_ok, menu_result = xpcall(deps.update_menu, debug.traceback)
		if not menu_ok or menu_result == false then
			Logger.error(LOG, "Profile deletion menu publication refused: %s.",
				tostring(menu_result))
			return reject_deletion("menu")
		end
		if not invoke_delete_boundary("Profile shortcut native release",
			shortcut_lease.commit) then
			return reject_deletion("shortcut release")
		end
		if debt.intent_pending then
			-- The real model-switch owner issues a pure local lease: after the native
			-- release above there is no remaining operational boundary that can refuse.
			debt.intent_lease.commit()
			debt.intent_pending = false
		end

		recovery_debt = nil
		Logger.info(LOG, "User profile '%s' deleted transactionally.", profile_id)
		return true
	end

	return delete_profile, settle_recovery
end





-- ====================================
-- ====================================
-- ======= 2/ Menu Construction =======
-- ====================================
-- ====================================

--- Builds the strategy selection submenu with support for custom profiles.
--- @param deps table Global dependencies.
--- @param models_mgr table Manager reference to handle auto-detection heuristics.
--- @param delete_profile function Exact profile-deletion transaction.
--- @return table The Hammerspoon menu structure.
local function build_profile_menu(deps, models_mgr, delete_profile)
	local state  = deps.state
	local paused = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false
	local rows   = {}

	-- Auto-detect recommendation logic
	table.insert(rows, {
		label    = i18n.get("menu.profiles.auto_detect"),
		disabled = paused or nil,
		action       = not paused and function()
			if not settle_profile_mutation_recovery(deps) then return false end
			if type(deps.apply_recommended_prompt_profile) == "function" then
				return deps.apply_recommended_prompt_profile({
					dialog_title = i18n.get("menu.profiles.recommended_profile"),
					force_dialog = true,
				})
			end

			Logger.callback(LOG, "Recommended-profile unavailable notification",
				notifications.notify,
				i18n.get("menu.profiles.recommended_unavailable_title"),
				i18n.get("menu.profiles.recommended_unavailable_body"),
				"warning")
			return false
		end or nil,
	})
	table.insert(rows, { separator = true })

	-- Native profiles section
	table.insert(rows, { label = i18n.section("menu.profiles.header_default_profiles"), disabled = true })
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
		table.insert(rows, {
			label    = display_label .. (profile.description and ("  —  " .. profile.description) or "") .. extra,
			checked  = (state.llm_active_profile == pid) or nil,
			disabled = paused or nil,
			action       = not paused and function() return select_profile(deps, state, pid) end or nil,
		})
	end

	-- Custom profiles section
	local user_profiles = state.llm_user_profiles or {}
	if type(user_profiles) == "table" and #user_profiles > 0 then
		table.insert(rows, { separator = true })
		table.insert(rows, { label = i18n.section("menu.profiles.header_custom_profiles"), disabled = true })
		for i, profile in ipairs(user_profiles) do
			local pid = profile.id
			local display_label = ProfileLabel.format(profile.label or (i18n.get("menu.profiles.custom_profile_label") .. " " .. i), state.llm_num_predictions)
			local profile_shortcut = type(state.llm_profile_shortcuts) == "table" and state.llm_profile_shortcuts[pid] or nil
			local item = {
				label    = display_label,
				checked  = (state.llm_active_profile == pid) or nil,
				disabled = paused or nil,
			}
			
			-- User profiles get a sub-menu for Editing/Deleting
			item.items = {
				{
					label    = i18n.get("menu.profiles.use_profile"),
					checked  = (state.llm_active_profile == pid) or nil,
					disabled = paused or nil,
					action       = not paused and function() return select_profile(deps, state, pid) end or nil,
				},
				{
					label    = i18n.get("menu.profiles.shortcut_prefix"),
					disabled = paused or nil,
					action       = not paused and function()
						return shortcut_ui.prompt_shortcut({
							title = i18n.get("menu.profiles.shortcut_title"),
							message = i18n.get("menu.profiles.shortcut_prompt"),
							current_shortcut = type(state.llm_profile_shortcuts) == "table" and state.llm_profile_shortcuts[pid] or nil,
							default_mods = {"ctrl"},
							on_apply = function(mods, key)
								if type(deps.apply_llm_profile_shortcut) == "function" then
									return deps.apply_llm_profile_shortcut(pid, mods, key)
								end
								return false
							end,
						})
					end or nil,
				},
				{ separator = true },
				{
					label    = i18n.get("menu.profiles.edit_profile"),
					disabled = paused or nil,
					action       = not paused and function()
						if prompt_editor and type(prompt_editor.open) == "function" then
							hs.timer.doAfter(0.1, function()
							pcall(prompt_editor.open, profile, function(updated)
								if type(updated) == "table" then
									if not settle_profile_mutation_recovery(deps) then return false end
									for j, p in ipairs(state.llm_user_profiles) do
											if type(p) == "table" and p.id == updated.id then
												state.llm_user_profiles[j] = updated
												break
											end
										end
										sync_profiles(state)
										if deps.save_prefs() ~= true then return false end
										pcall(deps.update_menu)
										pcall(notifications.notify, i18n.get("profiles.updated_title"), ProfileLabel.format(updated.label, state.llm_num_predictions), "success")
									end
								end)
							end)
						end
					end or nil,
				},
				{
					label    = i18n.get("menu.profiles.delete_profile"),
					disabled = paused or nil,
					action       = not paused and function()
						local ok_c, choice = pcall(dialog.block_alert,
							string.format(i18n.get("menu.profiles.delete_confirm_title"), display_label),
							i18n.get("menu.profiles.delete_confirm_body"),
							i18n.get("button.delete"), i18n.get("common.cancel"), "critical")

						if ok_c and choice == i18n.get("button.delete") then
							return delete_profile(pid)
						end
						return false
					end or nil,
				},
			}
			table.insert(rows, item)
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
		table.insert(rows, { separator = true })
		table.insert(rows, {
			label = i18n.get("menu.profiles.clone_builtin"),
			action    = function() return clone_builtin_profile(deps, state, active_builtin) end,
		})
	end

	table.insert(rows, { separator = true })
	table.insert(rows, {
		label = i18n.get("menu.profiles.create_profile"),
		action    = not paused and function()
			if prompt_editor and type(prompt_editor.open) == "function" then
				hs.timer.doAfter(0.1, function()
					pcall(prompt_editor.open, nil, function(new_profile)
						if type(new_profile) == "table" then
							if not settle_profile_mutation_recovery(deps) then return false end
							if type(state.llm_user_profiles) ~= "table" then state.llm_user_profiles = {} end
							table.insert(state.llm_user_profiles, new_profile)
							if select_profile(deps, state, new_profile.id) ~= true then return false end
							pcall(notifications.notify, i18n.get("profiles.created_title"), ProfileLabel.format(new_profile.label, state.llm_num_predictions), "success")
							Logger.info(LOG, string.format("Custom profile %s created.", new_profile.id))
						end
					end)
				end)
			end
		end or nil,
	})
	
	return ManifestMenu.render_rows(rows, "llm_profile")
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
	if sync_profiles(deps.state) ~= true then
		Logger.error(LOG, "Initial user-profile runtime synchronization did not commit.")
	end
	local delete_profile, settle_delete_recovery = make_profile_deleter(deps)
	deps.settle_profile_delete_recovery = settle_delete_recovery

	--- Returns the main menu entry for Strategy selection.
	function obj.get_menu_item()
		local label = active_profile_label(deps.state)
		
		local info = models_mgr and models_mgr.get_model_info(deps.state.llm_model) or {}
		local is_thinking = info.emojis and info.emojis:find("🧠💭")
		local warning = (is_thinking and (deps.state.llm_active_profile == "basic" or deps.state.llm_active_profile == "advanced")) and "  ⚠️" or ""

		return {
			label = string.format(i18n.get("menu.profiles.profile_label_prefix"), label) .. warning,
			menu  = build_profile_menu(deps, models_mgr, delete_profile)
		}
	end

	return obj
end

return M
