--- modules/llm/warmup.lua

--- ==============================================================================
--- MODULE: Ollama Model Warmup
--- DESCRIPTION:
--- Loads the selected Ollama model before the first prediction needs it, as
--- Windows (api_ollama/ollama_warmup.ahk) and macOS (warmup_controller.lua) do:
--- one load request after a short delay, retried with a doubling interval until
--- Ollama has the model in memory, the AI stops or the target changes.
---
--- FEATURES & RATIONALE:
--- 1. Engine lifecycle: the daemon binds the ports once; the prediction engine
---    schedules a chain when the AI starts, resumes or changes model, and every
---    path that stops its runtime (pause, switch-off, configuration scope,
---    reload, shutdown) stops the chain and retires its request.
--- 2. Lazy target: each attempt reads the origin and the model again, so a
---    model switch while a chain waits warms the new model, never the old one.
--- 3. Ollama serves one request at a time: an attempt never queues behind a
---    prediction, it waits one interval instead.
--- 4. A model Ollama does not have ends the chain: retrying cannot load it, and
---    the prediction path already offers its download.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Timings = require("infra.timings")
local LocalModelPolicy = require("llm.local_model_policy")

local LOG = "modules.llm.warmup"
local INITIAL_DELAY_MS = Timings.ms("llm", "warmup_initial_delay_ms")
local RETRY_BASE_MS = Timings.ms("llm", "warmup_retry_base_ms")
local RETRY_CAP_MS = Timings.ms("llm", "warmup_retry_cap_ms")

-- The bound ports: scheduler, target, request and busy (see M.init).
local _ports = nil
-- Bumped by every new chain and every stop: a callback of an older one is stale.
local _generation = 0
local _timer = nil
-- The load request in flight, kept until its transport physically settled.
local _request = nil
-- The origin and model Ollama confirmed loaded since the last stop.
local _ready_key = nil
-- The origin and model the running chain is loading.
local _chain_key = nil




-- ===================================
-- ===================================
-- ======= 1/ Chain Internals ========
-- ===================================
-- ===================================

--- The identity of one warmup target.
--- @param target table { origin, model }
--- @return string
local function key_of(target)
	return target.origin .. "\n" .. target.model
end

--- The target the engine would warm now, or nil when no warmup may run.
--- @return table|nil target { origin, model, receipt }
local function read_target()
	local ok, target = pcall(_ports.target)
	if not ok then
		Logger.error(LOG, "The warmup target could not be read: %s.", tostring(target))
		return nil
	end
	if type(target) ~= "table" or type(target.origin) ~= "string" or target.origin == ""
		or type(target.model) ~= "string" or target.model == "" then return nil end
	return target
end

--- Whether the request in flight retired its process and pipes.
--- @return boolean
local function request_settled()
	if not _request then return true end
	local ok, value = pcall(_request.is_settled, _request)
	if ok and value == true then _request = nil end
	return _request == nil
end

local fire

--- Arms the next attempt of one chain.
--- @param generation integer
--- @param delay_ms number
--- @param interval_ms number Interval the attempt waits if it fails.
--- @return boolean armed
local function arm(generation, delay_ms, interval_ms)
	if generation ~= _generation then return false end
	local handle = _ports.scheduler.after(delay_ms / 1000, function()
		fire(generation, interval_ms)
	end)
	if type(handle) ~= "table" or handle.fired == true then
		Logger.error(LOG, "The warmup timer could not be armed — the model loads on the first prediction.")
		return false
	end
	_timer = handle
	return true
end

--- Handles the answer to one load request.
--- @param generation integer
--- @param key string
--- @param next_interval number
--- @param loaded boolean
--- @param failure string|table|nil A transport reason, or the missing-model failure.
local function on_result(generation, key, next_interval, loaded, failure)
	if generation ~= _generation then return end
	if loaded then
		_ready_key, _chain_key = key, nil
		Logger.info(LOG, "Ollama model loaded — ready for predictions.")
		return
	end
	if LocalModelPolicy.is_missing(failure) then
		_chain_key = nil
		Logger.info(LOG, "Warmup ended: Ollama does not have the selected model.")
		return
	end
	Logger.info(LOG, "Warmup attempt failed (%s) — next attempt in %d ms.",
		type(failure) == "string" and failure or "unclassified failure", next_interval)
	arm(generation, next_interval, next_interval)
end

--- Runs one attempt: load the current target, or wait one more interval.
--- @param generation integer
--- @param interval_ms number
fire = function(generation, interval_ms)
	if generation ~= _generation then return end
	_timer = nil
	local target = read_target()
	if not target then
		_chain_key = nil
		Logger.debug(LOG, "Warmup ended: no Ollama model may be loaded now.")
		return
	end
	local key = key_of(target)
	if key == _ready_key then _chain_key = nil; return end
	_chain_key = key
	local next_interval = math.min(interval_ms * 2, RETRY_CAP_MS)
	local busy_ok, busy = pcall(_ports.busy)
	if not busy_ok or busy == true or not request_settled() then
		arm(generation, interval_ms, interval_ms)
		return
	end
	local called, operation = pcall(_ports.request, target, function(loaded, failure)
		on_result(generation, key, next_interval, loaded == true, failure)
	end)
	if not called or type(operation) ~= "table" or operation.started ~= true then
		Logger.warn(LOG, "The warmup request was refused before it was sent: %s.",
			tostring(called and operation or "request raised"))
		arm(generation, next_interval, next_interval)
		return
	end
	_request = operation
end




-- ==============================
-- ==============================
-- ======= 2/ Public API ========
-- ==============================
-- ==============================

--- Binds the ports once for this process.
--- @param ports table { scheduler = { after, cancel }, target = function → { origin, model, receipt }|nil,
---   request = function(target, on_done(loaded, failure)) → owned operation, busy = function → boolean }
--- @return boolean bound
function M.init(ports)
	Logger.start(LOG, "Initializing…")
	if _ports then
		Logger.error(LOG, "Warmup already initialized — a second owner was refused.")
		return false
	end
	if type(ports) ~= "table" or type(ports.scheduler) ~= "table" or type(ports.scheduler.after) ~= "function"
		or type(ports.scheduler.cancel) ~= "function" or type(ports.target) ~= "function"
		or type(ports.request) ~= "function" or type(ports.busy) ~= "function" then
		Logger.error(LOG, "Warmup initialization refused: incomplete ports.")
		return false
	end
	_ports = ports
	Logger.success(LOG, "Initialized.")
	return true
end

--- Starts a chain for the current target unless it is loaded or already loading.
--- @param reason string Who asked, for the log.
--- @return boolean scheduled True when a chain runs or the model is already loaded.
function M.schedule(reason)
	if not _ports then
		Logger.debug(LOG, "Warmup not initialized — '%s' schedules nothing.", tostring(reason))
		return false
	end
	local target = read_target()
	if not target then return false end
	local key = key_of(target)
	if key == _ready_key or (key == _chain_key and M.pending()) then return true end
	if not M.stop() then
		Logger.warn(LOG, "Warmup for '%s' deferred: the previous chain still owns its timer.", tostring(reason))
		return false
	end
	_chain_key = key
	Logger.debug(LOG, "Warmup scheduled (%s).", tostring(reason))
	return arm(_generation, INITIAL_DELAY_MS, RETRY_BASE_MS)
end

--- Stops the chain and retires its request; the next schedule loads again.
--- @return boolean settled True once no warmup timer and no request remain.
function M.stop()
	_generation = _generation + 1
	_ready_key, _chain_key = nil, nil
	if not _ports then return true end
	if _timer then
		if _ports.scheduler.cancel(_timer) ~= true then
			Logger.error(LOG, "The warmup timer could not be cancelled — its ownership is retained.")
			return false
		end
		_timer = nil
	end
	if _request then
		local called = pcall(_request.cancel, _request)
		if not called or not request_settled() then return false end
	end
	return true
end

--- Whether a timer or a request of a chain is still owned.
--- @return boolean
function M.pending()
	return _timer ~= nil or not request_settled()
end

--- Stops the chain and releases the ports, for the daemon's teardown.
--- @return boolean settled
function M.shutdown()
	if not M.stop() then return false end
	_ports = nil
	Logger.info(LOG, "Shut down.")
	return true
end

return M
