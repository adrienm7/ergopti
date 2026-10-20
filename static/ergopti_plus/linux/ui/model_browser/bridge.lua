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
local _projection, _page_epoch = nil, nil

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

local function installed_lookup(frame)
	local lookup = {}
	local models = frame.llm_ports.get_cached_models()
	for _, name in ipairs(type(models) == "table" and models or {}) do
		lookup[normalise_name(name)] = true
	end
	return lookup
end

local function build_payload(frame)
	local installed = installed_lookup(frame)
	local current = frame.llm_ports.get_current_model() or ""
	local payload = ModelCatalogue.build(load_catalogue() or {}, "ollama", current,
		function(_display_name, runtime_name)
			return installed[normalise_name(runtime_name)] == true
		end)
	local rows, urls = {}, {}
	for _, row in ipairs(payload.models) do
		rows[row.name] = row
		if type(row.url) == "string" and row.url ~= "" then urls[row.url] = true end
	end
	return payload, rows, urls
end

local function retained(frame)
	if not frame or _projection ~= frame or _page_epoch ~= frame.epoch
		or package.loaded["ui.webview_manager"] ~= frame.manager or frame.state.llm ~= frame.llm then return false end
	for name, port in pairs(frame.manager_ports) do if frame.manager[name] ~= port then return false end end
	for name, port in pairs(frame.llm_ports) do if frame.llm[name] ~= port then return false end end
	return true
end

local function projection_current(frame)
	if not retained(frame) then return false end
	local ports = frame.manager_ports
	local state, epoch = ports.get_daemon_state(), ports.current_epoch(APP_NAME)
	if not retained(frame) or state ~= frame.state or epoch ~= frame.epoch then return false end
	local ok, current = pcall(ports.document_owner_current, frame.document)
	if not ok or current ~= true or not retained(frame) then return false end
	return ports.document_owner_retained(frame.document) == true and retained(frame)
end

local function push_payload(frame)
	if not projection_current(frame) then return false, nil end
	local payload, rows, urls = build_payload(frame)
	if not projection_current(frame) then return false, nil end
	local ok_json, encoded = pcall(Json.encode, payload)
	if not ok_json or type(encoded) ~= "string" or not projection_current(frame) then return false, nil end
	local called, accepted = pcall(frame.manager_ports.eval_owned_js, APP_NAME, frame.document,
		"if(window.injectModels)window.injectModels(" .. encoded .. ")")
	local pushed = called and accepted == true and projection_current(frame)
	if pushed then frame.rows, frame.urls = rows, urls end
	return pushed, payload
end

local function capture_projection(state, context)
	if type(state) ~= "table" or type(state.llm) ~= "table" or type(context) ~= "table"
		or context.app_name ~= APP_NAME or context.epoch ~= _page_epoch or context.document_owner == nil then return nil end
	local manager = package.loaded["ui.webview_manager"]
	if type(manager) ~= "table" then return nil end
	local frame = { state = state, llm = state.llm, manager = manager, document = context.document_owner,
		epoch = context.epoch, manager_ports = {}, llm_ports = {}, rows = {}, urls = {} }
	for _, name in ipairs({ "capture_document_owner", "document_owner_current", "document_owner_retained",
		"eval_owned_js", "get_daemon_state", "current_epoch" }) do
		if type(manager[name]) ~= "function" then return nil end
		frame.manager_ports[name] = manager[name]
	end
	for _, name in ipairs({ "get_cached_models", "get_current_model", "refresh_models" }) do
		if type(state.llm[name]) ~= "function" then return nil end
		frame.llm_ports[name] = state.llm[name]
	end
	for _, name in ipairs({ "set_model", "download_model" }) do
		if type(state.llm[name]) == "function" then frame.llm_ports[name] = state.llm[name] end
	end
	_projection = frame
	if not projection_current(frame) or frame.manager_ports.capture_document_owner(APP_NAME) ~= frame.document
		or not projection_current(frame) then
		if _projection == frame then _projection = nil end
		return nil
	end
	return frame
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
		local frame = payload == "ready" and capture_projection(state, context) or _projection
		if not frame or frame.state ~= state or type(context) ~= "table" or context.document_owner ~= frame.document
			or not projection_current(frame) then return nil end
		frame.llm_ports.refresh_models()
		local pushed, data = push_payload(frame)
		if not pushed then Logger.error(LOG, "Model catalogue could not reach the page.") end
		return { pushed = pushed, data = data }
	end
	if type(payload) ~= "table" then return nil end
	local frame = _projection
	if not frame or frame.state ~= state or type(context) ~= "table" or context.document_owner ~= frame.document
		or not projection_current(frame) then return nil end

	if payload.action == "select_model" and type(payload.name) == "string" then
		local row = frame.rows[payload.name]
		if not row then
			Logger.warn(LOG, "Refused unknown model selection '%s'.", payload.name)
			return { selected = false }
		end
		if row.installed == true then
			local selected = type(frame.llm_ports.set_model) == "function" and projection_current(frame)
				and frame.llm_ports.set_model(row.runtime_name) == true
			local closed = selected and close_owned(context) or false
			return { selected = selected, closed = closed, model = row.runtime_name }
		end
		local downloading = type(frame.llm_ports.download_model) == "function" and projection_current(frame)
			and frame.llm_ports.download_model(row.runtime_name, row.name, function(succeeded)
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
		if frame.urls[payload.url] ~= true or not Shell.has_command("xdg-open") or not projection_current(frame) then
			Logger.warn(LOG, "Refused model source URL outside the active catalogue.")
			return { opened = false }
		end
		local command = "xdg-open " .. Shell.quote(payload.url) .. " >/dev/null 2>&1 &"
		local opened = projection_current(frame) and Shell.run(command) == true
		return { opened = opened }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(payload.action))
	return nil
end

--- Reprojects the contemporary service cache into only its current document.
--- @return boolean pushed No network acquisition is started.
function M.reproject_current()
	local frame = _projection
	if not projection_current(frame) then return false end
	local document = frame.manager_ports.capture_document_owner(APP_NAME)
	if document ~= frame.document or not projection_current(frame) then return false end
	return push_payload(frame)
end

--- Retires the old page projection before a successor native acquisition.
--- @param epoch number Exact Manager window epoch.
--- @return boolean accepted
function M.on_window_acquiring(epoch)
	_page_epoch, _projection = epoch, nil
	return true
end

--- Forgets only the closing page's projection; its successor keeps its own rows.
--- @param epoch number Exact closing Manager window epoch.
function M.on_window_closed(epoch)
	if _page_epoch == epoch then _page_epoch, _projection = nil, nil end
end

--- Test seam: forgets file and page projections.
function M._reset()
	_catalogue = nil
	_projection, _page_epoch = nil, nil
end

return M
