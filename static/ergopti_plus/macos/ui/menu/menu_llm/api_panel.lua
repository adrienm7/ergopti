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

local LOG = "api_panel"

-- Monotone counter for unique entry IDs.  os.time() alone has 1-second
-- resolution, so two entries created within the same second get the same id.
-- The seq suffix makes every id distinct regardless of wall-clock resolution.
local _entry_seq = 0

-- Monotone counter for add-entry validation probes.  A probe started for entry
-- A that resolves after the user has already selected entry B must not revert
-- the active selection back to pre-A.  Callbacks capture their own gen and
-- bail out when the global has moved on.
local _add_gen = 0

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





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Builds the API entries submenu and returns the title string and menu table.
--- Only call when state.llm_backend == "api" — returns nil, nil otherwise.
--- @param ctx table Context with fields: state, paused, update_menu, WarmupCtrl.
--- @return string|nil title   Title string for the parent row, or nil.
--- @return table|nil  menu    Populated api_menu table, or nil.
function M.build(ctx)
	local state       = ctx.state
	local paused      = ctx.paused
	local update_menu = ctx.update_menu
	local WarmupCtrl  = ctx.WarmupCtrl

	if state.llm_backend ~= "api" then
		return nil, nil
	end

	local api_remote = llm_mod.api_remote
	local entries    = (api_remote and api_remote.get_entries()) or {}
	local active_id  = (api_remote and api_remote.get_active_entry_id()) or ""
	local api_menu   = {}


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
		table.insert(api_menu, {
			title    = entry_title,
			checked  = (e.id == active_id),
			disabled = paused or nil,
			fn       = not paused and function()
				api_remote.set_active_entry_id(e.id)
				pcall_log("persist_api_entries(set_active)", llm_mod.persist_api_entries)
				WarmupCtrl.warmup("api_set_active")
				update_menu()
			end or nil
		})
	end

	if #entries > 0 then
		table.insert(api_menu, { title = "-" })
	end


	-- =====================================================
	-- ===== 1.2) Add entry =====
	-- =====================================================

	-- One "Add" entry per provider so the user picks the shape first
	-- (Bearer auth vs x-api-key vs Gemini's URL token, plus the right
	-- default model). Subsequent prompts collect the credentials.
	local add_submenu = {}
	for _, pid in ipairs(api_remote.PROVIDER_ORDER) do
		local p = api_remote.PROVIDERS[pid]
		if p then
			table.insert(add_submenu, {
				title    = string.format("➕ %s", p.label),
				disabled = paused or nil,
				fn       = not paused and function()
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
					local list = api_remote.get_entries() or {}
					local clone = {}
					for _, x in ipairs(list) do table.insert(clone, x) end
					table.insert(clone, new_entry)
					-- Stage in memory only — DO NOT persist yet. check_availability
					-- needs an active entry to probe credentials against, but we
					-- don't want to write a bad token into the Keychain. Persist only
					-- on success; on failure, roll the in-memory state back.
					api_remote.set_entries(clone)
					api_remote.set_active_entry_id(id)
					update_menu()
					-- Capture generation so a stale callback for a superseded add
					-- does not clobber the active selection made after this one.
					_add_gen = _add_gen + 1
					local my_add_gen = _add_gen
					api_remote.check_availability(new_entry.model,
						function()
							if my_add_gen ~= _add_gen then return end
							-- Credentials accepted — NOW persist + warmup.
							pcall_log("persist_api_entries(add_entry_ok)", llm_mod.persist_api_entries)
							WarmupCtrl.warmup("api_add_entry")
							pcall_log("notify(api_validated)", notifications.notify,
								i18n.get("menu.llm.api_validated_title"),
								string.format(i18n.get("menu.llm.api_validated_body"), new_entry.label),
								"success")
						end,
						function(_unreachable)
							if my_add_gen ~= _add_gen then return end
							-- Validation failed: roll the in-memory list back so the
							-- bogus token never lands in Keychain. Only revert the
							-- active selection if it has not been changed by the user
							-- since this probe was launched.
							local rolled = {}
							for _, x in ipairs(api_remote.get_entries() or {}) do
								if x.id ~= id then table.insert(rolled, x) end
							end
							api_remote.set_entries(rolled)
							local cur_id = api_remote.get_active_entry_id and api_remote.get_active_entry_id() or ""
							if cur_id == id then
								api_remote.set_active_entry_id(previous_active_id)
							end
							pcall_log("notify(api_unreachable)", notifications.notify,
								i18n.get("menu.llm.api_unreachable_title"),
								string.format(i18n.get("menu.llm.api_unreachable_body"), new_entry.label),
								"warning")
							pcall_log("update_menu(rollback)", update_menu)
						end)
				end or nil,
			})
		end
	end

	table.insert(api_menu, {
		title    = "➕ " .. i18n.get("menu.llm.api_add_entry"),
		disabled = paused or nil,
		menu     = add_submenu,
	})


	-- =====================================================
	-- ===== 1.3) Remove active entry =====
	-- =====================================================

	-- Remove only the active entry — keeps the action unambiguous and mirrors
	-- the AHK tray's "remove active" semantics. Disabled when nothing is
	-- configured so the user does not chase a no-op click.
	local active_entry = api_remote and api_remote.get_active_entry() or nil
	local active_label = active_entry and (active_entry.label or active_entry.id or "") or ""
	table.insert(api_menu, {
		title    = active_entry
			and string.format("🗑️ %s (%s)", i18n.get("menu.llm.api_remove_entry"), active_label)
			or  "🗑️ " .. i18n.get("menu.llm.api_remove_entry"),
		disabled = (paused or (active_entry == nil)) or nil,
		fn       = (not paused and active_entry) and function()
			-- Confirm before destroying — the saved token is gone for good once
			-- we delete it. Worth one extra click in a small menu.
			local ok_c, choice = pcall(dialog.block_alert,
				string.format(i18n.get("menu.llm.api_remove_confirm_title"), active_label),
				i18n.get("menu.llm.api_remove_confirm_body"),
				i18n.get("button.delete"), i18n.get("button.cancel"), "critical")
			if not (ok_c and choice == i18n.get("button.delete")) then
				return
			end
			local kept = {}
			for _, x in ipairs(api_remote.get_entries() or {}) do
				if x.id ~= active_entry.id then table.insert(kept, x) end
			end
			api_remote.set_entries(kept)
			api_remote.set_active_entry_id(kept[1] and kept[1].id or "")
			pcall_log("persist_api_entries(delete)", llm_mod.persist_api_entries)
			-- Purge the Keychain entry too; without this, deleted entries leave
			-- their token in the user's Keychain indefinitely.
			local ok_kc, TokenCrypto = pcall(require, "modules.llm.api_token_crypto")
			if ok_kc and TokenCrypto and active_entry.id then
				pcall_log("TokenCrypto.delete", TokenCrypto.delete, active_entry.id)
			end
			WarmupCtrl.warmup("api_delete_entry")
			update_menu()
		end or nil,
	})


	-- =====================================================
	-- ===== 1.4) Build parent row title =====
	-- =====================================================

	local api_title = active_entry
		and string.format("API — %s (%s)", active_label,
			(api_remote.PROVIDERS[active_entry.provider] and api_remote.PROVIDERS[active_entry.provider].label) or active_entry.provider)
		or  "API — " .. i18n.get("menu.llm.api_no_entry")

	return api_title, api_menu
end

--- Builds the "active model" submenu when the remote API backend is selected.
--- Mirrors Windows ``_LLM_Menu_BuildApiEntriesMenu()`` — local catalogue rows
--- are hidden because they have no ``urls.api`` entry in models.json.
--- @param ctx table Context with fields: state, paused, update_menu, WarmupCtrl.
--- @return table menu Populated API entry picker.
function M.build_model_picker(ctx)
	local state       = ctx.state
	local paused      = ctx.paused
	local update_menu = ctx.update_menu
	local WarmupCtrl  = ctx.WarmupCtrl

	local api_remote = llm_mod.api_remote
	local entries    = (api_remote and api_remote.get_entries()) or {}
	local active_id  = (api_remote and api_remote.get_active_entry_id()) or ""
	local menu       = {}

	table.insert(menu, {
		title   = i18n.get("menu.llm.no_model"),
		checked = (active_id == "" or active_id == nil),
		disabled = paused or nil,
		fn      = not paused and function()
			if api_remote and api_remote.set_active_entry_id then
				api_remote.set_active_entry_id("")
				state.llm_model = ""
				pcall_log("persist_api_entries(clear_active)", llm_mod.persist_api_entries)
				WarmupCtrl.warmup("api_clear_active")
				update_menu()
			end
		end or nil,
	})

	if #entries > 0 then
		table.insert(menu, { title = "-" })
	end

	for _, e in ipairs(entries) do
		local provider_label = (api_remote.PROVIDERS[e.provider] and api_remote.PROVIDERS[e.provider].label) or e.provider
		local entry_title = string.format("%s — %s (%s)",
			tostring(e.label or e.id or "?"),
			tostring(e.model or "?"),
			provider_label)
		table.insert(menu, {
			title    = entry_title,
			checked  = (e.id == active_id),
			disabled = paused or nil,
			fn       = not paused and function()
				api_remote.set_active_entry_id(e.id)
				state.llm_model = tostring(e.model or "")
				pcall_log("persist_api_entries(set_active)", llm_mod.persist_api_entries)
				WarmupCtrl.warmup("api_set_active")
				update_menu()
			end or nil,
		})
	end

	return menu
end

return M
