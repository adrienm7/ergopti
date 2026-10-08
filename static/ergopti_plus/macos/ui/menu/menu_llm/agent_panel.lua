--- ui/menu/menu_llm/agent_panel.lua

--- ==============================================================================
--- MODULE: AI Agent Menu
--- DESCRIPTION:
--- Builds the top-level "🤖 AI agent" menu from the manifest's `agent_menu`:
--- the mode (off, on action, automatic), the backend and model of System 1 and
--- System 2, and the applications the automatic mode ignores.
---
--- FEATURES & RATIONALE:
--- 1. The manifest places the rows; this panel supplies what each dynamic row
---    shows and does.
--- 2. Every change goes through the AI menu's setting transaction: runtime
---    setter, config.toml, menu refresh, rolled back as a whole on a refusal.
--- 3. The backend lists are the local server, the local OpenAI-compatible
---    servers that answer (local_servers.json, each with a submenu of the
---    models it serves), then the providers of
---    api_providers.json that serve the System, in the catalogue's order
---    (modules/llm/provider_uses.lua): a decisions provider (Jev) triages only,
---    so it is offered to System 1 alone. The model row shows the
---    model in force (the chosen one, or the backend's default) and asks for
---    another; an empty answer returns to the default.
--- 4. The automatic mode needs System 1: choosing it without one shows the
---    notice and changes nothing.
--- 5. A local model is shown installed or not, as the local server listed it
---    last, with a Download row when it is missing. Building the menu asks for
---    a new listing, which refreshes the menu only when it changes what a row
---    shows (a refresh on every listing would rebuild in a loop). Choosing the
---    local backend or naming a local model asks the server at once and offers
---    the download of a missing one, so no request names a model nobody pulled.
--- ==============================================================================

local M = {}

local Logger       = require("infra.logger")
local i18n         = require("infra.i18n")
local ManifestMenu = require("infra.manifest_menu")
local AppPickerLib = require("infra.app_picker")
local dialog       = require("infra.dialog_util")
local Vision       = require("llm.vision")
local Agent        = require("llm.agent")
local ProviderUses = require("modules.llm.provider_uses")

local LOG = "menu_llm.agent_panel"

-- The two systems: their setting, runtime setter and provider use
local SYSTEMS = {
	agent_system1 = { key = "llm_agent_system1", setter = "set_llm_agent_system1",
		use = ProviderUses.SYSTEM1 },
	agent_system2 = { key = "llm_agent_system2", setter = "set_llm_agent_system2",
		use = ProviderUses.SYSTEM2 },
}




-- =====================================
-- =====================================
-- ======= 1/ Choices ==================
-- =====================================
-- =====================================

--- The label of a local OpenAI-compatible server (local_servers.json).
--- @param id string Server id.
--- @return string label
local function server_label(id)
	return require("modules.llm.api_remote").PROVIDERS[id].label .. " 🖥️"
end

--- The backends a System may name: the local server, the local
--- OpenAI-compatible servers that answered the last sweep with their models
--- (modules/llm/local_servers.lua), then the providers that serve it.
--- @param use string|nil provider_uses.SYSTEM1 (the default, every provider) or SYSTEM2.
--- @return table Array of { id, label }.
function M.backends(use)
	local Remote = require("modules.llm.api_remote")
	local LocalServers = require("modules.llm.local_servers")
	use = use or ProviderUses.SYSTEM1
	local choices = { { id = Vision.LOCAL_BACKEND, label = i18n.get("llm.vision.local_backend") } }
	local up = {}
	for _, server_id in ipairs(LocalServers.detected()) do
		if LocalServers.result(server_id).status == LocalServers.STATUS_UP then up[#up + 1] = server_id end
	end
	for _, server_id in ipairs(ProviderUses.provider_ids(up, Remote.PROVIDERS, use)) do
		choices[#choices + 1] = { id = server_id, label = server_label(server_id) }
	end
	for _, provider_id in ipairs(ProviderUses.provider_ids(Remote.PROVIDER_ORDER, Remote.PROVIDERS, use)) do
		choices[#choices + 1] = { id = provider_id, label = Remote.PROVIDERS[provider_id].label }
	end
	return choices
end

--- The label of a backend id.
--- @param id string
--- @return string label
local function backend_label(id)
	for _, choice in ipairs(M.backends()) do
		if choice.id == id then return choice.label end
	end
	-- A chosen local server that does not answer now
	if require("modules.llm.api_remote").is_local_server(id) then return server_label(id) end
	return id
end

--- The model a System setting runs with.
--- @param parsed table { backend, model }.
--- @return string|nil model
local function resolved_model(parsed)
	local Remote = require("modules.llm.api_remote")
	local Runner = require("modules.llm.agent_runner")
	return Agent.resolve_model(parsed, Runner.config(), { providers = Remote.PROVIDERS })
end

--- The local model a System setting runs with.
--- @param value string The setting.
--- @return string|nil model nil for an off or remote System.
local function local_model_of(value)
	local parsed = type(value) == "string" and value ~= "" and Vision.parse(value) or nil
	if parsed == nil or parsed.backend ~= Vision.LOCAL_BACKEND then return nil end
	return resolved_model(parsed)
end

--- Refreshes the menu, whose rows show what the local server listed.
--- @param ctx table Panel context.
local function refresh_menu(ctx)
	if type(ctx.update_menu) ~= "function" then return end
	local ok, err = pcall(ctx.update_menu)
	if not ok then Logger.error(LOG, "Menu refresh after a local model listing raised: %s.", tostring(err)) end
end

--- Asks the local server whether it holds the local model a setting names,
--- and offers the download of a missing one.
--- @param ctx table Panel context.
--- @param value string The setting just applied.
local function offer_missing_local_model(ctx, value)
	local model = local_model_of(value)
	if model == nil then return end
	local Ollama = require("modules.llm.api_ollama")
	local before = Ollama.local_model_installed(model)
	Ollama.verify_local_model(model, function(installed, reason)
		if installed ~= before then refresh_menu(ctx) end
		if installed == false then
			require("modules.llm.local_model_offer").offer(model)
		elseif installed == nil then
			Logger.warn(LOG, "Whether local model '%s' is installed is unknown (%s).", model, tostring(reason))
		end
	end)
end




-- =====================================
-- =====================================
-- ======= 2/ Rows =====================
-- =====================================
-- =====================================

--- Applies one agent setting through the AI menu's transaction.
--- @param ctx table Panel context.
--- @param key string State key.
--- @param value any New value.
--- @param setter string Runtime setter of the keymap bridge.
--- @return boolean committed
local function apply(ctx, key, value, setter)
	local committed = ctx.settings_mgr.apply_setting_transaction({
		key = key, value = value, runtime_fn = setter, publish_setting = false,
	}) == true
	if not committed then Logger.warn(LOG, "Agent setting '%s' was not applied.", key) end
	return committed
end

--- Applies a shared mode choice through its native prerequisite and durable owner.
--- @param ctx table Panel context.
--- @param id string Mode from the shared enum feature.
--- @return boolean committed
local function set_mode(ctx, id)
	local Runner = require("modules.llm.agent_runner")
	if id == "auto" and not Runner.is_configured(ctx.state.llm_agent_system1) then
		Logger.info(LOG, "Automatic mode refused from the menu: System 1 is not chosen.")
		local ok_tooltip, tooltip = pcall(require, "ui.tooltip")
		if ok_tooltip and type(tooltip.show) == "function" then
			pcall(tooltip.show, i18n.get("llm.agent.no_system1"), true, true)
		end
		return false
	end
	return apply(ctx, "llm_agent_mode", id, "set_llm_agent_mode")
end

--- Asks for the model of a System and stores "<backend>" or "<backend>|<model>".
--- @param ctx table Panel context.
--- @param system table SYSTEMS entry.
--- @param parsed table The current { backend, model }.
--- @return boolean committed
local function prompt_model(ctx, system, parsed)
	local label = backend_label(parsed.backend)
	local ok_label = i18n.get("button.ok")
	local ok, button, typed = pcall(dialog.text_prompt, i18n.get("menu.agent.title"),
		i18n.format("dialog.agent.model_prompt", label), parsed.model or "", ok_label, i18n.get("common.cancel"))
	if not ok then
		Logger.error(LOG, "Agent model dialog raised: %s.", tostring(button))
		return false
	end
	if button ~= ok_label or type(typed) ~= "string" then return false end
	local model = typed:match("^%s*(.-)%s*$")
	local value = model == "" and parsed.backend or (parsed.backend .. "|" .. model)
	if not Vision.parse(value) then
		Logger.warn(LOG, "Agent model refused: '%s' is not a model name.", model)
		return false
	end
	if not apply(ctx, system.key, value, system.setter) then return false end
	offer_missing_local_model(ctx, value)
	return true
end

--- The model rows of a local server: the models it served at the last sweep,
--- and the chosen one even when it is gone. Each stores "<server>|<model>".
--- @param ctx table Panel context.
--- @param system table SYSTEMS entry.
--- @param id string Server id.
--- @param parsed table|nil The current { backend, model }.
--- @return table rows
local function server_model_rows(ctx, system, id, parsed)
	local LocalServers = require("modules.llm.local_servers")
	local verdict = LocalServers.result(id)
	local models = {}
	for _, model in ipairs(verdict and verdict.models or {}) do models[#models + 1] = model end
	local chosen = parsed and parsed.backend == id and parsed.model or nil
	local listed = false
	for _, model in ipairs(models) do listed = listed or model == chosen end
	if chosen and not listed then models[#models + 1] = chosen end
	local rows = {}
	for _, model in ipairs(models) do
		rows[#rows + 1] = {
			label = model,
			checked = model == chosen,
			action = function() return apply(ctx, system.key, id .. "|" .. model, system.setter) end,
		}
	end
	if #rows == 0 then return ManifestMenu.template_rows("agent_server_empty_status", {}, {}, {}) or {} end
	return rows
end

--- Rows of one System's submenu.
--- @param ctx table Panel context.
--- @param system table SYSTEMS entry.
--- @return table rows
local function system_rows(ctx, system)
	local value = ctx.state[system.key] or ""
	local parsed = value ~= "" and Vision.parse(value) or nil
	local off = ManifestMenu.check_row("agent_system_controls", "agent_system_off", {
		agent_system_off = function() return apply(ctx, system.key, "", system.setter) end,
	}, {
		agent_system_is_off = function()
			local current = ctx.state[system.key] or ""
			return current == "" or Vision.parse(current) == nil
		end,
		agent_system_off_ready = function()
			return type(ctx.settings_mgr.apply_setting_transaction) == "function"
		end,
	})
	if not off then return {} end
	local items = { off }
	local Remote = require("modules.llm.api_remote")
	local choices = M.backends(system.use)
	local chosen_listed = parsed == nil
	for _, choice in ipairs(choices) do chosen_listed = chosen_listed or choice.id == parsed.backend end
	if not chosen_listed and Remote.is_local_server(parsed.backend) then
		-- A chosen local server that does not answer now stays ticked
		table.insert(choices, 2, { id = parsed.backend, label = server_label(parsed.backend) })
	end
	for _, choice in ipairs(choices) do
		local id = choice.id
		local row = { label = choice.label, checked = parsed ~= nil and parsed.backend == id }
		if Remote.is_local_server(id) then
			-- A local server has no default model: its row lists the models it serves
			row.items = server_model_rows(ctx, system, id, parsed)
		else
			row.action = function()
				if not apply(ctx, system.key, id, system.setter) then return false end
				offer_missing_local_model(ctx, id)
				return true
			end
		end
		items[#items + 1] = row
	end
	local model = parsed and resolved_model(parsed) or nil
	-- nil while the local server has not listed its models (or for a remote System)
	local installed = nil
	if model ~= nil and parsed.backend == Vision.LOCAL_BACKEND then
		installed = require("modules.llm.api_ollama").local_model_installed(model)
	end
	local model_commands = {
		["agent_system_model"] = function() return prompt_model(ctx, system, parsed) end,
	}
	local model_getters = {
		agent_system_model_ready = function() return parsed ~= nil end,
		agent_system_model_caption = function() return model or i18n.get("menu.agent.off") end,
	}
	local model_rows
	if installed == true then
		model_rows = ManifestMenu.template_rows("agent_system_model_installed_controls", model_commands, model_getters)
	elseif installed == false then
		model_rows = ManifestMenu.template_rows("agent_system_model_missing_controls", model_commands, model_getters)
	else
		model_rows = ManifestMenu.template_rows("agent_system_model_controls", model_commands, model_getters)
	end
	if not model_rows then return {} end
	for _, row in ipairs(model_rows) do
		items[#items + 1] = row
	end
	if installed == false then
		local download = ManifestMenu.template_rows("agent_download_frame", {
			["agent_download_model"] = function() return require("modules.llm.local_model_offer").install(model) end,
		})
		if not download or #download ~= 1 or type(download[1].action) ~= "function" then return nil end
		download[1].label = download[1].label:gsub("{1}", function() return model end)
		items[#items + 1] = download[1]
	end
	local current = parsed and backend_label(parsed.backend) or i18n.get("menu.agent.off")
	local frame
	if system.key == "llm_agent_system1" then
		frame = ManifestMenu.template_rows("agent_system1_frame", {}, {}, { agent_system1 = items })
	else
		frame = ManifestMenu.template_rows("agent_system2_frame", {}, {}, { agent_system2 = items })
	end
	if not frame or #frame ~= 1 or type(frame[1].items) ~= "table" then return nil end
	frame[1].label = frame[1].label:gsub("{1}", function() return current end)
	return frame
end

--- Rows of the excluded-applications submenu.
--- @param ctx table Panel context.
--- @return table rows
local function disabled_apps_rows(ctx)
	local apps = type(ctx.state.llm_agent_disabled_apps) == "table" and ctx.state.llm_agent_disabled_apps or {}
	local definition = ManifestMenu.get_array("agent_excluded_apps_frame")
	if type(definition) ~= "table" or #definition ~= 1
		or type(definition[1]) ~= "table" or type(definition[1].i18n) ~= "string"
		or definition[1].i18n == "" then return nil end
	local label = i18n.get(definition[1].i18n):gsub("{1}", function() return tostring(#apps) end)
	local frame = ManifestMenu.template_rows("agent_excluded_apps_frame", {}, {}, {
		agent_disabled_apps = AppPickerLib.build_menu(apps, function(new_list)
			return apply(ctx, "llm_agent_disabled_apps", new_list, "set_llm_agent_disabled_apps")
		end, label),
	})
	if not frame or #frame ~= 1 or type(frame[1].items) ~= "table" then return nil end
	frame[1].label = frame[1].label:gsub("{1}", function() return tostring(#apps) end)
	return frame
end




-- =====================================
-- =====================================
-- ======= 3/ Public API ===============
-- =====================================
-- =====================================

--- Builds the top-level AI agent row.
--- @param ctx table { state, settings_mgr, update_menu }; update_menu (optional)
---        redraws the menu once a local model listing changed a row.
--- @return table row { label, submenu }.
function M.build(ctx)
	if type(ctx) ~= "table" or type(ctx.state) ~= "table" or type(ctx.settings_mgr) ~= "table"
		or type(ctx.settings_mgr.apply_setting_transaction) ~= "function" then
		error("agent_panel.build: a state and a settings manager are required")
	end
	if type(rawget(ManifestMenu.get_root(), "agent_menu")) ~= "table" then return nil end
	for _, key in ipairs({ "agent_panel_frame", "agent_system1_frame", "agent_system2_frame",
		"agent_excluded_apps_frame", "agent_download_frame" }) do
		local definition = ManifestMenu.get_array(key)
		if type(definition) ~= "table" or #definition ~= 1
			or type(definition[1]) ~= "table" or type(definition[1].i18n) ~= "string"
			or definition[1].i18n == "" then return nil end
	end
	-- A local server's missing-model notice fixes the Systems through this context
	require("ui.menu.menu_llm.local_server_panel").set_agent_context(ctx)
	-- The Shortcuts the agent may run are read again when the menu opens, if stale
	local Runner = require("modules.llm.agent_runner")
	local ok_tools, tools_error = pcall(Runner.refresh_tools, false, nil)
	if not ok_tools then Logger.error(LOG, "Shortcuts refresh raised: %s.", tostring(tools_error)) end
	-- A local System shows whether its model is installed: list the models
	-- again, and refresh the menu only if that changes what a row shows
	-- An array, not a map: an unlisted model's state is nil
	local shown = {}
	for _, key in ipairs({ "llm_agent_system1", "llm_agent_system2" }) do
		local model = local_model_of(ctx.state[key])
		if model then
			shown[#shown + 1] = { model = model, before = require("modules.llm.api_ollama").local_model_installed(model) }
		end
	end
	if #shown > 0 then
		local Ollama = require("modules.llm.api_ollama")
		local ok_list, list_error = pcall(Ollama.refresh_local_models, function(listed)
			if listed ~= true then return end
			for _, row in ipairs(shown) do
				if Ollama.local_model_installed(row.model) ~= row.before then return refresh_menu(ctx) end
			end
		end)
		if not ok_list then Logger.error(LOG, "Local model listing raised: %s.", tostring(list_error)) end
	end

	--- Wraps a row provider as a dynamic handler of the renderer.
	--- @param id string Row id, for the warnings.
	--- @param provider function Returns the rows.
	--- @return function handler
	local refused_frame = false
	local function dynamic(id, provider)
		return function(result)
			local ok, rows = pcall(provider)
			if not ok then refused_frame = true; error(rows, 0) end
			if rows == nil then refused_frame = true; return end
			for _, row in ipairs(ManifestMenu.render_rows(rows, id)) do result[#result + 1] = row end
		end
	end
	local submenu = ManifestMenu.build("agent_menu", "AI agent", {
		agent_system1 = dynamic("agent_system1", function() return system_rows(ctx, SYSTEMS.agent_system1) end),
		agent_system2 = dynamic("agent_system2", function() return system_rows(ctx, SYSTEMS.agent_system2) end),
		agent_disabled_apps = dynamic("agent_disabled_apps", function() return disabled_apps_rows(ctx) end),
	}, nil, {
		commands = { agent_mode = function(id) return set_mode(ctx, id) end },
		state_getters = {
			["llm.agent_mode"] = function() return ctx.state.llm_agent_mode end,
			agent_mode_ready = function() return type(ctx.settings_mgr) == "table" and type(ctx.settings_mgr.apply_setting_transaction) == "function" end,
		},
	})
	if not submenu or refused_frame then return nil end
	local children = ManifestMenu.native_child_rows(submenu)
	if not children then return nil end
	local frame = ManifestMenu.template_rows("agent_panel_frame", {}, {}, { agent_panel = children })
	if not frame or #frame ~= 1 or type(frame[1].items) ~= "table" then return nil end
	-- Preserve the existing public finished-submenu shape and its native callback identities.
	frame[1].items = nil
	frame[1].submenu = submenu
	return frame[1]
end

return M
