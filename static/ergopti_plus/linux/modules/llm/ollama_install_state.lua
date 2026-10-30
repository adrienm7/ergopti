--- modules/llm/ollama_install_state.lua

--- ==============================================================================
--- MODULE: Ollama Install State
--- DESCRIPTION:
--- Whether the local Ollama can run a model now, for the model selector page:
--- greyed with its reason when the runtime is absent or its last owned repair
--- failed, as macOS (ollama_deps_checker) and Windows (LLM_Deps_HasFailed) grey
--- their Ollama group.
---
--- FEATURES & RATIONALE:
--- 1. Read-only: the managed runtime is read through the owned resolver and
---    ollama_installed_runtime.capture, which spawn nothing, write nothing and
---    acquire no descriptor.
--- 2. A server that answers is never greyed: models in the inventory, or an
---    Ollama the user points at elsewhere than this computer, are available
---    whatever this computer has installed.
--- 3. The failure is the owned repair's own result (prediction_engine records
---    it through note_repair); the next successful repair clears it.
--- 4. An Ollama the user installed (on PATH, or a daemon on the stock port)
---    never counts: Ergopti runs only its own pinned Ollama, so the group stays
---    greyed until that one is installed, as on macOS and Windows.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "modules.llm.ollama_install_state"
local REASON = "model_browser.reason_ollama_missing"

-- The error of the last owned runtime repair that failed, nil after a success.
local _failure = nil
-- The origin of the daemon the last successful repair started, and the PAC
-- lookup stage that made it go direct, nil when its routes were looked up.
local _fallback_origin, _fallback_stage = nil, nil
-- The cause last reported, so the log names each change once.
local _last_cause = nil
-- The read-only managed-runtime resolver, built on the first capture.
local _resolver = nil

--- Records the result of one owned runtime repair.
--- @param result table { ok, error?, origin?, direct_fallback? } as the repair controller reports it.
function M.note_repair(result)
	if type(result) ~= "table" then return end
	if result.ok == true then
		if _failure ~= nil then Logger.info(LOG, "Local Ollama repair succeeded; its failure is cleared.") end
		_failure = nil
		-- A failed repair leaves the daemon an earlier one started, and its routes.
		_fallback_stage = type(result.direct_fallback) == "string" and result.direct_fallback or nil
		_fallback_origin = _fallback_stage and result.origin or nil
	elseif result.ok == false and result.error ~= "runtime_cancelled" then
		_failure = tostring(result.error)
		Logger.warn(LOG, "Local Ollama repair failed (%s); the page greys Ollama.", _failure)
	end
end

--- The error of the last owned repair that failed, nil after a success.
--- @return string|nil failure
function M.failure() return _failure end

--- The PAC lookup stage that sent the daemon serving this origin direct.
--- @param origin string|nil The Ollama origin a request went to.
--- @return string|nil stage Nil for another origin or a daemon whose routes were looked up.
function M.direct_fallback(origin)
	if _fallback_stage == nil or origin ~= _fallback_origin then return nil end
	return _fallback_stage
end

--- The managed runtime's read-only status: installed, missing or unavailable.
--- @return string status
local function managed_status()
	if _resolver == nil then
		local ok, resolver = pcall(function() return require("modules.llm.ollama_install_resolver").new() end)
		if not ok or type(resolver) ~= "table" then return "unavailable" end
		_resolver = resolver
	end
	local ok, verdict = pcall(require("modules.llm.ollama_installed_runtime").capture, _resolver)
	return ok and type(verdict) == "table" and type(verdict.status) == "string" and verdict.status or "unavailable"
end

local DEFAULT_PORTS = {
	failure = M.failure,
	managed = managed_status,
	loopback = function(origin) return require("llm.runtime_repair").loopback_origin(origin) ~= nil end,
}

--- Whether the local Ollama can run a model now.
--- @param llm table Prediction engine (get_cached_models, get_base_url).
--- @param ports table|nil { failure, managed, loopback } (tests).
--- @return boolean available
--- @return string|nil reason_key Locale key of why it cannot.
--- @return string cause installed|answering|remote|absent|install_failed.
function M.capture(llm, ports)
	ports = ports or DEFAULT_PORTS
	local cause
	local models = type(llm) == "table" and type(llm.get_cached_models) == "function" and llm.get_cached_models() or {}
	local origin = type(llm) == "table" and type(llm.get_base_url) == "function" and llm.get_base_url() or nil
	if ports.failure() ~= nil then
		cause = "install_failed"
	elseif type(models) == "table" and #models > 0 then
		cause = "answering"
	elseif type(origin) == "string" and origin ~= "" and not ports.loopback(origin) then
		cause = "remote"
	elseif ports.managed() == "installed" then
		cause = "installed"
	else
		cause = "absent"
	end
	if cause ~= _last_cause then
		_last_cause = cause
		Logger.info(LOG, "Local Ollama install state: %s.", cause)
	end
	local available = cause ~= "install_failed" and cause ~= "absent"
	return available, (not available) and REASON or nil, cause
end

--- Test seam: forgets the recorded failure and fallback, the resolver and the last cause.
function M._reset()
	_failure, _resolver, _last_cause = nil, nil, nil
	_fallback_origin, _fallback_stage = nil, nil
end

return M
