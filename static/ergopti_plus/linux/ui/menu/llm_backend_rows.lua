--- ui/menu/llm_backend_rows.lua

--- ==============================================================================
--- MODULE: AI Backend Choice (Linux)
--- DESCRIPTION:
--- Who answers a prediction: the local Ollama, or a hosted API (Cerebras,
--- OpenAI, Mistral, …) entered by the user. The tray shows one button with the
--- backend's emoji and the model (caption); the model selector page lists the
--- API entries and providers (api_page). Mirrors the macOS backend and API
--- panels, with the same translated labels and the same shared probe.
---
--- FEATURES & RATIONALE:
--- 1. The tray builds no list (maintainer, 2026-10-27): the page offers the
---    entries, the providers and the local servers, and runs these actions.
--- 2. Adding an API asks for the key in a hidden zenity entry, stores it in the
---    private entries file, selects it, then tests it at once so a wrong key is
---    reported while the user is still looking, with the provider's own reason.
--- 3. Dialogs are handed in by the menu builder, so this module never opens a
---    window the keyboard grab would starve (ui/modal.lua).
--- 4. A provider that is no chat model (Jev, for the agent's System 1 only) is
---    offered for its key like any other, but its entry never becomes the
---    predictions' one: it is listed with its own test and removal, and adding
---    it keeps the entry predictions already use.
--- 5. Every entry reads <provider>/<model>, told apart by host then order when
---    two share it (_shared/lua/llm/api_entry_names.lua), on every driver. The
---    label an entry stores is written for older builds and never read.
--- ==============================================================================

local M = {}
local TextUtils = require("text_utils")

local Logger = require("logger.shim")
local EntryNames = require("llm.api_entry_names")
local BackendBrands = require("modules.llm.backend_brands")

local LOG = "ui.menu.llm_backend_rows"
-- The characters of a test reply shown in the verdict, as on macOS.
local TEST_REPLY_PREVIEW = 120

--- A translated string, or its key when the catalogue cannot answer.
--- @param key string
--- @return string
local function tr(key)
	local ok, i18n = pcall(require, "infra.i18n")
	local value = ok and type(i18n.get) == "function" and i18n.get(key) or nil
	return type(value) == "string" and value ~= "" and value or key
end

--- Replaces {1}, {2}, … with values, without reading "%" in them.
--- @param template string
--- @param values table
--- @return string
local function fill(template, values)
	return (template:gsub("{(%d+)}", function(index) return tostring(values[tonumber(index)] or "") end))
end

--- The automatic name of every entry, by id: <provider>/<model>, with the
--- model and address its requests use.
--- @param remote table api_remote
--- @param list table The entries, in their order.
--- @return table names Entry id -> name.
local function entry_names(remote, list)
	local resolved = {}
	for index, entry in ipairs(list) do
		local provider = remote.provider(entry.provider) or {}
		resolved[index] = {
			provider = entry.provider,
			model = entry.model ~= "" and entry.model or (provider.default_model or ""),
			base_url = entry.base_url ~= "" and entry.base_url or (provider.base_url or ""),
		}
	end
	local names = {}
	for index, name in ipairs(EntryNames.names(resolved)) do names[list[index].id] = name end
	return names
end

--- Reports a test verdict.
--- @param dialogs table
--- @param name string The entry's automatic name.
--- @param ok boolean
--- @param detail string
--- @param elapsed_ms number
local function report_test(dialogs, name, ok, detail, elapsed_ms)
	if ok then
		local reply = tostring(detail or "")
		if #reply > TEST_REPLY_PREVIEW then reply = reply:sub(1, TEST_REPLY_PREVIEW) .. "..." end
		dialogs.info(tr("menu.llm.api_test_ok_title"),
			fill(tr("menu.llm.api_test_ok_body"), { name, math.floor(elapsed_ms or 0), reply }))
		return
	end
	local body = (tr("menu.llm.api_unreachable_body"):gsub("%%s", function() return name end))
	dialogs.error(body .. "\n" .. tostring(detail or ""), tr("menu.llm.api_unreachable_title"))
end

--- Tests one entry and reports the verdict when the answer arrives.
--- @param remote table api_remote
--- @param dialogs table
--- @param entry table
--- @param name string The entry's automatic name.
--- @param admit function|nil Exact source-bound runtime admission.
local function run_test(remote, dialogs, entry, name, admit)
	local function allowed()
		if admit == nil then return true end
		local ok, value = pcall(admit)
		return ok and value == true
	end
	if not allowed() then return false end
	local dispatched = remote.test(entry, function(ok, detail, elapsed_ms)
		if not allowed() then return end
		Logger.info(LOG, "API test of '%s': %s.", name, ok and "answered" or "failed")
		if not allowed() then return end
		report_test(dialogs, name, ok, detail, elapsed_ms)
	end, admit)
	if not dispatched then Logger.warn(LOG, "API test of '%s' could not be sent.", name) end
	return dispatched
end

--- Asks for a provider's key (and URL and model where needed), stores the
--- entry under the already-selected API backend and tests it.
--- @param llm table Prediction engine.
--- @param remote table api_remote
--- @param entries table api_entries
--- @param dialogs table { prompt, error, info }
--- @param provider table
--- @param on_changed function|nil
local function add_entry(llm, remote, entries, dialogs, provider, on_changed)
	local heading = tr("menu.llm.api_dialog_title") .. " — " .. provider.label
	local base_url = ""
	-- OpenAI selects the wire schema, not a fixed host. Keep its declared
	-- default visible while allowing the same custom endpoint as the generic form.
	if provider.base_url == "" or provider.id == "openai" then
		base_url = dialogs.prompt(heading, tr("menu.llm.api_prompt_url"), provider.base_url)
		if not base_url or base_url == "" then return end
		if not remote.normalize_base_url(base_url) then
			dialogs.error(tr("menu.llm.api_prompt_url") .. " " .. base_url, heading)
			return
		end
	end
	local prompt = type(remote.token_allowed) == "function" and remote.token_allowed(provider.id, "", base_url) == true
		and fill(tr("dialog.local_servers.key_prompt"), { provider.label }) or tr("menu.llm.api_prompt_token")
	local token = dialogs.prompt(heading, prompt, "", true)
	if not token then return end
	-- The actual provider owns optional authentication; never trim secret bytes.
	if token == "" and (type(remote.token_allowed) ~= "function"
		or remote.token_allowed(provider.id, token, base_url) ~= true) then return end
	local model = dialogs.prompt(heading, tr("menu.llm.api_prompt_model"), provider.default_model)
	if not model then return end
	model = TextUtils.trim(model)
	if model == "" then model = provider.default_model end
	if model == "" then return end

	local chat = remote.serves(provider.id, "chat")
	local ticket, current, finish
	if chat then
		local begin = llm.begin_api_selection
		current, finish = llm.api_selection_is_current, llm.finish_api_selection
		if type(begin) ~= "function" or type(current) ~= "function" or type(finish) ~= "function" then
			dialogs.error(tr("dialog.bulk_toggle.save_failed"), heading)
			return false
		end
		local captured, receipt = pcall(begin)
		if not captured or type(receipt) ~= "table" then
			dialogs.error(tr("dialog.bulk_toggle.save_failed"), heading)
			return false
		end
		ticket = receipt
	end
	local function admitted()
		local ok, value = pcall(current, ticket)
		return ok and value == true
	end
	-- The label is required by the builds before 2026-10 that read this file;
	-- it holds the automatic name and no tray reads it.
	local called, entry, _, settled, source = pcall(entries.add, {
		provider = provider.id,
		token = token,
		label = provider.id .. "/" .. model,
		model = model ~= provider.default_model and model or "",
		base_url = base_url,
	}, chat, chat and admitted or nil)
	if chat then
		local retired, ack = pcall(finish, ticket, called and type(entry) == "table", called and settled == true)
		if not retired or ack ~= true then
			dialogs.error(tr("dialog.bulk_toggle.save_failed"), heading)
			return false
		end
	end
	if not called or not entry then
		dialogs.error(tr("dialog.bulk_toggle.save_failed"), heading)
		return false
	end
	local function published_current()
		if not admitted() then return false end
		local checked, fresh = pcall(current, ticket, function()
			return entries.source_is_current(source) == true and entries.active() == entry
		end)
		return checked and fresh == true
	end
	if chat and not published_current() then return false end
	if not chat then
		-- Only the agent's System 1 reads this key: predictions keep their entry.
		Logger.info(LOG, "API entry '%s' serves the agent's System 1 only; predictions keep their entry.",
			entry.id)
	end
	if type(on_changed) == "function" then on_changed() end
	if chat and not published_current() then return false end
	return run_test(remote, dialogs, entry, entry_names(remote, entries.list())[entry.id], chat and published_current or nil)
end

--- The name of the model that answers predictions: the active API entry's
--- automatic name under the API backend, as macOS and Windows show it, else
--- Ollama's model.
--- @param llm table Prediction engine.
--- @param backend string The selected backend.
--- @param remote table|nil The api_remote module, nil when it cannot load.
--- @param entries table|nil The API entries module, nil when it cannot load.
--- @return string|nil name Nil when no model is selected.
local function selected_model_name(llm, backend, remote, entries)
	if backend == "api" then
		-- The button names the provider by its display name, then the model
		-- its requests use; the page lists entries by their automatic name.
		local active = entries and entries.active() or nil
		if type(active) ~= "table" or not remote then return nil end
		local provider = remote.provider(active.provider)
		if type(provider) ~= "table" or type(provider.label) ~= "string" or provider.label == "" then return nil end
		local model = (type(active.model) == "string" and active.model ~= "") and active.model or provider.default_model
		if type(model) ~= "string" or model == "" then return provider.label end
		return provider.label .. "/" .. model
	end
	local model = type(llm.get_current_model) == "function" and llm.get_current_model() or nil
	return type(model) == "string" and model ~= "" and model or nil
end

--- The tray's model button: the backend's emoji, then the model that answers
--- ("🦙 qwen3:4b", "🌐 OpenAI/gpt-4o-mini"), from the shared brand table.
--- @param llm table Prediction engine (get_backend, get_current_model).
--- @return string caption
function M.caption(llm)
	local backend = type(llm.get_backend) == "function" and llm.get_backend() or "ollama"
	local ok_remote, remote = pcall(require, "modules.llm.api_remote")
	local ok_entries, entries = pcall(require, "modules.llm.api_entries")
	local selected = selected_model_name(llm, backend, ok_remote and remote or nil, ok_entries and entries or nil)
	return BackendBrands.selector_caption(backend, selected or tr("menu.llm.no_model_none"))
end

--- Binds the model selector page to this tray build: the engine, the dialogs
--- its transactions open, and the refresh after a change.
--- @param llm table Prediction engine.
--- @param options table { dialogs, on_changed, delete_model, context }
function M.bind_page(llm, options)
	require("ui.model_browser.bridge").bind({
		llm = llm, dialogs = options.dialogs, on_changed = options.on_changed,
		delete_model = options.delete_model, context = options.context,
	})
end

--- The API group of the model selector page: one row per saved entry, the
--- providers an entry can be added for, the local servers that answer, and
--- their tools. Each `run` is this module's own transaction (the tray's former
--- API rows); the page bridge keeps it and sends the page the rest.
--- @param llm table Prediction engine.
--- @param dialogs table { prompt, error, info, confirm }
--- @param on_changed function|nil Called after a change (menu and page refresh).
--- @param context table|nil { paused, is_paused } for the local servers.
--- @return table api { rows, providers, tools }
function M.api_page(llm, dialogs, on_changed, context)
	local function changed() if type(on_changed) == "function" then on_changed() end end
	local ok_remote, remote = pcall(require, "modules.llm.api_remote")
	local ok_entries, entries = pcall(require, "modules.llm.api_entries")
	local api = { rows = {}, providers = {}, tools = {} }
	if not ok_remote or not ok_entries then
		Logger.error(LOG, "Remote API modules unavailable — the page lists no API entry.")
		return api
	end
	--- Runs one API transaction under the API backend, selecting it first.
	local function under_api(fn)
		if llm.get_backend() ~= "api" and llm.set_backend("api") ~= true then return false end
		return fn()
	end
	local active = entries.active()
	local list = entries.list()
	local names = entry_names(remote, list)
	local active_name = active and names[active.id] or nil
	--- The entry the page was drawn with is still the active one.
	local function active_commands_ready()
		local current = entries.active()
		return active ~= nil and current ~= nil and current.id == active.id
	end
	for _, entry in ipairs(list) do
		local label = names[entry.id]
		local chat = remote.serves(entry.provider, "chat")
		local is_active = chat and active ~= nil and entry.id == active.id
		local actions = {}
		if is_active then
			-- The active entry's Test and Remove, as the tray drew them: each
			-- rechecks that the entry is still the active one, and Remove
			-- retires the running request (set_backend) before deleting it.
			actions[1] = { id = "test", text = tr("menu.llm.api_test_entry"), run = function()
				if not active_commands_ready() then return false end
				return run_test(remote, dialogs, active, active_name)
			end }
			actions[2] = { id = "remove", text = tr("menu.llm.api_remove_entry"), run = function()
				local heading = (tr("menu.llm.api_remove_confirm_title"):gsub("%%s", function() return active_name end))
				if dialogs.confirm(heading, tr("menu.llm.api_remove_confirm_body")) ~= true then return false end
				if not active_commands_ready() then return false end
				if llm.set_backend("api") ~= true or not active_commands_ready() then return false end
				if entries.remove(active.id) ~= true then return false end
				changed()
				return true
			end }
		elseif not chat then
			-- Never the predictions' entry: its own test and removal instead.
			actions[1] = { id = "test", text = tr("menu.llm.api_test_entry"),
				run = function() return run_test(remote, dialogs, entry, label) end }
			actions[2] = { id = "remove", text = tr("menu.llm.api_remove_entry"), run = function()
				local heading = (tr("menu.llm.api_remove_confirm_title"):gsub("%%s", function() return label end))
				if dialogs.confirm(heading, tr("menu.llm.api_remove_confirm_body")) ~= true then return false end
				if entries.remove(entry.id) ~= true then return false end
				changed()
				return true
			end }
		end
		api.rows[#api.rows + 1] = {
			name = label, runtime_name = entry.model, provider = entry.provider, installed = true,
			-- A provider that is no chat model never answers predictions.
			available = chat or false, current = is_active, actions = actions,
			-- Selecting goes through set_backend("api") even under the API
			-- backend: it retires the running request of the previous entry.
			run = chat and function()
				if llm.set_backend("api") ~= true then return false end
				if entries.set_active(entry.id) ~= true then
					dialogs.error(tr("dialog.bulk_toggle.save_failed"), tr("common.error_title"))
					return false
				end
				changed()
				return true
			end or nil,
		}
	end
	for _, provider in ipairs(remote.providers()) do
		local function add() return add_entry(llm, remote, entries, dialogs, provider, on_changed) end
		api.providers[#api.providers + 1] = { id = provider.id, label = provider.label, run = function()
			-- A chat key becomes the predictions' entry, under the API backend;
			-- a System 1 key leaves the backend as it is.
			if remote.serves(provider.id, "chat") then return under_api(add) end
			return add()
		end }
	end
	if type(context) == "table" and type(context.is_paused) == "function"
		and type(llm.can_configure_local_servers) == "function" then
		local rows, tools = require("ui.menu.local_server_rows").page_rows(llm, dialogs, changed, context)
		for _, row in ipairs(rows) do api.rows[#api.rows + 1] = row end
		for _, tool in ipairs(tools) do api.tools[#api.tools + 1] = tool end
	end
	return api
end

return M
