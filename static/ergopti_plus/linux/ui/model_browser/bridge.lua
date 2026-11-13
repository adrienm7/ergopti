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

local Json = require("core.text.engine.json")
local Logger = require("core.logger.engine.shim")
local ModelCatalogue = require("ai.engine.local_servers.model_catalogue")
local Paths = require("infra.paths")
local Shell = require("adapters.shell_runner")

local APP_NAME = "model_browser"
local LOG = "bridge.model_browser"

local _catalogue = nil
local _projection, _page_epoch = nil, nil
-- The menu's transactions and dialogs for the page (bind()).
local _bound = nil
local ModelIdentifier = require("ai.engine.local_servers.model_identifier")
local BackendBrands = require("modules.llm.backend_brands")
local ApiModelListing = require("ai.engine.api.model_listing")

-- Borrowed, never re-implemented: ModelCatalogue.build decides which row is
-- ACTIVE with this exact rule, and the lookup below decides which rows are
-- INSTALLED. A second copy would let the page mark a model active while
-- reporting it as not installed (llm-model-identity-single-normaliser).
local normalise_name = ModelCatalogue.normalise_name

local function load_catalogue()
	if _catalogue then return _catalogue end
	local path = Paths.shared("ai/data/models.json")
	local body = path and require("infra.regular_file_reader").read_source(path) or nil
	if not body then return nil end
	local ok, decoded = pcall(Json.decode, body)
	if not ok or type(decoded) ~= "table" then
		Logger.error(LOG, "Shared model catalogue could not be decoded.")
		return nil
	end
	_catalogue = decoded
	return _catalogue
end

local function installed_lookup(models)
	local lookup = {}
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
	local entry = { id = id, brand = BackendBrands.brand(id), emoji = BackendBrands.emoji(id),
		kind = BackendBrands.kind(id) }
	for k, v in pairs(fields) do entry[k] = v end
	return entry
end

--- Where the Ollama group's "Install Ollama" button stands. Linux installs
--- Ergopti's own Ollama through the AI enable, which offers its download when
--- Ollama is missing, so the button acts only while the AI is off.
--- @param frame table The page projection.
--- @param blocked string|nil The config.toml refusal reason.
--- @param ollama_ok boolean Whether Ollama can run a model now.
--- @return table|nil install { state, reason_key? }; nil before a menu bound the page.
local function ollama_install(frame, blocked, ollama_ok)
	if not _bound then return nil end
	if blocked ~= nil then return { state = "unsupported", reason_key = blocked } end
	-- Named for the install, not "phase": a log phase belongs to the closed logger vocabulary.
	local install_step = _bound.ollama_install_phase(frame.llm)
	if install_step == "running" then return { state = "running" } end
	if ollama_ok then return { state = "installed" } end
	if install_step == "ai_on" then return { state = "unsupported", reason_key = "model_browser.reason_install_ai_on" } end
	return { state = "available", failed_key = frame.install_refused }
end

local projection_current

local function build_payload(frame, force_unknown)
	local models, inventory_known, inventory_identity
	if force_unknown then models, inventory_known = {}, false
	else
		local ok
		ok, models, inventory_known, inventory_identity = pcall(frame.llm_ports.get_cached_models_status)
		if not ok then models, inventory_known, inventory_identity = {}, false, nil end
	end
	if inventory_known ~= true or type(inventory_identity) ~= "table" then
		models, inventory_known, inventory_identity = {}, false, nil
	end
	local installed = installed_lookup(models)
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
	for _, name in ipairs(type(models) == "table" and models or {}) do
		if not in_catalogue[normalise_name(name)] then
			custom[#custom + 1] = { name = name, runtime_name = name, custom = true, installed = true }
		end
	end
	local api = _bound and require("ui.menu.llm_backend_rows").api_page(frame.llm, _bound.dialogs,
		_bound.on_changed, _bound.context, frame.listings, function() return projection_current(frame) end) or { rows = {}, providers = {}, tools = {} }
	local api_active = nil
	for _, row in ipairs(api.rows) do if row.current then api_active = row.name end end
	local blocked = require("ui.menu.llm_config_guard").reason()
	-- A config.toml that refuses writes wins; else Ollama's own install state.
	local ollama_ok, ollama_reason = true, nil
	if blocked == nil and _bound and type(_bound.ollama_state) == "function" then
		ollama_ok, ollama_reason = _bound.ollama_state(frame.llm)
	end
	local payload = ModelCatalogue.build_selector(catalogue, {
		active_backend = backend,
		active_model = backend == "api" and (api_active or "") or current,
		backends = {
			backend_entry("ollama", { available = blocked == nil and ollama_ok, reason_key = blocked or ollama_reason,
				is_installed = function(_display_name, runtime_name)
					return installed[normalise_name(runtime_name)] == true
				end, extra_rows = custom, add_model = (blocked == nil and ollama_ok) or nil }),
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
			b.add_model = (blocked == nil and ollama_ok) or nil
			b.install = ollama_install(frame, blocked, ollama_ok)
		elseif b.id == "mlx" then
			b.install = { state = "unsupported", reason_key = "model_browser.reason_mlx_unsupported_os" }
		end
	end
	local rows, urls = {}, {}
	for _, row in ipairs(payload.models) do
		if row.backend == "ollama" and inventory_known ~= true then
			row.available = false
			row.inventory_unknown = true
			row.hint_key = "model_browser.inventory_unavailable"
		end
		-- A pull still running keeps its percentage across a new payload.
		local percent = row.backend == "ollama" and frame.progress[row.runtime_name] or nil
		if percent ~= nil then row.pending, row.progress = "download", percent end
		rows[(row.backend or "") .. "\0" .. row.name] = row
		if type(row.url) == "string" and row.url ~= "" then urls[row.url] = true end
	end
	return payload, rows, urls, runs, models, inventory_known == true, inventory_identity
end

local function retained(frame)
	if not frame or _projection ~= frame or _page_epoch ~= frame.epoch
		or package.loaded["ui.webview_manager"] ~= frame.manager or frame.state.llm ~= frame.llm then return false end
	for name, port in pairs(frame.manager_ports) do if frame.manager[name] ~= port then return false end end
	for name, port in pairs(frame.llm_ports) do if frame.llm[name] ~= port then return false end end
	return true
end

projection_current = function(frame)
	if not retained(frame) then return false end
	local ports = frame.manager_ports
	local state, epoch = ports.get_daemon_state(), ports.current_epoch(APP_NAME)
	if not retained(frame) or state ~= frame.state or epoch ~= frame.epoch then return false end
	local ok, current = pcall(ports.document_owner_current, frame.document)
	if not ok or current ~= true or not retained(frame) then return false end
	return ports.document_owner_retained(frame.document) == true and retained(frame)
end

--- Checks that the model observation still belongs to the current runtime.
local function inventory_current(frame, models, known, identity)
	local ok, current, current_known, current_identity = pcall(frame.llm_ports.get_cached_models_status)
	if not ok or (current_known == true) ~= known or type(current) ~= "table" then return false end
	if not known then return true end
	if type(identity) ~= "table" or not rawequal(identity, current_identity) then return false end
	if type(models) ~= "table" or #models ~= #current then return false end
	for index, name in ipairs(models) do if current[index] ~= name then return false end end
	return true
end

local function push_payload(frame, force_unknown)
	frame.projection_serial = (frame.projection_serial or 0) + 1
	local serial = frame.projection_serial
	local function owned_projection()
		return frame.projection_serial == serial and projection_current(frame) and frame.projection_serial == serial
	end
	if not owned_projection() then return false, nil end
	local payload, rows, urls, runs, models, known, identity = build_payload(frame, force_unknown)
	if not owned_projection() then return false, nil end
	local ok_json, encoded = pcall(Json.encode, payload)
	if not ok_json or type(encoded) ~= "string" or not owned_projection() then return false, nil end
	if not force_unknown and not inventory_current(frame, models, known, identity) then
		if frame.projection_serial ~= serial then return false, nil end
		return push_payload(frame, true)
	end
	if frame.projection_serial ~= serial then return false, nil end
	local called, accepted = pcall(frame.manager_ports.eval_owned_js, APP_NAME, frame.document,
		"if(window.injectModels)window.injectModels(" .. encoded .. ")")
	local pushed = called and accepted == true and owned_projection()
	if pushed and not force_unknown and not inventory_current(frame, models, known, identity) then
		if frame.projection_serial ~= serial then return false, nil end
		return push_payload(frame, true)
	end
	if frame.projection_serial ~= serial then return false, nil end
	if pushed then
		frame.rows, frame.urls, frame.runs = rows, urls, runs
		frame.inventory_known, frame.inventory_identity = known, identity
	end
	return pushed, payload
end

--- Asks the next queued API entry's provider for its models; each answer
--- re-sends the payload to this page only, then asks the next entry.
--- @param frame table The page projection.
--- @param list function The bound listing port (api_remote.list_models).
local function next_listing(frame, list)
	local queue = frame.listing_queue
	if type(queue) ~= "table" or #queue == 0 or not projection_current(frame) then return false end
	local entry = table.remove(queue, 1)
	local delivered = false
	local called, dispatched = pcall(list, entry, function(listing)
		if delivered or not projection_current(frame) then return end
		delivered = true
		frame.listings[entry.id] = type(listing) == "table" and listing or { state = "failed", reason = "unavailable" }
		push_payload(frame)
		next_listing(frame, list)
	end)
	if (not called or dispatched == false) and not delivered then
		Logger.error(LOG, "Remote model listing could not be dispatched.")
		if not projection_current(frame) then return false end
		delivered = true
		frame.listings[entry.id] = { state = "failed", reason = "unavailable" }
		push_payload(frame)
		return next_listing(frame, list)
	end
	return true
end

--- Lists each chat API entry's models once per page, at most
--- ApiModelListing.MAX_ENTRIES of them, one request at a time, through the
--- ports the menu bound (llm_backend_rows.bind_page).
--- @param frame table The page projection.
local function start_listings(frame)
	local port = _bound and _bound.listing
	if frame.listing_queue ~= nil or type(port) ~= "table" or type(port.targets) ~= "function"
		or type(port.list) ~= "function" then return false end
	frame.listing_queue = {}
	for _, entry in ipairs(port.targets()) do
		if #frame.listing_queue >= ApiModelListing.MAX_ENTRIES then break end
		frame.listings[entry.id] = { state = "pending" }
		frame.listing_queue[#frame.listing_queue + 1] = entry
	end
	Logger.info(LOG, "Model selector page lists the models of %d API entry(ies).", #frame.listing_queue)
	return next_listing(frame, port.list)
end

local function capture_projection(state, context)
	if type(state) ~= "table" or type(state.llm) ~= "table" or type(context) ~= "table"
		or context.app_name ~= APP_NAME or context.epoch ~= _page_epoch or context.document_owner == nil then return nil end
	local manager = package.loaded["ui.webview_manager"]
	if type(manager) ~= "table" then return nil end
	local frame = { state = state, llm = state.llm, manager = manager, document = context.document_owner,
		epoch = context.epoch, manager_ports = {}, llm_ports = {}, rows = {}, urls = {}, runs = {},
		listings = {}, listing_queue = nil, progress = {} }
	for _, name in ipairs({ "capture_document_owner", "document_owner_current", "document_owner_retained",
		"eval_owned_js", "get_daemon_state", "current_epoch" }) do
		if type(manager[name]) ~= "function" then return nil end
		frame.manager_ports[name] = manager[name]
	end
	for _, name in ipairs({ "get_cached_models", "get_cached_models_status", "get_current_model", "refresh_models" }) do
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
		if pushed then start_listings(frame) end
		return { pushed = pushed, data = data }
	end
	if type(payload) ~= "table" then return nil end
	local frame = _projection
	if not frame or frame.state ~= state or type(context) ~= "table" or context.document_owner ~= frame.document
		or not projection_current(frame) then return nil end

	local blocked = require("ui.menu.llm_config_guard").reason()
	if blocked ~= nil and payload.action ~= "open_url" then
		Logger.warn(LOG, "Model selector action '%s' refused: %s.", tostring(payload.action), blocked)
		-- The page drew an install click as running: only a payload undoes it.
		push_payload(frame)
		return { accepted = false }
	end
	local backend = type(payload.backend) == "string" and payload.backend or "ollama"
	local function run(key)
		local fn = frame.runs[key]
		if type(fn) ~= "function" or not projection_current(frame) then return false end
		local ok, result = pcall(fn)
		if not ok then Logger.error(LOG, "Model selector action %s raised an error.", payload.action) end
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
	if payload.action == "group_action" and backend == "ollama" and payload.id == "install" then
		local ollama_ok = not _bound or _bound.ollama_state(frame.llm) == true
		local install = ollama_install(frame, nil, ollama_ok)
		if not install or install.state ~= "available" then
			Logger.warn(LOG, "Refused installing Ollama from the page: it is not offered now.")
			push_payload(frame)
			return { accepted = false }
		end
		Logger.info(LOG, "Installing Ollama from the model selector page through the AI enable.")
		frame.install_refused = nil
		local accepted = _bound.install_ollama(frame.llm, function()
			changed()
			M.reproject_current()
		end) == true
		if not accepted then
			frame.install_refused = "model_browser.install_not_started"
			Logger.error(LOG, "The Ollama install from the model selector page was not started.")
		end
		push_payload(frame)
		return { accepted = accepted }
	end
	if payload.action == "group_action" and type(payload.id) == "string" then
		return { accepted = run("tool\0" .. payload.id) }
	end
	if payload.action == "add_provider" and type(payload.provider) == "string" then
		return { accepted = run("provider\0" .. payload.provider) }
	end
	-- An Ollama that is absent or whose repair failed runs no model action.
	local function ollama_ready()
		if not _bound or type(_bound.ollama_state) ~= "function" or _bound.ollama_state(frame.llm) == true then
			return true
		end
		Logger.warn(LOG, "Model selector action '%s' refused: Ollama cannot run now.", tostring(payload.action))
		return false
	end
	if payload.action == "add_model" and type(payload.name) == "string" then
		if backend ~= "ollama" or not ModelIdentifier.valid("ollama", payload.name) then
			Logger.warn(LOG, "Refused adding '%s': not a valid Ollama name.", payload.name)
			return { downloading = false }
		end
		if not ollama_ready() then return { downloading = false } end
		local downloading = type(frame.llm_ports.download_model) == "function" and projection_current(frame)
			and frame.llm_ports.download_model(payload.name, payload.name, function(succeeded)
				if succeeded then changed() end
			end) == true
		if downloading then
			Logger.info(LOG, "Model download requested via the selector page: %s.", payload.name)
		else
			Logger.warn(LOG, "Model download could not be started via the selector page: %s.", payload.name)
		end
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
	if payload.action ~= "open_url" and not ollama_ready() then return { selected = false } end

	local function installed_now()
		if not projection_current(frame) then return nil end
		local ok, models, known, identity = pcall(frame.llm_ports.get_cached_models_status)
		if not ok or known ~= true or type(models) ~= "table" or frame.inventory_known ~= true
			or not rawequal(identity, frame.inventory_identity) or not projection_current(frame) then return nil end
		-- The document probe above can itself retire the inventory source. Read
		-- it again after that callback and use only pure retained-frame checks
		-- before handing the decision to its immediate caller.
		ok, models, known, identity = pcall(frame.llm_ports.get_cached_models_status)
		if not ok or known ~= true or type(models) ~= "table" or not rawequal(identity, frame.inventory_identity)
			or not retained(frame) then return nil end
		local target = normalise_name(row.runtime_name)
		for _, model in ipairs(models) do
			if type(model) ~= "string" then return nil end
			if normalise_name(model) == target then return retained(frame) and true or nil end
		end
		if not retained(frame) then return nil end
		return false
	end
	if payload.action == "select_model" then
		-- Only a still-installed model can be made active.
		local live_installed = installed_now()
		if row.installed ~= true or live_installed ~= true then
			if live_installed ~= nil and projection_current(frame) then push_payload(frame) end
			return { selected = false }
		end
		local selected = type(frame.llm_ports.set_model) == "function" and projection_current(frame)
		if selected and type(frame.llm.get_backend) == "function" and frame.llm.get_backend() ~= "ollama" then
			selected = projection_current(frame)
				and frame.llm.set_backend("ollama", function() return projection_current(frame) end) == true
		end
		selected = selected and installed_now() == true and frame.llm_ports.set_model(row.runtime_name) == true
		if selected then changed() end
		local closed = selected and close_owned(context) or false
		return { selected = selected, closed = closed, model = row.runtime_name }
	end
	if payload.action == "download_model" then
		local live_installed = installed_now()
		if row.installed == true or live_installed ~= false then
			if live_installed ~= nil and projection_current(frame) then push_payload(frame) end
			return { downloading = false }
		end
		local downloading = type(frame.llm_ports.download_model) == "function"
			and frame.llm_ports.download_model(row.runtime_name, row.name, function(succeeded)
				if succeeded then changed() end
			end) == true
		return { selected = false, downloading = downloading, model = row.runtime_name }
	end
	if payload.action == "delete_model" or payload.action == "remove_custom_model" then
		local live_installed = installed_now()
		if row.installed ~= true or not _bound or type(_bound.delete_model) ~= "function" or live_installed ~= true then
			if live_installed ~= nil and projection_current(frame) then push_payload(frame) end
			return { deleted = false }
		end
		return { deleted = _bound.delete_model(row.runtime_name, function() return installed_now() == true end) == true }
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

--- Shows a pull's percentage on the open page's row of that model.
--- @param tag string Ollama model tag being pulled.
--- @param percent number|nil Whole percentage; nil once the pull ended.
--- @return boolean shown
function M.on_download_progress(tag, percent)
	local frame = _projection
	if type(tag) ~= "string" or not projection_current(frame) then return false end
	frame.progress[tag] = percent
	if percent == nil then return false end
	for _, row in pairs(frame.rows) do
		if row.backend == "ollama" and row.runtime_name == tag then
			local ok_json, encoded = pcall(Json.encode, { backend = "ollama", name = row.name, percent = percent })
			if not ok_json or type(encoded) ~= "string" then return false end
			local called, accepted = pcall(frame.manager_ports.eval_owned_js, APP_NAME, frame.document,
				"if(window.injectProgress)window.injectProgress(" .. encoded .. ")")
			return called and accepted == true
		end
	end
	return false
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
--- @param options table { llm, dialogs, on_changed, delete_model, context,
---   ollama_state, ollama_install_phase, install_ollama }
function M.bind(options)
	if type(options) ~= "table" or type(options.dialogs) ~= "table" or type(options.delete_model) ~= "function" then
		error("model_browser bridge bind requires dialogs and delete_model", 2)
	end
	for _, name in ipairs({ "ollama_state", "ollama_install_phase", "install_ollama" }) do
		if type(options[name]) ~= "function" then error("model_browser bridge bind requires " .. name, 2) end
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
