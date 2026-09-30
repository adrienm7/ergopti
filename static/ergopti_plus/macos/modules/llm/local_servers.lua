--- modules/llm/local_servers.lua

--- ==============================================================================
--- MODULE: Local OpenAI-Compatible Servers
--- DESCRIPTION:
--- The local servers of _shared/modules/llm/local_servers.json (oMLX,
--- LM Studio, llama.cpp / LocalAI, Jan) that the user installed and runs,
--- which of them answer right now, and the models each one serves.
---
--- FEATURES & RATIONALE:
--- 1. Detection, never installation: a server is listed only when its models
---    endpoint answers. A sweep probes every server at once through a probe
---    the caller injects (api_remote owns the HTTP transport, the address and
---    the key), so the main thread never waits and tests fake the transport.
---    A newer sweep supersedes an older one: a late answer is dropped.
--- 2. A 401 or 403 is an answer: the server runs and wants a key, which the
---    menu then asks for.
--- 3. Requests take the openai format of api_providers.json: api_remote
---    registers each server as a provider needing no key, so predictions, the
---    agent and screen reading follow the paths of a remote provider.
--- 4. A request failure is classified (not running, key wanted, model absent)
---    and reported once to the handler the menu registers, which offers the
---    fix; a success or a sweep that finds the server up clears it.
--- 5. An address or a key typed before any model is chosen waits here, for
---    this session, until the chosen model creates the server's API entry.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local Paths          = require("infra.paths")
local FileSystem     = require("adapters.file_system")
local JsonCodec      = require("adapters.json_codec")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "llm.local_servers"





-- =====================================
-- =====================================
-- ======= 1/ Constants ================
-- =====================================
-- =====================================

-- What a probe found
M.STATUS_UP        = "up"          -- the models endpoint listed the models
M.STATUS_NEEDS_KEY = "needs_key"   -- the server answered 401 or 403
M.STATUS_DOWN      = "down"        -- nothing, or something else, answered

-- Why a request to a local server failed
M.FAILURE_NOT_RUNNING   = "not_running"
M.FAILURE_NEEDS_KEY     = "needs_key"
M.FAILURE_MODEL_MISSING = "model_missing"





-- =====================================
-- =====================================
-- ======= 2/ Catalogue ================
-- =====================================
-- =====================================

--- Reads local_servers.json. A missing or malformed file is logged and gives an
--- empty catalogue: the AI menu then lists no local server, and nothing else of
--- the LLM stack depends on it.
--- @return table order Server ids in menu order.
--- @return table servers Server id -> { id, label, base_url }.
local function load_catalogue()
	local path = Paths.shared_llm_path("local_servers.json")
	local raw, status = nil, "error"
	if path then raw, status = FileSystem.read_with_status(path) end
	if status ~= "ok" or type(raw) ~= "string" then
		Logger.error(LOG, "local_servers.json is unreadable at %s (%s): no local server is detected.",
			tostring(path), tostring(status))
		return {}, {}
	end
	local ok, root = pcall(JsonCodec.decode, raw)
	if not ok or type(root) ~= "table" or type(root.server_order) ~= "table" or type(root.servers) ~= "table" then
		Logger.error(LOG, "local_servers.json is malformed: no local server is detected.")
		return {}, {}
	end
	local order, servers = {}, {}
	for _, id in ipairs(root.server_order) do
		local desc = type(id) == "string" and root.servers[id] or nil
		local valid = type(desc) == "table" and id:match("^[a-z][a-z0-9_]*$") ~= nil and servers[id] == nil
			and type(desc.label) == "string" and desc.label ~= ""
			and type(desc.base_url) == "string" and desc.base_url:match("^https?://%S+$") ~= nil
		if valid then
			servers[id] = { id = id, label = desc.label, base_url = desc.base_url }
			order[#order + 1] = id
		else
			Logger.error(LOG, "local_servers.json: server '%s' has an invalid descriptor and is skipped.", tostring(id))
		end
	end
	return order, servers
end

M.ORDER, M.SERVERS = load_catalogue()

--- Tells whether an id names a server of the catalogue.
--- @param id any
--- @return boolean
function M.is_local(id)
	return type(id) == "string" and M.SERVERS[id] ~= nil
end





-- =====================================
-- =====================================
-- ======= 3/ Probe Verdicts ===========
-- =====================================
-- =====================================

--- Reads the model ids of an OpenAI models answer ({ data = { { id }, … } }),
--- in the server's order.
--- @param body any The answer body.
--- @return table|nil ids Nil when the body is not a models list.
function M.models_from_body(body)
	if type(body) ~= "string" or body == "" then return nil end
	local ok, decoded = pcall(JsonCodec.decode, body)
	if not ok or type(decoded) ~= "table" or type(decoded.data) ~= "table" then return nil end
	local ids = {}
	for _, model in ipairs(decoded.data) do
		if type(model) == "table" and type(model.id) == "string" and model.id ~= "" then ids[#ids + 1] = model.id end
	end
	return ids
end

--- Tells what answered a models probe.
--- @param response table|nil { ok, status, body } of the HTTP adapter.
--- @return string status M.STATUS_UP, M.STATUS_NEEDS_KEY or M.STATUS_DOWN.
--- @return table|nil models The model ids when the server is up.
function M.classify(response)
	if type(response) ~= "table" then return M.STATUS_DOWN, nil end
	local status = tonumber(response.status) or 0
	if status == 401 or status == 403 then return M.STATUS_NEEDS_KEY, nil end
	if response.ok ~= true then return M.STATUS_DOWN, nil end
	local models = M.models_from_body(response.body)
	-- A 200 that is not a models list is another service on that port
	if not models then return M.STATUS_DOWN, nil end
	return M.STATUS_UP, models
end

--- Tells why a request to a local server failed, when the user can fix it.
--- @param status number|nil HTTP status, 0 or nil when nothing answered.
--- @param message string|nil The server's error message.
--- @return string|nil kind A M.FAILURE_* value, nil for any other failure.
function M.classify_failure(status, message)
	status = tonumber(status) or 0
	if status == 0 then return M.FAILURE_NOT_RUNNING end
	if status == 401 or status == 403 then return M.FAILURE_NEEDS_KEY end
	if status == 404 then return M.FAILURE_MODEL_MISSING end
	local text = type(message) == "string" and message:lower() or ""
	if status == 400 and text:find("model", 1, true)
		and (text:find("not found", 1, true) or text:find("not loaded", 1, true)
			or text:find("does not exist", 1, true) or text:find("no model", 1, true)) then
		return M.FAILURE_MODEL_MISSING
	end
	return nil
end





-- =====================================
-- =====================================
-- ======= 4/ Detection ================
-- =====================================
-- =====================================

-- Server id -> { status, base_url, models } of the last completed sweep
local _results = {}
-- When the last sweep completed, nil before the first one
local _checked_at = nil
-- Identity of the sweep in flight; an older sweep's answers are dropped
local _sweep_generation = 0
local _sweep_active = false

--- Tells whether two verdicts differ.
--- @param a table|nil
--- @param b table|nil
--- @return boolean
local function verdict_changed(a, b)
	if a == nil or b == nil then return a ~= b end
	if a.status ~= b.status or a.base_url ~= b.base_url or #a.models ~= #b.models then return true end
	for index, model in ipairs(a.models) do
		if b.models[index] ~= model then return true end
	end
	return false
end

--- Probes every target at once and publishes the verdicts together.
--- @param targets table Array of { id, base_url, … }, one per server.
--- @param probe function (target, settle) -> boolean dispatched; settle(response)
---        receives the HTTP adapter's answer, once.
--- @param on_done function|nil Receives (changed) once every target settled.
--- @return boolean started
function M.sweep(targets, probe, on_done)
	if type(targets) ~= "table" or type(probe) ~= "function" then
		error("local_servers.sweep: targets and a probe are required")
	end
	_sweep_generation = _sweep_generation + 1
	local generation = _sweep_generation
	_sweep_active = true
	local fresh = {}
	local pending = #targets

	local function finish()
		if generation ~= _sweep_generation then return end
		_sweep_active = false
		local changed = false
		for _, id in ipairs(M.ORDER) do
			if verdict_changed(_results[id], fresh[id]) then changed = true end
			if fresh[id] and fresh[id].status == M.STATUS_UP then M.report_success(id) end
		end
		_results = fresh
		_checked_at = TimerScheduler.now()
		local found = {}
		for _, id in ipairs(M.detected()) do found[#found + 1] = id .. "=" .. _results[id].status end
		Logger.info(LOG, "Local servers swept: %s.", #found > 0 and table.concat(found, ", ") or "none answers")
		if type(on_done) == "function" then
			local ok, err = xpcall(on_done, debug.traceback, changed)
			if not ok then Logger.error(LOG, "Local server sweep callback raised: %s", tostring(err)) end
		end
	end

	if pending == 0 then
		finish()
		return true
	end
	for _, target in ipairs(targets) do
		local settled = false
		local function settle(response)
			if settled or generation ~= _sweep_generation then return end
			settled = true
			local status, models = M.classify(response)
			fresh[target.id] = { status = status, base_url = target.base_url, models = models or {} }
			pending = pending - 1
			if pending == 0 then finish() end
		end
		local ok, dispatched = xpcall(probe, debug.traceback, target, settle)
		if not ok or dispatched ~= true then
			Logger.warn(LOG, "Local server '%s' was not probed: %s.", tostring(target.id),
				ok and "the probe was refused" or tostring(dispatched))
			settle(nil)
		end
	end
	return true
end

--- The last verdict about one server.
--- @param id string
--- @return table|nil { status, base_url, models }
function M.result(id)
	return _results[id]
end

--- The servers that answered the last sweep, in catalogue order.
--- @return table ids
function M.detected()
	local ids = {}
	for _, id in ipairs(M.ORDER) do
		local verdict = _results[id]
		if verdict and verdict.status ~= M.STATUS_DOWN then ids[#ids + 1] = id end
	end
	return ids
end

--- Tells whether the verdicts are too old to show without a new sweep.
--- @return boolean stale
function M.is_stale()
	if _sweep_active then return false end
	if _checked_at == nil then return true end
	-- How long a sweep's verdict stands before the menu asks for a new one
	local max_age = require("infra.timings").sec("llm", "local_server_detection_max_age_ms")
	return TimerScheduler.now() - _checked_at >= max_age
end

--- Tells whether a sweep is in flight.
--- @return boolean
function M.is_sweeping()
	return _sweep_active
end





-- =====================================
-- =====================================
-- ======= 5/ Pending Settings =========
-- =====================================
-- =====================================

-- Server id -> { base_url?, token? } typed before the server has an API entry
local _pending = {}

--- Keeps an address or a key for a server that has no API entry yet.
--- @param id string A server id.
--- @param fields table { base_url = string|nil, token = string|nil }.
function M.set_pending(id, fields)
	if not M.is_local(id) or type(fields) ~= "table" then
		error("local_servers.set_pending: a server id and fields are required")
	end
	local pending = _pending[id] or {}
	for _, key in ipairs({ "base_url", "token" }) do
		if fields[key] ~= nil then pending[key] = fields[key] end
	end
	_pending[id] = pending
end

--- The address and key waiting for a server's API entry.
--- @param id string
--- @return table { base_url?, token? }
function M.pending(id)
	return _pending[id] or {}
end

--- Forgets what waited for a server once its API entry holds it.
--- @param id string
function M.clear_pending(id)
	_pending[id] = nil
end





-- =====================================
-- =====================================
-- ======= 6/ Failure Reports ==========
-- =====================================
-- =====================================

-- Called with (id, kind, detail) when a request to a local server fails
local _failure_handler = nil
-- Server id -> the failure kind already reported
local _reported = {}

--- Registers who offers the fix of a failure (the AI menu).
--- @param handler function|nil (id, kind, detail) where detail is { status, message, model }.
function M.set_failure_handler(handler)
	if handler ~= nil and type(handler) ~= "function" then
		error("local_servers.set_failure_handler: the handler must be a function")
	end
	_failure_handler = handler
end

--- Reports a failed request to a local server. Each kind is reported once
--- until the server answers again.
--- @param id string Server id.
--- @param status number|nil HTTP status.
--- @param message string|nil The server's error message.
--- @param model string|nil The model that was asked for.
--- @return string|nil kind The failure kind, nil when the user cannot fix it here.
function M.report_failure(id, status, message, model)
	if not M.is_local(id) then return nil end
	local kind = M.classify_failure(status, message)
	if kind == nil or _reported[id] == kind then return kind end
	Logger.warn(LOG, "Local server '%s' request failed: %s (HTTP %s).", id, kind, tostring(status))
	-- Before the menu registers its handler nothing is shown, so nothing is
	-- marked reported: the next failure still reaches the user
	if not _failure_handler then return kind end
	_reported[id] = kind
	local ok, err = xpcall(_failure_handler, debug.traceback, id, kind,
		{ status = tonumber(status) or 0, message = message, model = model })
	if not ok then Logger.error(LOG, "Local server failure handler raised: %s", tostring(err)) end
	return kind
end

--- Records that a server answered, so its next failure is reported again.
--- @param id string Server id.
function M.report_success(id)
	_reported[id] = nil
end

return M
