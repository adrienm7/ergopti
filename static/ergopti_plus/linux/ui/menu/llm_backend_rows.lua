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
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

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

--- Reports a test verdict.
--- @param dialogs table
--- @param entry table
--- @param ok boolean
--- @param detail string
--- @param elapsed_ms number
local function report_test(dialogs, entry, ok, detail, elapsed_ms)
	if ok then
		local reply = tostring(detail or "")
		if #reply > TEST_REPLY_PREVIEW then reply = reply:sub(1, TEST_REPLY_PREVIEW) .. "..." end
		dialogs.info(tr("menu.llm.api_test_ok_title"),
			fill(tr("menu.llm.api_test_ok_body"), { entry.label, math.floor(elapsed_ms or 0), reply }))
		return
	end
	local body = (tr("menu.llm.api_unreachable_body"):gsub("%%s", function() return entry.label end))
	dialogs.error(body .. "\n" .. tostring(detail or ""), tr("menu.llm.api_unreachable_title"))
end

--- Tests one entry and reports the verdict when the answer arrives.
--- @param remote table api_remote
--- @param dialogs table
--- @param entry table
local function run_test(remote, dialogs, entry)
	local dispatched = remote.test(entry, function(ok, detail, elapsed_ms)
		Logger.info(LOG, "API test of '%s': %s.", entry.label, ok and "answered" or "failed")
		report_test(dialogs, entry, ok, detail, elapsed_ms)
	end)
	if not dispatched then Logger.warn(LOG, "API test of '%s' could not be sent.", entry.label) end
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
	local token = dialogs.prompt(heading, tr("menu.llm.api_prompt_token"), "", true)
	if not token then return end
	token = token:match("^%s*(.-)%s*$")
	if token == "" then return end
	local model = dialogs.prompt(heading, tr("menu.llm.api_prompt_model"), provider.default_model)
	if not model then return end
	model = model:match("^%s*(.-)%s*$")
	if model == "" then model = provider.default_model end
	if model == "" then return end

	local entry, err = entries.add({
		provider = provider.id,
		token = token,
		label = provider.label,
		model = model ~= provider.default_model and model or "",
		base_url = base_url,
	})
	if not entry then
		dialogs.error(tostring(err), heading)
		return
	end
	llm.set_backend("api")
	if type(on_changed) == "function" then on_changed() end
	run_test(remote, dialogs, entry)
end

--- Rows choosing the backend, and the rows of the API backend.
--- @param llm table Prediction engine (get_backend, set_backend).
--- @param dialogs table { prompt(heading, text, initial, hidden), error(text, heading), info(heading, text), confirm(heading, text) }
--- @param on_changed function|nil Rebuilds the menu.
--- @param ollama_rows function Returns the Ollama model rows.
--- @return table rows
function M.rows(llm, dialogs, on_changed, ollama_rows)
	if type(llm.get_backend) ~= "function" then return ollama_rows() end
	local ok_remote, remote = pcall(require, "modules.llm.api_remote")
	local ok_entries, entries = pcall(require, "modules.llm.api_entries")
	local backend = llm.get_backend()
	local function changed() if type(on_changed) == "function" then on_changed() end end

	local rows = {
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
		{ separator = true },
	}
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
	if #list == 0 then rows[#rows + 1] = { label = tr("menu.llm.api_no_entry"), disabled = true } end
	for _, entry in ipairs(list) do
		local provider = remote.provider(entry.provider)
		local model = entry.model ~= "" and entry.model or (provider and provider.default_model or "")
		rows[#rows + 1] = {
			label = string.format("%s — %s", entry.label, model),
			checked = active ~= nil and entry.id == active.id,
			action = function() entries.set_active(entry.id); changed() end,
		}
	end
	rows[#rows + 1] = { separator = true }

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
	rows[#rows + 1] = { label = tr("menu.llm.api_add_entry"), items = add_items }
	rows[#rows + 1] = {
		label = tr("menu.llm.api_test_entry"),
		disabled = active == nil or nil,
		action = function() if active then run_test(remote, dialogs, active) end end,
	}
	rows[#rows + 1] = {
		label = "🗑️ " .. tr("menu.llm.api_remove_entry") .. (active and (" (" .. active.label .. ")") or ""),
		disabled = active == nil or nil,
		action = function()
			if not active then return end
			local heading = (tr("menu.llm.api_remove_confirm_title"):gsub("%%s", function() return active.label end))
			if dialogs.confirm(heading, tr("menu.llm.api_remove_confirm_body")) ~= true then return end
			entries.remove(active.id)
			changed()
		end,
	}
	return rows
end

return M
