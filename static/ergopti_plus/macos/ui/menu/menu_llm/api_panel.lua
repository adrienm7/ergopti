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
--- 3. Automatic names: every entry reads <provider>/<model>, told apart by host
---    then order when two share it (_shared/lua/llm/api_entry_names.lua). Adding
---    an entry asks no name, and a `label` an earlier build stored is not read.
--- ==============================================================================

local M = {}

local llm_mod       = require("modules.llm")
local i18n          = require("infra.i18n")
local Logger        = require("infra.logger")
local dialog        = require("infra.dialog_util")
local notifications = require("infra.notifications")
local ManifestMenu   = require("infra.manifest_menu")
local ProviderUses   = require("modules.llm.provider_uses")
local EntryNames     = require("llm.api_entry_names")

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

--- Fills ``{1}``-style placeholders shared with the Windows driver (whose
--- formatter cannot do positional ``%s``). Translators may reorder the
--- placeholders; only the set matters.
--- @param template string Locale template.
--- @param args table Positional values.
--- @return string
local function fill_placeholders(template, args)
	return (tostring(template or ""):gsub("{(%d+)}", function(index)
		return tostring(args[tonumber(index)] or "")
	end))
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

--- The automatic name of every entry, by id: <provider>/<model>, with the
--- model and address its requests use (the provider's defaults for empty
--- fields), told apart as the shared rule tells them apart.
--- @param api_remote table The remote backend, for its provider catalogue.
--- @param entries table The entries to name, in their order.
--- @return table names Entry id -> name.
local function entry_names(api_remote, entries)
	local providers = type(api_remote) == "table" and type(api_remote.PROVIDERS) == "table"
		and api_remote.PROVIDERS or {}
	local resolved = {}
	for index, e in ipairs(entries or {}) do
		local provider = providers[e.provider] or {}
		resolved[index] = {
			provider = tostring(e.provider or ""),
			model = (type(e.model) == "string" and e.model ~= "") and e.model or (provider.default_model or ""),
			base_url = (type(e.base_url) == "string" and e.base_url ~= "") and e.base_url
				or (provider.base_url or ""),
		}
	end
	local names = {}
	for index, name in ipairs(EntryNames.names(resolved)) do names[entries[index].id] = name end
	return names
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

--- Display name for the active API entry: its automatic name, as the entry
--- picker shows it, else nil. Used by the model parent row so backend api
--- never shows the stale local-model slot.
--- @return string|nil Display name or nil.
function M.active_entry_display_name()
	local remote = llm_mod and llm_mod.api_remote
	if type(remote) ~= "table" then return nil end
	if type(remote.get_active_entry_id) ~= "function"
		or type(remote.get_entries) ~= "function" then
		return nil
	end
	local active_id = remote.get_active_entry_id()
	if type(active_id) ~= "string" or active_id == "" then return nil end
	return entry_names(remote, remote.get_entries() or {})[active_id]
end

-- Shared probe-verdict rendering for the Test action and the post-add
-- probe: success carries excerpt + latency, failure appends the provider's
-- own "[status] message" line (no locale key needed for it). Module-level:
-- the add action's closure is built before any later local of M.build, so a
-- helper declared there resolved to a nil global when the probe answered.
local function excerpt_reply(text)
	local s = tostring(text or "")
	if #s > 120 then return s:sub(1, 120) .. "..." end
	return s
end
local function probe_fail_body(label, detail)
	local fail_body = string.format(i18n.get("menu.llm.api_unreachable_body"), label)
	if type(detail) == "table" then
		local status = tonumber(detail.status) or 0
		local message = type(detail.message) == "string"
			and detail.message:match("^%s*(.-)%s*$") or ""
		if message ~= "" then
			fail_body = fail_body .. "\n"
				.. (status > 0 and string.format("[%d] %s", status, message) or message)
		end
	end
	return fail_body
end
local function notify_probe_verdict(ok, label, reply, ms, detail)
	if ok then
		pcall_log("notify(api_test_ok)", notifications.notify,
			i18n.get("menu.llm.api_test_ok_title"),
			fill_placeholders(i18n.get("menu.llm.api_test_ok_body"),
				{ label, tostring(ms), excerpt_reply(reply) }),
			"success")
	else
		pcall_log("notify(api_test_fail)", notifications.notify,
			i18n.get("menu.llm.api_unreachable_title"),
			probe_fail_body(label, detail),
			"error")
	end
end

--- Tells whether an entry's provider serves the agent's System 1 only (a
--- decisions provider such as TypeSafe's Jev): such an entry is never the
--- prediction backend, so it is kept out of the entry pickers and managed by
--- its own Test and Remove rows.
--- @param api_remote table The remote backend.
--- @param entry table API entry.
--- @return boolean system1_only
local function is_system1_only(api_remote, entry)
	local providers = type(api_remote) == "table" and api_remote.PROVIDERS or nil
	local provider = type(providers) == "table" and type(entry) == "table" and providers[entry.provider] or nil
	if type(provider) ~= "table" or type(provider.format) ~= "string" then return false end
	return not ProviderUses.format_serves(provider.format, ProviderUses.PREDICTION)
end

--- Asks whether to probe a just-created entry end to end. Existing
--- locale strings only (no new keys): the action label as question,
--- OK/Cancel buttons. A declined answer is any non-OK choice.
--- @return boolean True when the user confirmed.
local function probe_offer_accepted()
	local ok_c, choice = pcall(dialog.block_alert,
		i18n.get("menu.llm.api_dialog_title"),
		i18n.get("menu.llm.api_test_entry"),
		i18n.get("button.ok"), i18n.get("button.cancel"), "informational")
	return ok_c and choice == i18n.get("button.ok")
end

--- Adds an entry whose provider serves System 1 only (a decisions provider).
--- It never becomes the prediction backend: the active entry is kept, the
--- entry is proven by the shared decisions probe (api_providers.json
--- decisions_test), and only a proven entry is persisted; a refused one is
--- rolled back with the provider's verdict.
--- @param add table { api_remote, keymap, update_menu, WarmupCtrl, new_entry,
---        entries (with the new one), previous_entries, previous_active_id, admit }.
--- @return boolean started True when the probe was sent.
local function add_system1_entry(add)
	local api_remote, new_entry = add.api_remote, add.new_entry
	local label = entry_names(api_remote, add.entries)[new_entry.id]
	if reset_prediction_identity(add.keymap, "stage System 1 API entry") ~= true then return false end
	if add.admit() ~= true then return false end
	local my_add_gen = begin_mutation()
	if not my_add_gen then return false end
	--- Restores the entries, and the prediction backend the staging invalidated.
	local function restore_entries()
		api_remote.set_entries(add.previous_entries)
		if add.previous_active_id ~= "" then add.WarmupCtrl.warmup("api_add_entry_rollback") end
	end
	api_remote.set_entries(add.entries)
	Logger.info(LOG, "API test dispatched for new System 1 entry '%s' (model %s).",
		label, tostring(new_entry.model or ""))
	local call_ok, dispatched = xpcall(function()
		return api_remote.test_request(new_entry, nil, function(reply, ms)
			if not mutation_is_current(my_add_gen) then return end
			persist_entries("persist_api_entries(add_system1_entry)", function(ok, reason, durable)
				if not mutation_is_current(my_add_gen) then return end
				finish_mutation(my_add_gen)
				if ok == true or durable == true then
					if ok ~= true then
						Logger.error(LOG, "System 1 API entry committed with cleanup debt: %s", tostring(reason))
					end
					if add.previous_active_id ~= "" then add.WarmupCtrl.warmup("api_add_entry") end
					pcall_log("update_menu(add system1 committed)", add.update_menu)
					notify_probe_verdict(true, label, reply, ms, nil)
					return
				end
				restore_entries()
				notify_persistence_failure("System 1 API entry creation")
				pcall_log("update_menu(add system1 persistence rollback)", add.update_menu)
			end)
		end, function(_, detail)
			if not mutation_is_current(my_add_gen) then return end
			finish_mutation(my_add_gen)
			restore_entries()
			notify_probe_verdict(false, label, "", 0, detail)
			pcall_log("update_menu(add system1 rollback)", add.update_menu)
		end)
	end, debug.traceback)
	if not call_ok then
		Logger.error(LOG, "System 1 API entry probe raised: %s", tostring(dispatched))
		if mutation_is_current(my_add_gen) then
			finish_mutation(my_add_gen)
			restore_entries()
			pcall_log("update_menu(add system1 raised)", add.update_menu)
		end
		return false
	end
	return dispatched == true
end

--- Builds the Test and Remove rows of one System 1-only entry, which no
--- entry picker lists: they name the entry, since it is never the active one.
--- @param ctx table Context with fields: state, paused, is_paused, keymap, update_menu, WarmupCtrl.
--- @param api_remote table The remote backend.
--- @param entry table The System 1-only entry.
--- @param busy boolean True while a mutation or a pause forbids actions.
--- @param label string The entry's automatic name.
--- @return table rows
local function system1_entry_rows(ctx, api_remote, entry, busy, label)
	local test_row = {
		label = string.format("%s (%s)", i18n.get("menu.llm.api_test_entry"), label),
		disabled = busy or nil,
		action = (not busy) and function()
			Logger.info(LOG, "API test dispatched for '%s' (model %s).", label, tostring(entry.model or ""))
			local call_ok, dispatched = xpcall(function()
				return api_remote.test_request(entry, nil,
					function(reply, ms) notify_probe_verdict(true, label, reply, ms, nil) end,
					function(_, detail) notify_probe_verdict(false, label, "", 0, detail) end)
			end, debug.traceback)
			if not call_ok or dispatched ~= true then
				Logger.error(LOG, "API test dispatch failed: %s", tostring(dispatched))
				return false
			end
			return true
		end or nil,
	}
	local remove_row = {
		label = string.format("🗑️ %s (%s)", i18n.get("menu.llm.api_remove_entry"), label),
		disabled = busy or nil,
		action = (not busy) and function()
			if _mutation_owner ~= nil then return false end
			local ok_c, choice = pcall(dialog.block_alert,
				string.format(i18n.get("menu.llm.api_remove_confirm_title"), label),
				i18n.get("menu.llm.api_remove_confirm_body"),
				i18n.get("button.delete"), i18n.get("button.cancel"), "critical")
			if not (ok_c and choice == i18n.get("button.delete")) then return end
			local previous_entries = api_remote.get_entries() or {}
			local kept = {}
			for _, x in ipairs(previous_entries) do
				if x.id ~= entry.id then table.insert(kept, x) end
			end
			if reset_prediction_identity(ctx.keymap, "delete System 1 API entry") ~= true then return false end
			local my_generation = begin_mutation()
			if not my_generation then return false end
			local active_id = api_remote.get_active_entry_id() or ""
			api_remote.set_entries(kept)
			persist_entries("persist_api_entries(delete system1)", function(ok, reason, durable)
				if not mutation_is_current(my_generation) then return end
				finish_mutation(my_generation)
				if durable ~= true then
					api_remote.set_entries(previous_entries)
					notify_persistence_failure("System 1 API entry deletion")
				elseif ok ~= true then
					Logger.error(LOG,
						"System 1 API entry deletion is durable but Keychain cleanup remains pending: %s",
						tostring(reason))
				end
				-- Setting the entries invalidated the prediction backend either way
				if active_id ~= "" then ctx.WarmupCtrl.warmup("api_delete_system1_entry") end
				pcall_log("update_menu(delete system1)", ctx.update_menu)
			end, { delete_entry_ids = { entry.id } })
			return true
		end or nil,
	}
	return { test_row, remove_row }
end

--- Builds the API entries submenu and returns the title string and menu table.
--- Only call when state.llm_backend == "api" — returns nil, nil otherwise.
--- @param ctx table Context with fields: state, paused, is_paused, keymap, update_menu, WarmupCtrl.
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
	local names      = entry_names(api_remote, entries)

	-- Retained provider choices must read the actual native owner, including
	-- after each modal prompt. The menu-build pause snapshot is display data.
	local function native_unpaused()
		if type(ctx.is_paused) ~= "function" then return false end
		local ok, current_paused = pcall(ctx.is_paused)
		return ok and type(current_paused) == "boolean" and current_paused == false
	end
	local function add_commands_ready()
		return native_unpaused() and state.llm_backend == "api" and _mutation_owner == nil
	end


	-- =====================================================
	-- ===== 1.1) Entry list =====
	-- =====================================================

	-- One row per configured entry, named <provider>/<model> — clicking
	-- sets it as active and triggers a warmup so the next prediction uses
	-- the new entry immediately.
	for _, e in ipairs(entries) do
		if not is_system1_only(api_remote, e) then
			table.insert(rows, {
				label    = names[e.id],
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
					if not add_commands_ready() then return false end
					local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
					local function prompt_field(title_key, default_val, hint)
						if not add_commands_ready() then return false, nil end
						local ok, ret_a, ret_b = pcall(dialog.text_prompt,
							title_key, hint, default_val or "",
							"OK", i18n.get("button.cancel"))
						if not ok then return false, nil end
						local picked_btn, picked_text
						if ret_a == "OK" or ret_a == i18n.get("button.cancel") then
							picked_btn, picked_text = ret_a, ret_b
						else
							picked_text, picked_btn = ret_a, ret_b
						end
						if picked_btn ~= "OK" then return false, nil end
						if not add_commands_ready() then return false, nil end
						return true, trim(picked_text)
					end

					-- Use existing i18n keys for prompt hints so non-French users
					-- see localized text. Provider name mixed with field tag.
					local base_url_ok, base_url = prompt_field(
						string.format("API %s — URL", p.label),
						p.base_url,
						i18n.get("menu.llm.api_prompt_url"))
					if not base_url_ok then return false end
					local token_ok, token = prompt_field(
						string.format("API %s — Token", p.label),
						"",
						i18n.get("menu.llm.api_prompt_token"))
					if not token_ok or token == "" then return false end
					local model_ok, model = prompt_field(
						string.format("API %s — Model", p.label),
						p.default_model,
						i18n.get("menu.llm.api_prompt_model"))
					if not model_ok then return false end

					-- Unique id: seq suffix prevents collision when two entries are
					-- created within the same second (os.time() resolution = 1s).
					_entry_seq = _entry_seq + 1
					local id = string.format("%s-%d-%d", pid, os.time(), _entry_seq)
					local list = api_remote.get_entries() or {}
					local new_entry = {
						id       = id,
						provider = pid,
						base_url = (base_url ~= "" and base_url ~= p.base_url) and base_url or "",
						token    = token,
						model    = (model ~= "" and model) or p.default_model,
					}
					local previous_active_id = api_remote.get_active_entry_id and api_remote.get_active_entry_id() or ""
					local previous_model = state.llm_model
					local previous_entries = {}
					local clone = {}
					for _, x in ipairs(list) do
						table.insert(previous_entries, x)
						table.insert(clone, x)
					end
					table.insert(clone, new_entry)
					local new_name = entry_names(api_remote, clone)[id]
					if is_system1_only(api_remote, new_entry) then
						return add_system1_entry({
							api_remote = api_remote, keymap = keymap, update_menu = update_menu,
							WarmupCtrl = WarmupCtrl, new_entry = new_entry, entries = clone,
							previous_entries = previous_entries, previous_active_id = previous_active_id,
							admit = add_commands_ready,
						})
					end
					-- Stage in memory only — DO NOT persist yet. check_availability
					-- needs an active entry to probe credentials against, but we
					-- don't want to write a bad token into the Keychain. Persist only
					-- on success; on failure, roll the in-memory state back.
					if reset_prediction_identity(keymap, "stage remote API entry") ~= true then return false end
					if not add_commands_ready() then return false end
					local my_add_gen = begin_mutation()
					if not my_add_gen then return false end
					api_remote.set_entries(clone)
					api_remote.set_active_entry_id(id)
					state.llm_model = new_entry.model
					local function rollback_validation(kind, detail)
						if not mutation_is_current(my_add_gen) then return false end
						finish_mutation(my_add_gen)
						api_remote.set_entries(previous_entries)
						api_remote.set_active_entry_id(previous_active_id)
						state.llm_model = previous_model
						if kind == "unreachable" then
							pcall_log("notify(api_unreachable)", notifications.notify,
								i18n.get("menu.llm.api_unreachable_title"),
								string.format(i18n.get("menu.llm.api_unreachable_body"), new_name),
								"warning")
						else
							Logger.error(LOG, "Remote API validation did not commit (%s): %s",
								tostring(kind), tostring(detail))
							notify_persistence_failure("Remote API validation")
						end
						pcall_log("update_menu(validation rollback)", update_menu)
						return true
					end

					local validation_call_ok, validation_result = xpcall(function()
						return api_remote.check_availability(new_entry.model,
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
											string.format(i18n.get("menu.llm.api_validated_body"), new_name),
											"success")
									else
										Logger.error(LOG, "Remote API entry committed with cleanup debt: %s",
											tostring(reason))
									end
									-- Offer the full end-to-end probe on the
									-- just-saved entry (now active), so a bad
									-- token or model surfaces here with its
									-- server message instead of mid-typing. A
									-- declined offer keeps the save.
									if probe_offer_accepted() then
										local spec = api_remote.get_test_request_spec and api_remote.get_test_request_spec() or nil
										if type(spec) ~= "table" then
											Logger.error(LOG, "API test refused: shared test-request spec unavailable.")
										else
											Logger.info(LOG, "API test dispatched for '%s' (model %s).",
												new_name, tostring(new_entry.model or ""))
											api_remote.test_request(new_entry, spec,
												function(reply, ms)
													notify_probe_verdict(true, new_name, reply, ms, nil)
												end,
												function(_, detail)
													notify_probe_verdict(false, new_name, "", 0, detail)
												end)
										end
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
							rollback_validation("unreachable", "probe rejected credentials")
						end,
						function(reason)
							rollback_validation("cancelled", reason)
						end)
					end, debug.traceback)
					if not validation_call_ok or validation_result ~= true then
						rollback_validation(validation_call_ok and "refused" or "raised",
							validation_result)
					end
			end or nil,
			})
		end
	end

	local add_controls = ManifestMenu.template_rows("llm_api_add_provider_group", {}, {
		llm_api_add_group_ready = function() return not paused and not mutation_busy end,
	}, { api_add_entry = add_rows })
	if not add_controls then return nil, nil end
	for _, row in ipairs(add_controls) do
		row.label = "➕ " .. row.label
		table.insert(rows, row)
	end

	-- Add sits before the separator so creating an entry is one glance
	-- away; the separator only appears with the management rows below,
	-- never dangling when no entry exists.
	if #entries > 0 then
		local separators = ManifestMenu.template_rows("llm_api_add_separator", {}, {}, {})
		if not separators then return nil, nil end
		for _, row in ipairs(separators) do table.insert(rows, row) end
	end


	-- The active entry is shared by the management rows below (Test,
	-- Remove): resolve it once so the two cannot disagree mid-build.
	local active_entry = api_remote and api_remote.get_active_entry() or nil
	local active_label = active_entry and (names[active_entry.id] or "") or ""
	local function active_commands_ready()
		return native_unpaused() and _mutation_owner == nil and active_entry ~= nil
			and api_remote.get_active_entry_id() == active_entry.id
	end



	-- =====================================================
	-- ===== 1.3) Test active entry =====
	-- =====================================================

	-- Sends the shared minimal probe to the active entry and surfaces the
	-- verdict. Unlike the add-time availability ping this proves the full
	-- path: credentials, model id and body format. No entry state is mutated,
	-- so no mutation lease is taken; a mid-flight entry change or delete
	-- discards the verdict instead of relabelling it.
	if active_entry then
		table.insert(rows, { separator = true })
	end
	local test_row = ManifestMenu.command_row("llm_api_active_commands", "api_test_active", {
		api_test_active = function()
			local probed_id = active_entry.id
			local probed_label = active_label
			local probed_entry = {
				id       = active_entry.id,
				provider = active_entry.provider,
				base_url = active_entry.base_url,
				token    = active_entry.token,
				model    = active_entry.model,
			}
			local spec = api_remote.get_test_request_spec and api_remote.get_test_request_spec() or nil
			if type(spec) ~= "table" then
				Logger.error(LOG, "API test refused: shared test-request spec unavailable.")
				pcall_log("notify(api_test_no_spec)", notifications.notify,
					i18n.get("menu.llm.api_test_entry"),
					i18n.get("menu.llm.api_providers_unavailable"), "error")
				return false
			end
			-- Logged before dispatch, not after: if the click reaches this
			-- action there is always exactly one line proving it, so a silent
			-- menu click can be told apart from a handler failure.
			Logger.info(LOG, "API test dispatched for '%s' (model %s).",
				probed_label, tostring(probed_entry.model or ""))
			local call_ok, dispatched = xpcall(function()
				return api_remote.test_request(probed_entry, spec,
					function(reply, ms)
						if api_remote.get_active_entry_id() ~= probed_id then return end
						local still_there = false
						for _, e in ipairs(api_remote.get_entries() or {}) do
							if e.id == probed_id then still_there = true; break end
						end
						if not still_there then return end
						notify_probe_verdict(true, probed_label, reply, ms, nil)
					end,
					function(_reason, detail)
						if api_remote.get_active_entry_id() ~= probed_id then return end
						notify_probe_verdict(false, probed_label, "", 0, detail)
					end)
			end, debug.traceback)
			if not call_ok or dispatched ~= true then
				Logger.error(LOG, "API test dispatch failed: %s", tostring(dispatched))
				return false
			end
			return true
		end,
	}, { llm_api_active_ready = active_commands_ready })


	-- =====================================================
	-- ===== 1.4) Remove active entry =====
	-- =====================================================

	-- Remove only the active entry — keeps the action unambiguous and mirrors
	-- the AHK tray's "remove active" semantics. Disabled when nothing is
	-- configured so the user does not chase a no-op click. Test sits above
	-- it: the destructive action stays last.
	local remove_row = ManifestMenu.command_row("llm_api_active_commands", "api_remove_active", {
		api_remove_active = function()
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
			if not active_commands_ready() then return false end
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
		end,
	}, { llm_api_active_ready = active_commands_ready })
	if remove_row then
		remove_row.label = "🗑️ " .. remove_row.label .. (active_entry and (" (" .. active_label .. ")") or "")
	end
	local active_rows = { api_test_active = test_row, api_remove_active = remove_row }
	for _, declaration in ipairs(ManifestMenu.get_array("llm_api_active_commands")) do
		local row = active_rows[declaration.id]
		if row then
			-- Preserve the native disabled-row ABI; retained live actions still recheck readiness.
			if row.disabled then row.action = nil end
			table.insert(rows, row)
		end
	end


	-- =====================================================
	-- ===== 1.5) System 1-only entries =====
	-- =====================================================

	-- A decisions provider (Jev) serves the agent's System 1 only: its
	-- entries are in no picker, so each gets its own Test and Remove rows
	local system1_rows = {}
	for _, e in ipairs(entries) do
		if is_system1_only(api_remote, e) and e.id ~= (active_entry and active_entry.id) then
			for _, row in ipairs(system1_entry_rows(ctx, api_remote, e, paused or mutation_busy, names[e.id])) do
				system1_rows[#system1_rows + 1] = row
			end
		end
	end
	if #system1_rows > 0 then
		table.insert(rows, { separator = true })
		for _, row in ipairs(system1_rows) do table.insert(rows, row) end
	end


	-- =====================================================
	-- ===== 1.6) Build parent row title =====
	-- =====================================================

	-- The name already starts with the provider: it is not repeated.
	local api_title = "API — " .. (active_entry and active_label or i18n.get("menu.llm.api_no_entry"))

	return api_title, ManifestMenu.render_rows(rows, "llm_backend")
end

--- Builds the "active model" submenu when the remote API backend is selected.
--- Mirrors Windows ``_LLM_Menu_BuildApiEntriesMenu()`` — local catalogue rows
--- are hidden because they have no ``urls.api`` entry in models.json.
--- @param ctx table Context with fields: state, paused, is_paused, keymap, update_menu, WarmupCtrl.
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
	local names      = entry_names(api_remote, entries)

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
		if not is_system1_only(api_remote, e) then
			table.insert(rows, {
				label    = names[e.id],
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
	end

	return ManifestMenu.render_rows(rows, "llm_model")
end

--- Stores what the user chose for a local server (local_servers.json): its
--- address, its key or its model, in the one API entry the server has. Before
--- a model is chosen there is no entry: the address and the key wait in
--- modules/llm/local_servers.lua. Choosing a model creates or updates the
--- entry, makes it the active one and warms it up when the API backend is
--- selected; a refused persistence restores the previous entries.
--- @param ctx table { state, keymap, update_menu, WarmupCtrl }.
--- @param server_id string A local server id.
--- @param fields table { base_url = string|nil, token = string|nil, model = string|nil }.
--- @param on_done function|nil Receives (committed) once settled.
--- @return boolean started False when another entry change is in flight.
function M.apply_local_server(ctx, server_id, fields, on_done)
	local api_remote = llm_mod.api_remote
	if not api_remote.is_local_server(server_id) or type(fields) ~= "table" then
		error("api_panel.apply_local_server: a local server id and fields are required")
	end
	local LocalServers = require("modules.llm.local_servers")
	local function done(committed)
		if type(on_done) == "function" then pcall_log("apply_local_server(on_done)", on_done, committed) end
	end
	if _mutation_owner ~= nil then return false end
	local provider = api_remote.PROVIDERS[server_id]
	local existing = api_remote.local_server_entry(server_id)
	fields = { base_url = fields.base_url, token = fields.token, model = fields.model }
	-- The default address is stored as "", so a catalogue change reaches the entry
	if fields.base_url == provider.base_url then fields.base_url = "" end
	if not existing and fields.model == nil then
		LocalServers.set_pending(server_id, fields)
		done(true)
		return true
	end

	local pending = LocalServers.pending(server_id)
	local entry = {
		id       = existing and existing.id or ("local-" .. server_id),
		provider = server_id,
		base_url = existing and existing.base_url or pending.base_url or "",
		token    = existing and existing.token or pending.token or "",
		model    = existing and existing.model or "",
	}
	for _, key in ipairs({ "base_url", "token", "model" }) do
		if fields[key] ~= nil then entry[key] = fields[key] end
	end
	local previous_entries = {}
	local staged = {}
	for _, e in ipairs(api_remote.get_entries() or {}) do
		previous_entries[#previous_entries + 1] = e
		if e ~= existing then staged[#staged + 1] = e end
	end
	staged[#staged + 1] = entry

	local state = ctx.state
	local previous_active_id = api_remote.get_active_entry_id()
	local previous_model = state.llm_model
	local becomes_active = fields.model ~= nil or (existing ~= nil and existing.id == previous_active_id)
	-- New entries retire the API backend's predictions and readiness: only a
	-- selected API backend has them to retire, a model slot to follow the
	-- entry and a warmup to redo; otherwise the backend switch owns all three
	local serving = state.llm_backend == "api"
	if serving and reset_prediction_identity(ctx.keymap, "apply local server entry") ~= true then
		return false
	end
	local my_generation = begin_mutation()
	if not my_generation then return false end
	api_remote.set_entries(staged)
	if becomes_active then api_remote.set_active_entry_id(entry.id) end
	if serving and becomes_active then state.llm_model = entry.model end
	-- A key the user removed leaves no Keychain item behind
	local cleared_key = existing ~= nil and (existing.token or "") ~= "" and entry.token == ""
	persist_entries("persist_api_entries(local server)", function(ok, reason, durable)
		if not mutation_is_current(my_generation) then return end
		finish_mutation(my_generation)
		if ok == true or durable == true then
			if ok ~= true then
				Logger.error(LOG, "Local server entry committed with cleanup debt: %s", tostring(reason))
			end
			LocalServers.clear_pending(server_id)
			Logger.info(LOG, "Local server '%s' entry stored (model %s).", server_id, entry.model)
			if serving and ctx.WarmupCtrl then ctx.WarmupCtrl.warmup("local_server") end
			pcall_log("update_menu(local server)", ctx.update_menu)
			done(true)
			return
		end
		api_remote.set_entries(previous_entries)
		api_remote.set_active_entry_id(previous_active_id)
		state.llm_model = previous_model
		notify_persistence_failure("Local server entry")
		pcall_log("update_menu(local server rollback)", ctx.update_menu)
		done(false)
	end, cleared_key and { delete_entry_ids = { entry.id } } or nil)
	return true
end

return M
