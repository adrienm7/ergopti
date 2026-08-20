--- ui/menu/menu_llm/api_panel.lua

--- ==============================================================================
--- MODULE: LLM API Panel
--- DESCRIPTION:
--- Builds the remote-API entries submenu (list, add per-provider, remove active)
--- for the LLM tray menu.
---
--- FEATURES & RATIONALE:
--- 1. Isolated panel: all CRUD logic for the remote-API entries (list, add,
---    remove, validate) lives here so init.lua stays free of dialog scaffolding.
--- 2. Optimistic UI with rollback: a new entry is staged in memory, the menu
---    refreshes immediately, and the entry is only persisted to Keychain if the
---    availability probe succeeds — on failure the in-memory state is rolled back.
--- ==============================================================================

local M = {}

local llm_mod       = require("modules.llm")
local i18n          = require("infra.i18n")
local Logger        = require("infra.logger")
local dialog        = require("infra.dialog_util")
local notifications = require("infra.notifications")
local ManifestMenu   = require("infra.manifest_menu")

local LOG = "api_panel"

-- Monotone counter for unique entry IDs.  os.time() alone has 1-second
-- resolution, so two entries created within the same second get the same id.
-- The seq suffix makes every id distinct regardless of wall-clock resolution.
local _entry_seq = 0

-- Monotone counter for every remote-entry mutation. A validation or persistence
-- callback from A must not publish after the user selected/deleted B.
local _add_gen = 0
local _mutation_owner = nil

--- Acquires the one remote-entry mutation lease. Menu rows can outlive the
--- menu build that created them, so every action checks this at invocation as
--- well as exposing a disabled row while async validation/persistence runs.
--- @return number|nil generation
local function begin_mutation()
	if _mutation_owner ~= nil then return nil end
	_add_gen = _add_gen + 1
	_mutation_owner = _add_gen
	return _mutation_owner
end

local function mutation_is_current(generation)
	return generation == _add_gen and _mutation_owner == generation
end

local function finish_mutation(generation)
	if mutation_is_current(generation) then _mutation_owner = nil end
end

--- Wraps pcall and logs Logger.error when the wrapped call fails.
--- @param name string Short label identifying the call site.
--- @param fn function The function to call.
--- @vararg any Arguments forwarded to ``fn``.
local function pcall_log(name, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		Logger.error(LOG, "pcall '%s' failed: %s", tostring(name), tostring(err))
	end
	return ok, err
end

--- Starts the callback-based persistence transaction and converts an immediate
--- throw into the same explicit failure result as an async rejection.
--- @param label string Diagnostic label.
--- @param callback function Receives (ok, reason, durable).
--- @param options table|nil Persistence options.
local function persist_entries(label, callback, options)
	local ok, err = xpcall(function()
		llm_mod.persist_api_entries(callback, options)
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s raised before persistence started: %s", tostring(label), tostring(err))
		pcall_log(label .. " failure callback", callback, false, "launch_raised", false)
	end
end

local function notify_persistence_failure(label)
	Logger.error(LOG, "%s was rejected; runtime state was restored.", tostring(label))
	pcall_log("notify(api persistence failure)", notifications.notify,
		i18n.get("common.error_title"), i18n.get("dialog.bulk_toggle.save_failed"), "error")
end

--- Revokes the prediction-engine identity before a remote-entry mutation.
--- ApiRemote fences callbacks and readiness, while the keymap bridge owns the
--- already-visible tooltip and request counters; both halves must transition.
--- @param keymap table Keymap facade injected by menu_llm.
--- @param label string Mutation label for diagnostics.
--- @return boolean committed
local function reset_prediction_identity(keymap, label)
	if type(keymap) ~= "table" or type(keymap.reset_predictions) ~= "function" then
		Logger.error(LOG, "Cannot %s: keymap.reset_predictions is unavailable.", tostring(label))
		return false
	end
	local ok, committed = xpcall(function()
		return keymap.reset_predictions(false)
	end, debug.traceback)
	if not ok or committed ~= true then
		Logger.error(LOG, "Cannot %s: prediction identity reset did not commit (result: %s).",
			tostring(label), tostring(committed))
		return false
	end
	return true
end





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Builds the API entries submenu and returns the title string and menu table.
--- Only call when state.llm_backend == "api" — returns nil, nil otherwise.
--- @param ctx table Context with fields: state, paused, keymap, update_menu, WarmupCtrl.
--- @return string|nil title   Title string for the parent row, or nil.
--- @return table|nil  menu    The entries submenu, rendered from row data.
function M.build(ctx)
	local state       = ctx.state
	local paused      = ctx.paused
	local update_menu = ctx.update_menu
	local WarmupCtrl  = ctx.WarmupCtrl
	local keymap      = ctx.keymap

	if state.llm_backend ~= "api" then
		return nil, nil
	end

	local api_remote = llm_mod.api_remote
	local entries    = (api_remote and api_remote.get_entries()) or {}
	local active_id  = (api_remote and api_remote.get_active_entry_id()) or ""
	local rows       = {}
	local mutation_busy = _mutation_owner ~= nil


	-- =====================================================
	-- ===== 1.1) Entry list =====
	-- =====================================================

	-- One row per configured entry — clicking sets it as active and triggers a
	-- warmup so the next prediction uses the new entry immediately.
	for _, e in ipairs(entries) do
		local provider_label = (api_remote.PROVIDERS[e.provider] and api_remote.PROVIDERS[e.provider].label) or e.provider
		local entry_title = string.format("%s — %s (%s)",
			tostring(e.label or e.id or "?"),
			tostring(e.model or "?"),
			provider_label)
		table.insert(rows, {
			label    = entry_title,
			checked  = (e.id == active_id),
			disabled = (paused or mutation_busy) or nil,
			action       = (not paused and not mutation_busy) and function()
				if _mutation_owner ~= nil then return false end
				if reset_prediction_identity(keymap, "select remote API entry") ~= true then return false end
				local previous_active_id = api_remote.get_active_entry_id()
				local previous_model = state.llm_model
				local my_generation = begin_mutation()
				if not my_generation then return false end
				api_remote.set_active_entry_id(e.id)
				state.llm_model = tostring(e.model or "")
				persist_entries("persist_api_entries(set_active)", function(ok, reason, durable)
					if not mutation_is_current(my_generation) then return end
					finish_mutation(my_generation)
					if ok == true or durable == true then
						if ok ~= true then
							Logger.error(LOG, "Remote API selection committed with cleanup debt: %s",
								tostring(reason))
						end
						WarmupCtrl.warmup("api_set_active")
						pcall_log("update_menu(set_active)", update_menu)
						return
					end
					api_remote.set_active_entry_id(previous_active_id)
					state.llm_model = previous_model
					notify_persistence_failure("Remote API entry selection")
					pcall_log("update_menu(set_active rollback)", update_menu)
				end)
				return true
			end or nil
		})
	end

	if #entries > 0 then
		table.insert(rows, { separator = true })
	end


	-- =====================================================
	-- ===== 1.2) Add entry =====
	-- =====================================================

	-- One "Add" entry per provider so the user picks the shape first
	-- (Bearer auth vs x-api-key vs Gemini's URL token, plus the right
	-- default model). Subsequent prompts collect the credentials.
	local add_rows = {}
	for _, pid in ipairs(api_remote.PROVIDER_ORDER) do
		local p = api_remote.PROVIDERS[pid]
		if p then
			table.insert(add_rows, {
				label    = string.format("➕ %s", p.label),
				disabled = (paused or mutation_busy) or nil,
				action       = (not paused and not mutation_busy) and function()
					if _mutation_owner ~= nil then return false end
					local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
					local function prompt_field(title_key, default_val, hint)
						local ok, ret_a, ret_b = pcall(dialog.text_prompt,
							title_key, hint, default_val or "",
							"OK", i18n.get("button.cancel"))
						if not ok then return nil end
						local picked_btn, picked_text
						if ret_a == "OK" or ret_a == i18n.get("button.cancel") then
							picked_btn, picked_text = ret_a, ret_b
						else
							picked_text, picked_btn = ret_a, ret_b
						end
						if picked_btn ~= "OK" then return nil end
						return trim(picked_text)
					end

					-- Use existing i18n keys for prompt hints so non-French users
					-- see localized text. Provider name mixed with field tag.
					local base_url = prompt_field(
						string.format("API %s — URL", p.label),
						p.base_url,
						i18n.get("menu.llm.api_prompt_url")) or ""
					local token = prompt_field(
						string.format("API %s — Token", p.label),
						"",
						i18n.get("menu.llm.api_prompt_token"))
					if not token or token == "" then return end
					local model = prompt_field(
						string.format("API %s — Model", p.label),
						p.default_model,
						i18n.get("menu.llm.api_prompt_model")) or p.default_model
					local label = prompt_field(
						string.format("API %s — Label", p.label),
						"",
						i18n.get("menu.llm.api_prompt_name")) or ""

					-- Unique id: seq suffix prevents collision when two entries are
					-- created within the same second (os.time() resolution = 1s).
					_entry_seq = _entry_seq + 1
					local id = string.format("%s-%d-%d", pid, os.time(), _entry_seq)
					local new_entry = {
						id       = id,
						provider = pid,
						base_url = (base_url ~= "" and base_url ~= p.base_url) and base_url or "",
						token    = token,
						model    = (model ~= "" and model) or p.default_model,
						label    = (label ~= "" and label) or p.label,
					}
					local previous_active_id = api_remote.get_active_entry_id and api_remote.get_active_entry_id() or ""
					local previous_model = state.llm_model
					local list = api_remote.get_entries() or {}
					local previous_entries = {}
					local clone = {}
					for _, x in ipairs(list) do
						table.insert(previous_entries, x)
						table.insert(clone, x)
					end
					table.insert(clone, new_entry)
					-- Stage in memory only — DO NOT persist yet. check_availability
					-- needs an active entry to probe credentials against, but we
					-- don't want to write a bad token into the Keychain. Persist only
					-- on success; on failure, roll the in-memory state back.
					if reset_prediction_identity(keymap, "stage remote API entry") ~= true then return false end
					local my_add_gen = begin_mutation()
					if not my_add_gen then return false end
					api_remote.set_entries(clone)
					api_remote.set_active_entry_id(id)
					state.llm_model = new_entry.model
					local validation_started, validation_error = xpcall(function()
					api_remote.check_availability(new_entry.model,
						function()
							if not mutation_is_current(my_add_gen) then return end
							persist_entries("persist_api_entries(add_entry_ok)", function(ok, reason, durable)
								if not mutation_is_current(my_add_gen) then return end
								finish_mutation(my_add_gen)
								if ok == true or durable == true then
									WarmupCtrl.warmup("api_add_entry")
									pcall_log("update_menu(add committed)", update_menu)
									if ok == true then
										pcall_log("notify(api_validated)", notifications.notify,
											i18n.get("menu.llm.api_validated_title"),
											string.format(i18n.get("menu.llm.api_validated_body"), new_entry.label),
											"success")
									else
										Logger.error(LOG, "Remote API entry committed with cleanup debt: %s",
											tostring(reason))
									end
									return
								end
								api_remote.set_entries(previous_entries)
								api_remote.set_active_entry_id(previous_active_id)
								state.llm_model = previous_model
								notify_persistence_failure("Remote API entry creation")
								pcall_log("update_menu(add persistence rollback)", update_menu)
							end)
						end,
						function(_unreachable)
							if not mutation_is_current(my_add_gen) then return end
							finish_mutation(my_add_gen)
							-- Validation failed: roll the in-memory list back so the
							-- bogus token never lands in Keychain. Only revert the
							-- active selection if it has not been changed by the user
							-- since this probe was launched.
							api_remote.set_entries(previous_entries)
							api_remote.set_active_entry_id(previous_active_id)
							state.llm_model = previous_model
							pcall_log("notify(api_unreachable)", notifications.notify,
								i18n.get("menu.llm.api_unreachable_title"),
								string.format(i18n.get("menu.llm.api_unreachable_body"), new_entry.label),
								"warning")
							pcall_log("update_menu(rollback)", update_menu)
						end)
					end, debug.traceback)
					if not validation_started and mutation_is_current(my_add_gen) then
						finish_mutation(my_add_gen)
						api_remote.set_entries(previous_entries)
						api_remote.set_active_entry_id(previous_active_id)
						state.llm_model = previous_model
						Logger.error(LOG, "Remote API validation launch raised: %s",
							tostring(validation_error))
						notify_persistence_failure("Remote API validation")
						pcall_log("update_menu(validation launch rollback)", update_menu)
					end
			end or nil,
			})
		end
	end

	table.insert(rows, {
		label    = "➕ " .. i18n.get("menu.llm.api_add_entry"),
		disabled = (paused or mutation_busy) or nil,
		items    = add_rows,
	})


	-- =====================================================
	-- ===== 1.3) Remove active entry =====
	-- =====================================================

	-- Remove only the active entry — keeps the action unambiguous and mirrors
	-- the AHK tray's "remove active" semantics. Disabled when nothing is
	-- configured so the user does not chase a no-op click.
	local active_entry = api_remote and api_remote.get_active_entry() or nil
	local active_label = active_entry and (active_entry.label or active_entry.id or "") or ""
	table.insert(rows, {
		label    = active_entry
			and string.format("🗑️ %s (%s)", i18n.get("menu.llm.api_remove_entry"), active_label)
			or  "🗑️ " .. i18n.get("menu.llm.api_remove_entry"),
		disabled = (paused or mutation_busy or (active_entry == nil)) or nil,
		action       = (not paused and not mutation_busy and active_entry) and function()
			if _mutation_owner ~= nil then return false end
			-- Confirm before destroying — the saved token is gone for good once
			-- we delete it. Worth one extra click in a small menu.
			local ok_c, choice = pcall(dialog.block_alert,
				string.format(i18n.get("menu.llm.api_remove_confirm_title"), active_label),
				i18n.get("menu.llm.api_remove_confirm_body"),
				i18n.get("button.delete"), i18n.get("button.cancel"), "critical")
			if not (ok_c and choice == i18n.get("button.delete")) then
				return
			end
			local previous_entries = api_remote.get_entries() or {}
			local previous_active_id = api_remote.get_active_entry_id()
			local previous_model = state.llm_model
			local kept = {}
			for _, x in ipairs(previous_entries) do
				if x.id ~= active_entry.id then table.insert(kept, x) end
			end
			if reset_prediction_identity(keymap, "delete remote API entry") ~= true then return false end
			local my_generation = begin_mutation()
			if not my_generation then return false end
			local next_active = kept[1]
			api_remote.set_entries(kept)
			api_remote.set_active_entry_id(next_active and next_active.id or "")
			state.llm_model = next_active and tostring(next_active.model or "") or ""
			persist_entries("persist_api_entries(delete)", function(ok, reason, durable)
				if not mutation_is_current(my_generation) then return end
				finish_mutation(my_generation)
				if durable == true then
					if next_active then WarmupCtrl.warmup("api_delete_entry") end
					if ok ~= true then
						Logger.error(LOG,
							"Remote API entry deletion is durable but Keychain cleanup remains pending: %s",
							tostring(reason))
					end
					pcall_log("update_menu(delete committed)", update_menu)
					return
				end
				api_remote.set_entries(previous_entries)
				api_remote.set_active_entry_id(previous_active_id)
				state.llm_model = previous_model
				notify_persistence_failure("Remote API entry deletion")
				pcall_log("update_menu(delete rollback)", update_menu)
			end, { delete_entry_ids = { active_entry.id } })
			return true
		end or nil,
	})


	-- =====================================================
	-- ===== 1.4) Build parent row title =====
	-- =====================================================

	local api_title = active_entry
		and string.format("API — %s (%s)", active_label,
			(api_remote.PROVIDERS[active_entry.provider] and api_remote.PROVIDERS[active_entry.provider].label) or active_entry.provider)
		or  "API — " .. i18n.get("menu.llm.api_no_entry")

	return api_title, ManifestMenu.render_rows(rows, "llm_backend")
end

--- Builds the "active model" submenu when the remote API backend is selected.
--- Mirrors Windows ``_LLM_Menu_BuildApiEntriesMenu()`` — local catalogue rows
--- are hidden because they have no ``urls.api`` entry in models.json.
--- @param ctx table Context with fields: state, paused, keymap, update_menu, WarmupCtrl.
--- @return table menu Populated API entry picker.
function M.build_model_picker(ctx)
	local state       = ctx.state
	local paused      = ctx.paused
	local update_menu = ctx.update_menu
	local WarmupCtrl  = ctx.WarmupCtrl
	local keymap      = ctx.keymap

	local api_remote = llm_mod.api_remote
	local entries    = (api_remote and api_remote.get_entries()) or {}
	local active_id  = (api_remote and api_remote.get_active_entry_id()) or ""
	local rows       = {}
	local mutation_busy = _mutation_owner ~= nil

	table.insert(rows, {
		label   = i18n.get("menu.llm.no_model"),
		checked = (active_id == "" or active_id == nil),
		disabled = (paused or mutation_busy) or nil,
		action      = (not paused and not mutation_busy) and function()
			if _mutation_owner ~= nil then return false end
			if api_remote and api_remote.set_active_entry_id then
				if reset_prediction_identity(keymap, "select No Model") ~= true then return false end
				local previous_active_id = api_remote.get_active_entry_id()
				local previous_model = state.llm_model
				local my_generation = begin_mutation()
				if not my_generation then return false end
				api_remote.set_active_entry_id("")
				state.llm_model = ""
				persist_entries("persist_api_entries(clear_active)", function(ok, reason, durable)
					if not mutation_is_current(my_generation) then return end
					finish_mutation(my_generation)
					if ok == true or durable == true then
						if ok ~= true then
							Logger.error(LOG, "No Model selection committed with cleanup debt: %s",
								tostring(reason))
						end
						pcall_log("update_menu(clear_active)", update_menu)
						return
					end
					api_remote.set_active_entry_id(previous_active_id)
					state.llm_model = previous_model
					notify_persistence_failure("No Model selection")
					pcall_log("update_menu(clear_active rollback)", update_menu)
				end)
				return true
			end
			return false
		end or nil,
	})

	if #entries > 0 then
		table.insert(rows, { separator = true })
	end

	for _, e in ipairs(entries) do
		local provider_label = (api_remote.PROVIDERS[e.provider] and api_remote.PROVIDERS[e.provider].label) or e.provider
		local entry_title = string.format("%s — %s (%s)",
			tostring(e.label or e.id or "?"),
			tostring(e.model or "?"),
			provider_label)
		table.insert(rows, {
			label    = entry_title,
			checked  = (e.id == active_id),
			disabled = (paused or mutation_busy) or nil,
			action       = (not paused and not mutation_busy) and function()
				if _mutation_owner ~= nil then return false end
				if reset_prediction_identity(keymap, "select remote API entry") ~= true then return false end
				local previous_active_id = api_remote.get_active_entry_id()
				local previous_model = state.llm_model
				local my_generation = begin_mutation()
				if not my_generation then return false end
				api_remote.set_active_entry_id(e.id)
				state.llm_model = tostring(e.model or "")
				persist_entries("persist_api_entries(set_active)", function(ok, reason, durable)
					if not mutation_is_current(my_generation) then return end
					finish_mutation(my_generation)
					if ok == true or durable == true then
						if ok ~= true then
							Logger.error(LOG, "Remote API selection committed with cleanup debt: %s",
								tostring(reason))
						end
						WarmupCtrl.warmup("api_set_active")
						pcall_log("update_menu(set_active)", update_menu)
						return
					end
					api_remote.set_active_entry_id(previous_active_id)
					state.llm_model = previous_model
					notify_persistence_failure("Remote API entry selection")
					pcall_log("update_menu(set_active rollback)", update_menu)
				end)
				return true
			end or nil,
		})
	end

	return ManifestMenu.render_rows(rows, "llm_model")
end

return M
