--- ui/menu/agent_rows.lua

--- ==============================================================================
--- MODULE: AI Agent Menu (Linux tray)
--- DESCRIPTION:
--- The top-level « AI agent » submenu the manifest declares (menu.agent_menu):
--- the agent's mode, the backend and model of System 1 and System 2, and the
--- applications the automatic mode ignores.
---
--- FEATURES & RATIONALE:
--- 1. Row data only: the shared renderer draws it, like every other submenu.
--- 2. A system's backend list is the local server, then the providers of
---    api_providers.json that serve it in catalogue order (System 1 also
---    offers Jev, System 2 only chat models); the model row shows the model
---    the system runs and asks for another in a text prompt, empty for the
---    default.
--- 3. The mode goes through the prediction engine, which refuses the automatic
---    mode without System 1 and System 2 and tells the user why.
--- 4. Dialogs are handed in by the menu builder, so this module never opens a
---    window the keyboard grab would starve (ui/modal.lua).
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local AgentSettings = require("modules.llm.agent_settings")

local LOG = "ui.menu.agent_rows"

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

--- Appends provider row data rendered by the shared renderer.
--- @param target table The native rows the renderer is building.
--- @param row table Row data { label, items?, action?, disabled? }.
--- @param id string Diagnostic id.
local function append(target, row, id)
	for _, rendered in ipairs(require("infra.manifest_menu").render_rows({ row }, id)) do
		target[#target + 1] = rendered
	end
end




-- =========================================
-- =========================================
-- ======= 1/ Systems ======================
-- =========================================
-- =========================================

--- The rows of one system: Off, every backend, then its model.
--- @param system string "system1" or "system2".
--- @param dialogs table { prompt(title, text, initial) }
--- @param changed function Redraws the menu.
--- @return string current The current backend's label.
--- @return table rows
local function system_rows(system, dialogs, changed)
	local spec = AgentSettings.get_spec(system)
	local parsed = spec ~= "" and require("llm.vision").parse(spec) or nil
	local choices = AgentSettings.backend_choices(system)
	local current_label = tr("menu.agent.off")
	local current_choice = nil
	for _, choice in ipairs(choices) do
		if parsed and choice.value == parsed.backend then
			current_label, current_choice = choice.label, choice
		end
	end
	if parsed and not current_choice then current_label = parsed.backend end

	local function store(value)
		if AgentSettings.set_spec(system, value) then changed() end
	end
	local off = require("infra.manifest_menu").check_row("agent_system_controls", "agent_system_off", {
		agent_system_off = function()
			if AgentSettings.set_spec(system, "") ~= true then return false end
			changed()
			return true
		end,
	}, {
		agent_system_is_off = function() return AgentSettings.get_spec(system) == "" end,
		agent_system_off_ready = function() return type(AgentSettings.set_spec) == "function" end,
	})
	if not off then return current_label, {} end
	local rows = { off }
	for _, choice in ipairs(choices) do
		local value = choice.value
		rows[#rows + 1] = {
			label = choice.label,
			checked = parsed ~= nil and parsed.backend == value,
			-- A new backend starts on its default model.
			action = function() store(value) end,
		}
	end
	local resolved = AgentSettings.resolve(system)
	local model = resolved and resolved.model or (parsed and parsed.model) or ""
	local model_rows = require("infra.manifest_menu").template_rows("agent_system_model_controls", {
		["agent_system_model"] = function()
			if not parsed then return end
			local backend = parsed.backend
			local answer = dialogs.prompt(tr("menu.agent.title"),
				fill(tr("dialog.agent.model_prompt"), { current_label }), parsed.model or "")
			if answer == nil then return end
			answer = answer:match("^%s*(.-)%s*$")
			local value = answer == "" and backend or (backend .. "|" .. answer)
			if not AgentSettings.is_valid_spec(value) then
				Logger.warn(LOG, "Agent %s model refused: not a model name.", system)
				dialogs.error(tr("dialog.gestures.param_err_llm_vision"))
				return
			end
			store(value)
		end,
	}, {
		agent_system_model_ready = function() return parsed ~= nil end,
	})
	if not model_rows then return current_label, {} end
	for _, row in ipairs(model_rows) do
		if row.label then row.label = fill(row.label, { model }) end
		rows[#rows + 1] = row
	end
	return current_label, rows
end




-- =========================================
-- =========================================
-- ======= 2/ Excluded applications ========
-- =========================================
-- =========================================

--- The applications a user may exclude without typing their identifier: the
--- ones with a window on screen, when the session can list them.
--- @param excluded table Set of excluded identifiers.
--- @return table Array of identifiers.
local function running_apps(excluded)
	local ok, WindowInfo = pcall(require, "adapters.window_info")
	if not ok then return {} end
	local list, seen = {}, {}
	for _, info in ipairs(WindowInfo.getAll()) do
		local app = type(info) == "table" and info.appId or nil
		if type(app) == "string" and app ~= "" and not seen[app] and not excluded[app] then
			seen[app] = true
			list[#list + 1] = app
		end
	end
	table.sort(list)
	return list
end

--- The rows of the excluded applications: each one (clicking removes it), the
--- application last typed in, then any other.
--- @param llm table|nil The prediction engine.
--- @param dialogs table { prompt(title, text, initial, hidden, choices) }
--- @param changed function Redraws the menu.
--- @return integer count, table rows
local function disabled_app_rows(llm, dialogs, changed)
	local apps = AgentSettings.get_disabled_apps()
	local excluded = {}
	for _, app in ipairs(apps) do excluded[app] = true end
	local function store(list)
		if AgentSettings.set_disabled_apps(list) then changed() end
	end
	-- Read again at click time: the list may have changed since the menu was built.
	local function add(app)
		local list = AgentSettings.get_disabled_apps()
		for _, existing in ipairs(list) do if existing == app then return end end
		list[#list + 1] = app
		store(list)
	end
	local rows = {}
	for _, app in ipairs(apps) do
		rows[#rows + 1] = {
			label = app .. "  ✗",
			action = function()
				local list = {}
				for _, existing in ipairs(AgentSettings.get_disabled_apps()) do
					if existing ~= app then list[#list + 1] = existing end
				end
				store(list)
			end,
		}
	end
	if #rows > 0 then rows[#rows + 1] = { separator = true } end
	local last = llm and type(llm.get_agent_last_app) == "function" and llm.get_agent_last_app() or nil
	if type(last) == "string" and last ~= "" and not excluded[last] then
		-- Plain indices: an application name is data, not a pattern replacement.
		local template = tr("app_picker.exclude_current")
		local at = template:find("{app}", 1, true)
		rows[#rows + 1] = {
			label = at and (template:sub(1, at - 1) .. last .. template:sub(at + 5)) or template,
			action = function() add(last) end,
		}
	end
	rows[#rows + 1] = {
		label = tr("app_picker.add_another_app"),
		action = function()
			local answer = dialogs.prompt(tr("menu.agent.title"), tr("app_picker.search_placeholder"), "", false,
				running_apps(excluded))
			if answer == nil then return end
			answer = answer:match("^%s*(.-)%s*$")
			if answer == "" then return end
			add(answer)
		end,
	}
	return #apps, rows
end




-- =========================================
-- =========================================
-- ======= 3/ The submenu ==================
-- =========================================
-- =========================================

--- Builds the agent's top-level row.
--- @param ctx table Menu context { llm, on_menu_changed }.
--- @param dialogs table { prompt(title, text, initial, hidden, choices), error(text) }
--- @return table Row data { label, submenu }.
function M.build(ctx, dialogs)
	local ManifestMenu = require("infra.manifest_menu")
	local llm = ctx.llm
	local function changed()
		if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
	end
	local handlers = {}
	for _, system in ipairs({ "system1", "system2" }) do
		handlers["agent_" .. system] = function(target)
			local current, rows = system_rows(system, dialogs, changed)
			append(target, { label = fill(tr("menu.agent." .. system), { current }), items = rows },
				"agent_" .. system)
		end
	end
	handlers["agent_disabled_apps"] = function(target)
		local count, rows = disabled_app_rows(llm, dialogs, changed)
		append(target, { label = fill(tr("menu.agent.disabled_apps"), { count }), items = rows },
			"agent_disabled_apps")
	end
	local menu_ctx = {
		commands = {
			agent_mode = function(id)
				if not llm or type(llm.set_agent_mode) ~= "function" then return false end
				local committed = llm.set_agent_mode(id) == true
				if committed then changed() end
				return committed
			end,
		},
		state_getters = {
			["llm.agent_mode"] = AgentSettings.get_mode,
			agent_mode_ready = function() return llm ~= nil and type(llm.set_agent_mode) == "function" end,
		},
	}
	return { label = tr("menu.agent.title"), submenu = ManifestMenu.build("agent_menu", "Agent", handlers, nil, menu_ctx, {}) }
end

return M
