--- ui/model_browser/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: LLM Model Browser
--- DESCRIPTION:
--- Projects the shared catalogue, the installed models, the API entries and the
--- local servers into the shared model selector page, and runs its actions
--- through the tray's own transactions (the menu binds them; see bind()).
--- Ollama is the local backend; MLX is listed greyed with its reason.
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
-- The menu's transactions and dialogs for the page (bind()).
local _bound = nil
local ModelIdentifier = require("llm.model_identifier")
local BackendBrands = require("modules.llm.backend_brands")

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

--- Strips the native closures of page data before encoding; keeps them by key.
--- @param list table Rows or tools carrying `run` and `actions[i].run`.
--- @param store table key -> run, filled.
--- @param prefix string Key prefix.
--- @return table encoded
local function strip(list, store, prefix)
	local out = {}
	for _, item in ipairs(list or {}) do
		local copy = {}
		for k, v in pairs(item) do
			if k ~= "run" and k ~= "actions" then copy[k] = v end
		end
		local key = prefix .. "\0" .. tostring(item.name or item.id)
		if type(item.run) == "function" then store[key] = item.run end
		if type(item.actions) == "table" then
			copy.actions = {}
			for _, action in ipairs(item.actions) do
				copy.actions[#copy.actions + 1] = { id = action.id, text = action.text }
				if type(action.run) == "function" then store[key .. "\0" .. action.id] = action.run end
			end
		end
		out[#out + 1] = copy
	end
	return out
end

local function backend_entry(id, fields)
	local entry = { id = id, brand = BackendBrands.label(id):match("^(%S+)"), emoji = BackendBrands.emoji(id),
		kind = BackendBrands.kind(id) }
	for k, v in pairs(fields) do entry[k] = v end
	return entry
end

local function build_payload(frame)
	local installed = installed_lookup(frame)
	local current = frame.llm_ports.get_current_model() or ""
	local backend = type(frame.llm.get_backend) == "function" and frame.llm.get_backend() or "ollama"
	local runs = {}
	local catalogue = load_catalogue() or {}
	local in_catalogue = {}
	for _, provider in ipairs(catalogue) do
		for _, family in ipairs(type(provider.families) == "table" and provider.families or {}) do
			for _, model in ipairs(type(family.models) == "table" and family.models or {}) do
				local tag = ModelCatalogue.runtime_name(model, "ollama")
				if tag then in_catalogue[normalise_name(tag)] = true end
			end
		end
	end
	local custom = {}
	for _, name in ipairs(frame.llm_ports.get_cached_models() or {}) do
		if not in_catalogue[normalise_name(name)] then
			custom[#custom + 1] = { name = name, runtime_name = name, custom = true, installed = true }
		end
	end
	local api = _bound and require("ui.menu.llm_backend_rows").api_page(frame.llm, _bound.dialogs,
		_bound.on_changed, _bound.context) or { rows = {}, providers = {}, tools = {} }
	local api_active = nil
	for _, row in ipairs(api.rows) do if row.current then api_active = row.name end end
	local blocked = require("ui.menu.llm_config_guard").reason()
	local payload = ModelCatalogue.build_selector(catalogue, {
		active_backend = backend,
		active_model = backend == "api" and (api_active or "") or current,
		backends = {
			backend_entry("ollama", { available = blocked == nil, reason_key = blocked,
				is_installed = function(_display_name, runtime_name)
					return installed[normalise_name(runtime_name)] == true
				end, extra_rows = custom, add_model = blocked == nil or nil }),
			backend_entry("mlx", { available = false, reason_key = "model_browser.reason_mlx_unsupported_os" }),
			backend_entry("api", { available = blocked == nil, reason_key = blocked,
				extra_rows = strip(api.rows, runs, "api"), actions = strip(api.tools, runs, "tool") }),
		},
		capabilities = { disable = true },
	})
	local providers = strip(api.providers, runs, "provider")
	for _, b in ipairs(payload.backends) do
		if b.id == "api" then
			b.actions = strip(api.tools, runs, "tool")
			b.providers = providers
		elseif b.id == "ollama" then
			b.add_model = blocked == nil or nil
		end
	end
	local rows, urls = {}, {}
	for _, row in ipairs(payload.models) do
		rows[(row.backend or "") .. "\0" .. row.name] = row
		if type(row.url) == "string" and row.url ~= "" then urls[row.url] = true end
	end
	return payload, rows, urls, runs
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
	local payload, rows, urls, runs = build_payload(frame)
	if not projection_current(frame) then return false, nil end
	local ok_json, encoded = pcall(Json.encode, payload)
	if not ok_json or type(encoded) ~= "string" or not projection_current(frame) then return false, nil end
	local called, accepted = pcall(frame.manager_ports.eval_owned_js, APP_NAME, frame.document,
		"if(window.injectModels)window.injectModels(" .. encoded .. ")")
	local pushed = called and accepted == true and projection_current(frame)
	if pushed then frame.rows, frame.urls, frame.runs = rows, urls, runs end
	return pushed, payload
end

local function capture_projection(state, context)
	if type(state) ~= "table" or type(state.llm) ~= "table" or type(context) ~= "table"
		or context.app_name ~= APP_NAME or context.epoch ~= _page_epoch or context.document_owner == nil then return nil end
	local manager = package.loaded["ui.webview_manager"]
	if type(manager) ~= "table" then return nil end
	local frame = { state = state, llm = state.llm, manager = manager, document = context.document_owner,
		epoch = context.epoch, manager_ports = {}, llm_ports = {}, rows = {}, urls = {}, runs = {} }
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

	local blocked = require("ui.menu.llm_config_guard").reason()
	if blocked ~= nil and payload.action ~= "open_url" then
		Logger.warn(LOG, "Model selector action '%s' refused: %s.", tostring(payload.action), blocked)
		return { accepted = false }
	end
	local backend = type(payload.backend) == "string" and payload.backend or "ollama"
	local function run(key)
		local fn = frame.runs[key]
		if type(fn) ~= "function" or not projection_current(frame) then return false end
		local ok, result = pcall(fn)
		if not ok then Logger.error(LOG, "Model selector action failed: %s", tostring(result)) end
		return ok and result ~= false
	end
	local function changed()
		if type(state) == "table" and type(state.on_config_changed) == "function" then state.on_config_changed() end
	end

	if payload.action == "disable_model" then
		local done = type(frame.llm_ports.set_model) == "function" and frame.llm_ports.set_model("") == true
		if done then changed() end
		return { selected = done, closed = done and close_owned(context) or false }
	end
	if payload.action == "group_action" and type(payload.id) == "string" then
		return { accepted = run("tool\0" .. payload.id) }
	end
	if payload.action == "add_provider" and type(payload.provider) == "string" then
		return { accepted = run("provider\0" .. payload.provider) }
	end
	if payload.action == "add_model" and type(payload.name) == "string" then
		if backend ~= "ollama" or not ModelIdentifier.valid("ollama", payload.name) then
			Logger.warn(LOG, "Refused adding '%s': not a valid Ollama name.", payload.name)
			return { downloading = false }
		end
		local downloading = type(frame.llm_ports.download_model) == "function" and projection_current(frame)
			and frame.llm_ports.download_model(payload.name, payload.name, function(succeeded)
				if succeeded then changed() end
			end) == true
		Logger.info(LOG, "Model added via the selector page: %s.", payload.name)
		return { downloading = downloading }
	end
	if type(payload.name) ~= "string" then return nil end
	local row = frame.rows[backend .. "\0" .. payload.name]
	if not row then
		Logger.warn(LOG, "Refused model selector action '%s' for an unknown row '%s'.", tostring(payload.action), payload.name)
		return { selected = false }
	end
	if payload.action == "row_action" and type(payload.id) == "string" then
		return { accepted = run("api\0" .. row.name .. "\0" .. payload.id) }
	end
	if backend == "api" then
		if payload.action ~= "select_model" or row.available == false then return { selected = false } end
		local selected = run("api\0" .. row.name)
		return { selected = selected, closed = selected and close_owned(context) or false }
	end
	if backend ~= "ollama" then return { selected = false } end

	if payload.action == "select_model" then
		-- Only an installed model can be made active; a missing one offers its download.
		if row.installed ~= true then return { selected = false } end
		local selected = type(frame.llm_ports.set_model) == "function" and projection_current(frame)
		if selected and type(frame.llm.get_backend) == "function" and frame.llm.get_backend() ~= "ollama" then
			selected = frame.llm.set_backend("ollama") == true
		end
		selected = selected and frame.llm_ports.set_model(row.runtime_name) == true
		if selected then changed() end
		local closed = selected and close_owned(context) or false
		return { selected = selected, closed = closed, model = row.runtime_name }
	end
	if payload.action == "download_model" then
		if row.installed == true then return { downloading = false } end
		local downloading = type(frame.llm_ports.download_model) == "function" and projection_current(frame)
			and frame.llm_ports.download_model(row.runtime_name, row.name, function(succeeded)
				if succeeded then changed() end
			end) == true
		return { selected = false, downloading = downloading, model = row.runtime_name }
	end
	if payload.action == "delete_model" or payload.action == "remove_custom_model" then
		if row.installed ~= true or not _bound or type(_bound.delete_model) ~= "function" then return { deleted = false } end
		return { deleted = _bound.delete_model(row.runtime_name) == true }
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

--- Binds the menu's transactions and dialogs the page runs. The menu builder
--- binds them on every build, so the page acts with the current ones.
--- @param options table { llm, dialogs, on_changed, delete_model, context }
function M.bind(options)
	if type(options) ~= "table" or type(options.dialogs) ~= "table" or type(options.delete_model) ~= "function" then
		error("model_browser bridge bind requires dialogs and delete_model", 2)
	end
	_bound = options
end

--- Test seam: forgets file and page projections.
function M._reset()
	_catalogue = nil
	_projection, _page_epoch = nil, nil
	_bound = nil
end

return M
