--- ui/model_browser/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: LLM Model Browser
--- DESCRIPTION:
--- Projects the shared Ollama catalogue into the shared model-browser page and
--- owns its exact ready/select_model/open_url protocol.
--- ==============================================================================

local M = {}
M.bridge_name = "model_browser_bridge"

local Json = require("json")
local Logger = require("logger.shim")
local ModelCatalogue = require("llm.model_catalogue")
local Paths = require("infra.paths")
local Shell = require("adapters.shell_runner")

local APP_NAME = "model_browser"
local LOG = "bridge.model_browser"

local _catalogue = nil
local _rows_by_name = {}
local _allowed_urls = {}

-- Borrowed, never re-implemented: ModelCatalogue.build decides which row is
-- ACTIVE with this exact rule, and the lookup below decides which rows are
-- INSTALLED. A second copy would let the page mark a model active while
-- reporting it as not installed (llm-model-identity-single-normaliser).
local normalise_name = ModelCatalogue.normalise_name

local function load_catalogue()
	if _catalogue then return _catalogue end
	local path = Paths.shared("modules/llm/models.json")
	local handle = path and io.open(path, "r") or nil
	if not handle then return nil end
	local body = handle:read("*a")
	handle:close()
	local ok, decoded = pcall(Json.decode, body)
	if not ok or type(decoded) ~= "table" then
		Logger.error(LOG, "Shared model catalogue could not be decoded.")
		return nil
	end
	_catalogue = decoded
	return _catalogue
end

local function installed_lookup(state)
	local lookup = {}
	local models = type(state) == "table" and type(state.llm) == "table"
		and type(state.llm.get_models) == "function" and state.llm.get_models() or {}
	for _, name in ipairs(type(models) == "table" and models or {}) do
		lookup[normalise_name(name)] = true
	end
	return lookup
end

local function build_payload(state)
	local installed = installed_lookup(state)
	local current = type(state) == "table" and type(state.llm) == "table"
		and type(state.llm.get_current_model) == "function"
		and state.llm.get_current_model() or ""
	local payload = ModelCatalogue.build(load_catalogue() or {}, "ollama", current,
		function(_display_name, runtime_name)
			return installed[normalise_name(runtime_name)] == true
		end)
	_rows_by_name = {}
	_allowed_urls = {}
	for _, row in ipairs(payload.models) do
		_rows_by_name[row.name] = row
		if type(row.url) == "string" and row.url ~= "" then _allowed_urls[row.url] = true end
	end
	return payload
end

local function push_payload(state)
	local ok_manager, manager = pcall(require, "ui.webview_manager")
	if not ok_manager or type(manager.eval_js) ~= "function" then return false, nil end
	local payload = build_payload(state)
	local ok_json, encoded = pcall(Json.encode, payload)
	if not ok_json or type(encoded) ~= "string" then return false, nil end
	local pushed = manager.eval_js(APP_NAME,
		"if(window.injectModels)window.injectModels(" .. encoded .. ")") == true
	return pushed, payload
end

local function close_owned(context)
	return type(context) == "table" and type(context.close_owned_window) == "function"
		and context.close_owned_window() == true
end

--- Handles the shared page's exact messages.
--- @param payload any
--- @param state table
--- @param context table|nil
--- @return table|nil
function M.on_message(payload, state, context)
	if payload == "ready" or payload == "refresh" then
		if payload == "refresh" and type(state) == "table" and type(state.llm) == "table"
				and type(state.llm.refresh_models) == "function" then
			state.llm.refresh_models()
		end
		local pushed, data = push_payload(state)
		if not pushed then Logger.error(LOG, "Model catalogue could not reach the page.") end
		return { pushed = pushed, data = data }
	end
	if type(payload) ~= "table" then return nil end

	if payload.action == "select_model" and type(payload.name) == "string" then
		local row = _rows_by_name[payload.name]
		if not row then
			Logger.warn(LOG, "Refused unknown model selection '%s'.", payload.name)
			return { selected = false }
		end
		local llm = type(state) == "table" and state.llm or nil
		if row.installed == true then
			local selected = type(llm) == "table" and type(llm.set_model) == "function"
				and llm.set_model(row.runtime_name) == true
			local closed = selected and close_owned(context) or false
			return { selected = selected, closed = closed, model = row.runtime_name }
		end
		local downloading = type(llm) == "table" and type(llm.download_model) == "function"
			and llm.download_model(row.runtime_name, row.name, function(succeeded)
				if succeeded and type(state) == "table"
						and type(state.on_config_changed) == "function" then
					state.on_config_changed()
				end
			end) == true
		local closed = downloading and close_owned(context) or false
		return {
			selected = false,
			downloading = downloading,
			closed = closed,
			model = row.runtime_name,
		}
	end

	if payload.action == "open_url" and type(payload.url) == "string" then
		if _allowed_urls[payload.url] ~= true or not Shell.has_command("xdg-open") then
			Logger.warn(LOG, "Refused model source URL outside the active catalogue.")
			return { opened = false }
		end
		local opened = Shell.run(
			"xdg-open " .. Shell.quote(payload.url) .. " >/dev/null 2>&1 &")
		return { opened = opened }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(payload.action))
	return nil
end

--- Test seam: forgets file and page projections.
function M._reset()
	_catalogue = nil
	_rows_by_name = {}
	_allowed_urls = {}
end

return M
