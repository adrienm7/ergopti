--- ui/menu/menu_llm/local_server_panel.lua

--- ==============================================================================
--- MODULE: Local Server Panel
--- DESCRIPTION:
--- The rows of the AI engine submenu for the local servers that speak the
--- OpenAI API (modules/llm/local_servers.lua): each server that answers, with
--- the models it serves, its address and its key; a new search; another
--- address. Also the fixes the failure notices offer, and the switch to a
--- server that the unreachable-backend error offers (use_server).
---
--- FEATURES & RATIONALE:
--- 1. Listed only when it answers: the menu shows the last sweep's verdicts
---    and asks for a new sweep, asynchronously, when they are stale; the menu
---    is redrawn only when a verdict changed.
--- 2. Choosing a model is choosing the backend: the server's API entry is
---    stored (api_panel.apply_local_server), then the API backend is selected
---    if it was not, so predictions go to the server at once.
--- 3. Every failure offers its fix: a server that stopped answering, a key it
---    wants and a model it no longer serves each post a notice whose click
---    searches again, asks for the key or asks for another model.
--- ==============================================================================

local M = {}

local Logger        = require("infra.logger")
local i18n          = require("infra.i18n")
local dialog        = require("infra.dialog_util")
local notifications = require("infra.notifications")
local llm_mod       = require("modules.llm")
local ApiPanel      = require("ui.menu.menu_llm.api_panel")
local ServerMenu    = require("llm.local_server_menu")

local LOG = "menu_llm.local_servers"

-- The context of the last engine menu build: the failure notices act through it
local _ctx = nil
-- The AI agent menu's context: a missing model of a System is fixed through it
local _agent_ctx = nil




-- =====================================
-- =====================================
-- ======= 1/ Helpers ==================
-- =====================================
-- =====================================

--- The remote backend, which owns the servers' entries and probes.
--- @return table
local function remote()
	return llm_mod.api_remote
end

--- The servers and their verdicts, loaded with the remote backend that
--- registers them.
--- @return table modules/llm/local_servers.lua
local function servers()
	return require("modules.llm.local_servers")
end

--- The host and port of a base URL, for a row or a notice.
--- @param base_url string
--- @return string
local function host_of(base_url)
	return ServerMenu.host_of(base_url)
end

--- Shows a notice, logging a refusal instead of raising.
--- @param title string
--- @param body string
--- @param kind string "success", "warning" or "error".
--- @param on_click function|nil The fix a click applies.
local function notify(title, body, kind, on_click)
	local ok, err = pcall(notifications.notify, title, body, kind, on_click)
	if not ok then Logger.error(LOG, "Local server notice failed: %s", tostring(err)) end
end

--- Asks for one line of text.
--- @param message string
--- @param informative string
--- @param default string
--- @param secure boolean|nil Hide what is typed (a key).
--- @return string|nil text Trimmed, nil when cancelled.
local function ask(message, informative, default, secure)
	local ok_label = i18n.get("button.ok")
	local ok, button, typed = pcall(dialog.text_prompt, message, informative, default or "",
		ok_label, i18n.get("button.cancel"), secure == true)
	if not ok then
		Logger.error(LOG, "Local server dialog raised: %s", tostring(button))
		return nil
	end
	if button ~= ok_label or type(typed) ~= "string" then return nil end
	return (typed:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Sweeps the servers again and redraws the menu when a verdict changed.
--- @param ctx table|nil Engine menu context.
--- @param on_done function|nil Called once the sweep settled.
--- @return boolean started
function M.rescan(ctx, on_done)
	return remote().detect_local_servers(function(changed)
		if changed and ctx and type(ctx.update_menu) == "function" then
			local ok, err = pcall(ctx.update_menu)
			if not ok then Logger.error(LOG, "Menu redraw after the sweep failed: %s", tostring(err)) end
		end
		if type(on_done) == "function" then on_done() end
	end)
end




-- =====================================
-- =====================================
-- ======= 2/ Actions ==================
-- =====================================
-- =====================================

--- Makes one of a server's models the prediction backend.
--- @param ctx table Engine menu context, with activate_api.
--- @param id string Server id.
--- @param model string Model id.
--- @param on_selected function|nil Receives true once the API backend serves
---        the model, false when the entry or the backend switch did not commit.
--- @return boolean started
function M.select_model(ctx, id, model, on_selected)
	Logger.info(LOG, "Local server '%s' model '%s' chosen.", id, model)
	return ApiPanel.apply_local_server(ctx, id, { model = model }, function(committed)
		if committed and ctx.state.llm_backend ~= "api" and type(ctx.activate_api) == "function" then
			ctx.activate_api()
		end
		if type(on_selected) == "function" then
			local selected = committed == true and ctx.state.llm_backend == "api"
			if committed == true and not selected then
				-- Leaving MLX waits for its server to stop: the switch lands later
				Logger.warn(LOG, "Local server '%s' is stored; the API backend is not selected yet.", id)
			end
			on_selected(selected)
		end
	end)
end

--- Makes a server the prediction backend from outside the engine menu (the
--- unreachable-backend error), through the last engine menu's context.
--- @param id string Server id.
--- @param model string Model id.
--- @param on_selected function|nil As for select_model.
--- @return boolean started
function M.use_server(id, model, on_selected)
	if _ctx == nil then
		-- The AI menu builds its engine rows on its first draw, before any error
		Logger.error(LOG, "Local server '%s' cannot be selected: the AI engine menu was never built.", id)
		return false
	end
	return M.select_model(_ctx, id, model, on_selected)
end

--- Asks for a server's address, stores it and searches again.
--- @param ctx table Engine menu context.
--- @param id string Server id.
--- @return boolean started
function M.prompt_address(ctx, id)
	local server = servers().SERVERS[id]
	local current = remote().local_server_target(id).base_url
	local typed = ask(i18n.get("menu.llm.local_servers.header"),
		i18n.format("dialog.local_servers.address_prompt", server.label, server.base_url), current)
	if typed == nil then return false end
	if typed == "" then typed = server.base_url end
	local base = remote().normalize_base_url(typed)
	if not base then
		notify(server.label, i18n.format("llm.local_servers.invalid_address", server.base_url), "error",
			function() M.prompt_address(ctx, id) end)
		return false
	end
	return ApiPanel.apply_local_server(ctx, id, { base_url = base }, function(committed)
		if committed then M.rescan(ctx, function() M.report_sweep(id) end) end
	end)
end

--- Asks for the key a server wants, stores it and searches again.
--- @param ctx table Engine menu context.
--- @param id string Server id.
--- @return boolean started
function M.prompt_key(ctx, id)
	local server = servers().SERVERS[id]
	local typed = ask(i18n.get("menu.llm.local_servers.header"),
		i18n.format("dialog.local_servers.key_prompt", server.label), "", true)
	if typed == nil then return false end
	return ApiPanel.apply_local_server(ctx, id, { token = typed }, function(committed)
		if committed then M.rescan(ctx, function() M.report_sweep(id) end) end
	end)
end

--- Says what a new search found about one server.
--- @param id string Server id.
function M.report_sweep(id)
	local server = servers().SERVERS[id]
	local verdict = servers().result(id)
	local target = remote().local_server_target(id)
	if verdict and verdict.status == servers().STATUS_UP then
		notify(server.label, i18n.format("llm.local_servers.found_body", #verdict.models), "success")
	elseif verdict and verdict.status == servers().STATUS_NEEDS_KEY then
		notify(i18n.format("llm.local_servers.needs_key_title", server.label),
			i18n.format("llm.local_servers.needs_key_body", server.label), "warning",
			function() M.prompt_key(_ctx, id) end)
	else
		notify(i18n.format("llm.local_servers.not_running_title", server.label),
			i18n.format("llm.local_servers.still_down_body", host_of(target.base_url)), "warning",
			function() M.rescan(_ctx, function() M.report_sweep(id) end) end)
	end
end

--- Replaces a model a server no longer serves wherever it is chosen: the
--- prediction entry, and the agent's Systems.
--- @param id string Server id.
--- @param missing string|nil The model the server refused.
--- @param model string The model to use instead.
local function replace_model(id, missing, model)
	local entry = remote().local_server_entry(id)
	if _ctx and entry and (missing == nil or entry.model == missing) then
		ApiPanel.apply_local_server(_ctx, id, { model = model })
	end
	if not (_agent_ctx and missing) then return end
	for _, key in ipairs({ "llm_agent_system1", "llm_agent_system2" }) do
		if _agent_ctx.state[key] == id .. "|" .. missing then
			local setter = key == "llm_agent_system1" and "set_llm_agent_system1" or "set_llm_agent_system2"
			_agent_ctx.settings_mgr.apply_setting_transaction({
				key = key, value = id .. "|" .. model, runtime_fn = setter, publish_setting = false,
			})
		end
	end
end

--- Searches again, then asks which of the served models replaces a missing one.
--- @param id string Server id.
--- @param missing string|nil The model the server refused.
function M.prompt_model(id, missing)
	M.rescan(_ctx, function()
		local server = servers().SERVERS[id]
		local verdict = servers().result(id)
		if not verdict or verdict.status ~= servers().STATUS_UP then
			M.report_sweep(id)
			return
		end
		local typed = ask(i18n.format("llm.local_servers.model_missing_title", server.label, missing or "?"),
			i18n.format("dialog.local_servers.model_prompt", server.label, table.concat(verdict.models, ", ")),
			verdict.models[1] or "")
		if typed == nil or typed == "" then return end
		replace_model(id, missing, typed)
	end)
end

--- Offers the fix of a failed request to a local server (the failure handler
--- of modules/llm/local_servers.lua).
--- @param id string Server id.
--- @param kind string A FAILURE_* value of modules/llm/local_servers.lua.
--- @param detail table { status, message, model }.
local function on_failure(id, kind, detail)
	local server = servers().SERVERS[id]
	if kind == servers().FAILURE_NOT_RUNNING then
		notify(i18n.format("llm.local_servers.not_running_title", server.label),
			i18n.format("llm.local_servers.not_running_body", host_of(remote().local_server_target(id).base_url)),
			"warning", function() M.rescan(_ctx, function() M.report_sweep(id) end) end)
	elseif kind == servers().FAILURE_NEEDS_KEY then
		notify(i18n.format("llm.local_servers.needs_key_title", server.label),
			i18n.format("llm.local_servers.needs_key_body", server.label), "warning",
			function() M.prompt_key(_ctx, id) end)
	elseif kind == servers().FAILURE_MODEL_MISSING then
		notify(i18n.format("llm.local_servers.model_missing_title", server.label, detail.model or "?"),
			i18n.get("llm.local_servers.model_missing_body"), "warning",
			function() M.prompt_model(id, detail.model) end)
	end
end
M.on_failure = on_failure

--- Keeps the AI agent menu's context, for the missing-model fix.
--- @param ctx table { state, settings_mgr }.
function M.set_agent_context(ctx)
	_agent_ctx = ctx
end




-- =====================================
-- =====================================
-- ======= 3/ Rows =====================
-- =====================================
-- =====================================

--- The rows of the local servers in the AI engine submenu. Starts a sweep,
--- without waiting for it, when the verdicts are stale.
--- @param ctx table { state, paused, keymap, update_menu, WarmupCtrl, activate_api }.
--- @return table rows
function M.rows(ctx)
	local api_remote = remote()
	if type(api_remote) ~= "table" or type(api_remote.detect_local_servers) ~= "function" then
		-- The AI menu is built from the LLM core, which always carries it
		Logger.error(LOG, "The remote backend is unavailable: no local server row is built.")
		return {}
	end
	_ctx = ctx
	servers().set_failure_handler(on_failure)
	-- A paused script sends nothing: the rows keep the last verdicts
	if not ctx.paused and servers().is_stale() then M.rescan(ctx) end

	local data = servers()
	return ServerMenu.rows({
		order = data.ORDER, servers = data.SERVERS, detected = data.detected(),
		result = data.result, sweeping = data.is_sweeping(), paused = ctx.paused,
		backend = ctx.state.llm_backend, active = remote().get_active_entry(),
		tr = i18n.get, format = i18n.format,
		actions = {
			select = function(id, model) return M.select_model(ctx, id, model) end,
			address = function(id) return M.prompt_address(ctx, id) end,
			key = function(id) return M.prompt_key(ctx, id) end,
			rescan = function() return M.rescan(ctx) end,
		},
	})
end

return M
