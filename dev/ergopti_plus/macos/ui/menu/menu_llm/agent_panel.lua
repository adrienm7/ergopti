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
--- 3. The backend lists are the local server, then the providers of
---    api_providers.json that serve the System, in the catalogue's order
---    (modules/llm/provider_uses.lua): a decisions provider (Jev) triages only,
---    so it is offered to System 1 alone. The model row shows the
---    model in force (the chosen one, or the backend's default) and asks for
---    another; an empty answer returns to the default.
--- 4. The automatic mode needs System 1: choosing it without one shows the
---    notice and changes nothing.
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

-- The mode choices, in menu order, with their labels
local MODES = {
	{ id = "off", key = "menu.agent.mode_off" },
	{ id = "action", key = "menu.agent.mode_action" },
	{ id = "auto", key = "menu.agent.mode_auto" },
}

-- The two systems: their setting, runtime setter and title key
local SYSTEMS = {
	agent_system1 = { key = "llm_agent_system1", setter = "set_llm_agent_system1", title = "menu.agent.system1",
		use = ProviderUses.SYSTEM1 },
	agent_system2 = { key = "llm_agent_system2", setter = "set_llm_agent_system2", title = "menu.agent.system2",
		use = ProviderUses.SYSTEM2 },
}




-- =====================================
-- =====================================
-- ======= 1/ Choices ==================
-- =====================================
-- =====================================

--- The backends a System may name: the local server, then the providers that
--- serve it.
--- @param use string|nil provider_uses.SYSTEM1 (the default, every provider) or SYSTEM2.
--- @return table Array of { id, label }.
function M.backends(use)
	local Remote = require("modules.llm.api_remote")
	local choices = { { id = Vision.LOCAL_BACKEND, label = i18n.get("llm.vision.local_backend") } }
	for _, provider_id in ipairs(ProviderUses.provider_ids(Remote.PROVIDER_ORDER, Remote.PROVIDERS,
		use or ProviderUses.SYSTEM1)) do
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

--- Rows of the mode submenu.
--- @param ctx table Panel context.
--- @return table rows
local function mode_rows(ctx)
	local current = ctx.state.llm_agent_mode
	local current_label = i18n.get("menu.agent.mode_off")
	local items = {}
	for _, mode in ipairs(MODES) do
		if mode.id == current then current_label = i18n.get(mode.key) end
		local id = mode.id
		items[#items + 1] = {
			label = i18n.get(mode.key),
			checked = id == current,
			action = function()
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
			end,
		}
	end
	return { { label = i18n.format("menu.agent.mode_title", current_label), items = items } }
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
	return apply(ctx, system.key, value, system.setter)
end

--- Rows of one System's submenu.
--- @param ctx table Panel context.
--- @param system table SYSTEMS entry.
--- @return table rows
local function system_rows(ctx, system)
	local value = ctx.state[system.key] or ""
	local parsed = value ~= "" and Vision.parse(value) or nil
	local items = {
		{
			label = i18n.get("menu.agent.off"),
			checked = parsed == nil,
			action = function() return apply(ctx, system.key, "", system.setter) end,
		},
	}
	for _, choice in ipairs(M.backends(system.use)) do
		local id = choice.id
		items[#items + 1] = {
			label = choice.label,
			checked = parsed ~= nil and parsed.backend == id,
			action = function() return apply(ctx, system.key, id, system.setter) end,
		}
	end
	items[#items + 1] = { separator = true }
	local model = parsed and resolved_model(parsed) or nil
	items[#items + 1] = {
		label = i18n.format("menu.agent.model", model or i18n.get("menu.agent.off")),
		disabled = parsed == nil or nil,
		action = parsed and function() return prompt_model(ctx, system, parsed) end or nil,
	}
	local current = parsed and backend_label(parsed.backend) or i18n.get("menu.agent.off")
	return { { label = i18n.format(system.title, current), items = items } }
end

--- Rows of the excluded-applications submenu.
--- @param ctx table Panel context.
--- @return table rows
local function disabled_apps_rows(ctx)
	local apps = type(ctx.state.llm_agent_disabled_apps) == "table" and ctx.state.llm_agent_disabled_apps or {}
	local label = i18n.format("menu.agent.disabled_apps", #apps)
	return { {
		label = label,
		items = AppPickerLib.build_menu(apps, function(new_list)
			return apply(ctx, "llm_agent_disabled_apps", new_list, "set_llm_agent_disabled_apps")
		end, label),
	} }
end




-- =====================================
-- =====================================
-- ======= 3/ Public API ===============
-- =====================================
-- =====================================

--- Builds the top-level AI agent row.
--- @param ctx table { state, settings_mgr }.
--- @return table row { label, submenu }.
function M.build(ctx)
	if type(ctx) ~= "table" or type(ctx.state) ~= "table" or type(ctx.settings_mgr) ~= "table"
		or type(ctx.settings_mgr.apply_setting_transaction) ~= "function" then
		error("agent_panel.build: a state and a settings manager are required")
	end
	-- The Shortcuts the agent may run are read again when the menu opens, if stale
	local Runner = require("modules.llm.agent_runner")
	local ok_tools, tools_error = pcall(Runner.refresh_tools, false, nil)
	if not ok_tools then Logger.error(LOG, "Shortcuts refresh raised: %s.", tostring(tools_error)) end

	--- Wraps a row provider as a dynamic handler of the renderer.
	--- @param id string Row id, for the warnings.
	--- @param provider function Returns the rows.
	--- @return function handler
	local function dynamic(id, provider)
		return function(result)
			for _, row in ipairs(ManifestMenu.render_rows(provider(), id)) do result[#result + 1] = row end
		end
	end
	local submenu = ManifestMenu.build("agent_menu", "AI agent", {
		agent_mode = dynamic("agent_mode", function() return mode_rows(ctx) end),
		agent_system1 = dynamic("agent_system1", function() return system_rows(ctx, SYSTEMS.agent_system1) end),
		agent_system2 = dynamic("agent_system2", function() return system_rows(ctx, SYSTEMS.agent_system2) end),
		agent_disabled_apps = dynamic("agent_disabled_apps", function() return disabled_apps_rows(ctx) end),
	}, nil, ctx) or {}
	return { label = i18n.get("menu.agent.title"), submenu = submenu }
end

return M
