--- ui/menu/llm_backend_rows.lua

--- ==============================================================================
--- MODULE: AI Backend Rows (Linux tray)
--- DESCRIPTION:
--- The rows of the AI "Models" list that choose who answers a prediction: the
--- local Ollama, or a hosted API (Cerebras, OpenAI, Mistral, …) entered by the
--- user. Mirrors the macOS backend and API panels, with the same translated
--- labels and the same shared connectivity probe.
---
--- FEATURES & RATIONALE:
--- 1. Row data only: the shared renderer draws it, like every other list.
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

local Logger = require("logger.shim")
local EntryNames = require("llm.api_entry_names")
local ManifestMenu = require("infra.manifest_menu")

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
local function run_test(remote, dialogs, entry, name)
	local dispatched = remote.test(entry, function(ok, detail, elapsed_ms)
		Logger.info(LOG, "API test of '%s': %s.", name, ok and "answered" or "failed")
		report_test(dialogs, name, ok, detail, elapsed_ms)
	end)
	if not dispatched then Logger.warn(LOG, "API test of '%s' could not be sent.", name) end
	return dispatched
end

--- Asks for a provider's key (and URL and model where needed), stores the
--- entry, selects the API backend and tests it.
--- @param llm table Prediction engine.
--- @param remote table api_remote
--- @param entries table api_entries
--- @param dialogs table { prompt, error, info }
--- @param provider table
--- @param on_changed function|nil
local function add_entry(llm, remote, entries, dialogs, provider, on_changed)
	local heading = tr("menu.llm.api_dialog_title") .. " — " .. provider.label
	local base_url = ""
	-- Only the generic OpenAI-compatible entry has no URL of its own.
	if provider.base_url == "" then
		base_url = dialogs.prompt(heading, tr("menu.llm.api_prompt_url"), "")
		if not base_url or base_url == "" then return end
		if not remote.normalize_base_url(base_url) then
			dialogs.error(tr("menu.llm.api_prompt_url") .. " " .. base_url, heading)
			return
		end
	end
	local prompt = type(remote.token_allowed) == "function" and remote.token_allowed(provider.id, "") == true
		and fill(tr("dialog.local_servers.key_prompt"), { provider.label }) or tr("menu.llm.api_prompt_token")
	local token = dialogs.prompt(heading, prompt, "", true)
	if not token then return end
	-- The actual provider owns optional authentication; never trim secret bytes.
	if token == "" and (type(remote.token_allowed) ~= "function"
		or remote.token_allowed(provider.id, token) ~= true) then return end
	local model = dialogs.prompt(heading, tr("menu.llm.api_prompt_model"), provider.default_model)
	if not model then return end
	model = model:match("^%s*(.-)%s*$")
	if model == "" then model = provider.default_model end
	if model == "" then return end

	local chat = remote.serves(provider.id, "chat")
	local previous = entries.active()
	-- The label is required by the builds before 2026-10 that read this file;
	-- it holds the automatic name and no tray reads it.
	local entry, err = entries.add({
		provider = provider.id,
		token = token,
		label = provider.id .. "/" .. model,
		model = model ~= provider.default_model and model or "",
		base_url = base_url,
	})
	if not entry then
		dialogs.error(tostring(err), heading)
		return
	end
	if chat then
		llm.set_backend("api")
	else
		-- Only the agent's System 1 reads this key: predictions keep their entry.
		Logger.info(LOG, "API entry '%s' serves the agent's System 1 only; predictions keep their entry.",
			entry.id)
		if previous and entries.set_active(previous.id) ~= true then
			Logger.error(LOG, "The predictions' API entry '%s' could not be selected again.", previous.id)
		end
	end
	if type(on_changed) == "function" then on_changed() end
	run_test(remote, dialogs, entry, entry_names(remote, entries.list())[entry.id])
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
		local active = entries and entries.active() or nil
		if type(active) ~= "table" or not remote then return nil end
		return entry_names(remote, entries.list())[active.id]
	end
	local model = type(llm.get_current_model) == "function" and llm.get_current_model() or nil
	return type(model) == "string" and model ~= "" and model or nil
end

--- Rows choosing the backend, and the rows of the API backend.
--- @param llm table Prediction engine (get_backend, set_backend, get_current_model).
--- @param dialogs table { prompt(heading, text, initial, hidden), error(text, heading), info(heading, text), confirm(heading, text) }
--- @param on_changed function|nil Rebuilds the menu.
--- @param ollama_rows function Returns the Ollama model rows.
--- @return table rows
function M.rows(llm, dialogs, on_changed, ollama_rows, context)
	if type(llm.get_backend) ~= "function" then return ollama_rows() end
	local ok_remote, remote = pcall(require, "modules.llm.api_remote")
	local ok_entries, entries = pcall(require, "modules.llm.api_entries")
	local backend = llm.get_backend()
	local function changed() if type(on_changed) == "function" then on_changed() end end

	-- The selected model heads the list under the key macOS and Windows give
	-- their model row, so the three trays name it with one wording.
	local selected = selected_model_name(llm, backend, ok_remote and remote or nil, ok_entries and entries or nil)
	local rows = {
		{
			label = string.format(tr("menu.llm.model_label"), selected or tr("menu.llm.no_model_none")),
			disabled = true,
		},
		{
			label = "Ollama 🦙 — " .. tr("menu.llm.backend_ollama_suffix"),
			checked = backend == "ollama",
			action = function() llm.set_backend("ollama"); changed() end,
		},
		{
			label = "API 🌐 — " .. tr("menu.llm.backend_api_suffix"),
			checked = backend == "api",
			action = function() llm.set_backend("api"); changed() end,
		},
	}
	local boundary = ManifestMenu.template_rows("llm_backend_choice_boundary", {}, {}, {})
	if not boundary then return {} end
	for _, row in ipairs(boundary) do rows[#rows + 1] = row end
	if type(context) == "table" and type(context.is_paused) == "function"
		and type(llm.can_configure_local_servers) == "function" then
		for _, row in ipairs(require("ui.menu.local_server_rows").rows(llm, dialogs, changed, context)) do
			rows[#rows + 1] = row
		end
	end
	if backend ~= "api" then
		for _, row in ipairs(ollama_rows()) do rows[#rows + 1] = row end
		return rows
	end
	if not ok_remote or not ok_entries then
		Logger.error(LOG, "Remote API modules unavailable — the API rows cannot be built.")
		rows[#rows + 1] = { label = tr("menu.llm.api_providers_unavailable"), disabled = true }
		return rows
	end

	local active = entries.active()
	local list = entries.list()
	local names = entry_names(remote, list)
	if #list == 0 then rows[#rows + 1] = { label = tr("menu.llm.api_no_entry"), disabled = true } end
	for _, entry in ipairs(list) do
		local label = names[entry.id]
		if remote.serves(entry.provider, "chat") then
			rows[#rows + 1] = {
				label = label,
				checked = active ~= nil and entry.id == active.id,
				action = function() entries.set_active(entry.id); changed() end,
			}
		else
			-- Never the predictions' entry: its own test and removal instead.
			rows[#rows + 1] = { label = label, items = {
				{ label = tr("menu.llm.api_test_entry"), action = function() run_test(remote, dialogs, entry, label) end },
				{ label = "🗑️ " .. tr("menu.llm.api_remove_entry"), action = function()
					local heading = (tr("menu.llm.api_remove_confirm_title"):gsub("%%s", function() return label end))
					if dialogs.confirm(heading, tr("menu.llm.api_remove_confirm_body")) ~= true then return end
					entries.remove(entry.id)
					changed()
				end },
			} }
		end
	end
	local separators = ManifestMenu.template_rows("llm_api_add_separator", {}, {}, {})
	if not separators then return {} end
	for _, row in ipairs(separators) do rows[#rows + 1] = row end

	local add_items = {}
	for _, provider in ipairs(remote.providers()) do
		add_items[#add_items + 1] = {
			label = "➕ " .. provider.label,
			action = function() add_entry(llm, remote, entries, dialogs, provider, on_changed) end,
		}
	end
	if #add_items == 0 then
		add_items[1] = { label = tr("menu.llm.api_providers_unavailable"), disabled = true }
	end
	local add_controls = ManifestMenu.template_rows("llm_api_add_provider_group", {}, {
		llm_api_add_group_ready = function() return true end,
	}, { api_add_entry = add_items })
	if not add_controls then return {} end
	for _, row in ipairs(add_controls) do rows[#rows + 1] = row end
	local active_name = active and names[active.id] or nil
	local function active_commands_ready()
		local current = entries.active()
		return active ~= nil and current ~= nil and current.id == active.id
	end
	local test_row = ManifestMenu.command_row("llm_api_active_commands", "api_test_active", {
		api_test_active = function() return run_test(remote, dialogs, active, active_name) end,
	}, { llm_api_active_ready = active_commands_ready })
	local remove_row = ManifestMenu.command_row("llm_api_active_commands", "api_remove_active", {
		api_remove_active = function()
			local heading = (tr("menu.llm.api_remove_confirm_title"):gsub("%%s", function() return active_name end))
			if dialogs.confirm(heading, tr("menu.llm.api_remove_confirm_body")) ~= true then return false end
			if not active_commands_ready() then return false end
			if entries.remove(active.id) ~= true then return false end
			changed()
			return true
		end,
	}, { llm_api_active_ready = active_commands_ready })
	if remove_row then
		remove_row.label = "🗑️ " .. remove_row.label .. (active and (" (" .. active_name .. ")") or "")
	end
	local active_rows = { api_test_active = test_row, api_remove_active = remove_row }
	for _, declaration in ipairs(ManifestMenu.get_array("llm_api_active_commands")) do
		if active_rows[declaration.id] then rows[#rows + 1] = active_rows[declaration.id] end
	end
	return rows
end

return M
