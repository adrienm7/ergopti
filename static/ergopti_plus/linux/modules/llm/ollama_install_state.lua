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

local Logger = require("core.logger.engine.shim")

local LOG = "modules.llm.ollama_install_state"
local REASON = "model_browser.reason_ollama_missing"

-- The error of the last owned runtime repair that failed, nil after a success.
local _failure = nil
-- The sign-in relay's closed refusal under the daemon the last successful repair
-- started without its proxy, and that daemon's origin. Only its pulls are refused.
local _relay_refusal, _refusal_origin = nil, nil
-- The origin of the daemon the last successful repair started, and the PAC
-- lookup stage that made it go direct, nil when its routes were looked up.
local _fallback_origin, _fallback_stage = nil, nil
-- The cause last reported, so the log names each change once.
local _last_cause = nil

--- Records the result of one owned runtime repair.
--- @param result table { ok, error?, origin?, direct_fallback?, relay_refusal? } as the repair controller reports it.
function M.note_repair(result)
	if type(result) ~= "table" then return end
	if result.ok == true then
		if _failure ~= nil then Logger.info(LOG, "Local Ollama repair succeeded; its failure is cleared.") end
		_failure = nil
		-- A failed repair leaves the daemon an earlier one started, and its routes.
		_fallback_stage = type(result.direct_fallback) == "string" and result.direct_fallback or nil
		_fallback_origin = _fallback_stage and result.origin or nil
		_relay_refusal = type(result.relay_refusal) == "string" and result.relay_refusal or nil
		_refusal_origin = _relay_refusal and result.origin or nil
	elseif result.ok == false and result.error ~= "runtime_cancelled" then
		_failure = tostring(result.error)
		Logger.warn(LOG, "Local Ollama repair failed (%s); the page greys Ollama.", _failure)
	end
end

--- The sign-in relay's closed refusal under the daemon serving this origin.
--- @param origin string|nil The Ollama origin a pull goes to.
--- @return string|nil reason Nil for another origin or a daemon under its proxy.
function M.relay_refusal(origin)
	if _relay_refusal == nil or origin ~= _refusal_origin then return nil end
	return _relay_refusal
end

--- The locale key of the message that refuses a pull from this origin.
--- @param origin string|nil The Ollama origin a pull goes to.
--- @return string|nil key Nil when the pull may go ahead.
function M.pull_refusal_key(origin)
	local reason = M.relay_refusal(origin)
	if reason == nil then return nil end
	local relay = require("infra.proxy_auth_relay").load()
	return relay and relay.message_key(reason) or "network.relay.failed"
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
--- Each observation builds its own resolver. A resolver records the absence of
--- missing ancestors as part of its witness, so one kept from before the first
--- install refused the parents that install created and reported the new
--- runtime absent until a restart (audit LRT-001).
--- @return string status
local function managed_status()
	local built, resolver = pcall(function() return require("modules.llm.ollama_install_resolver").new() end)
	if not built or type(resolver) ~= "table" then return "unavailable" end
	local ok, verdict = pcall(require("modules.llm.ollama_installed_runtime").capture, resolver)
	return ok and type(verdict) == "table" and type(verdict.status) == "string" and verdict.status or "unavailable"
end

local DEFAULT_PORTS = {
	failure = M.failure,
	managed = managed_status,
	loopback = function(origin) return require("ai.engine.local_servers.runtime_repair").loopback_origin(origin) ~= nil end,
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
	local reason = (not available) and REASON or nil
	return available, reason, cause
end

--- Test seam: forgets the recorded failure and fallback and the last cause.
function M._reset()
	_failure, _last_cause, _relay_refusal, _refusal_origin = nil, nil, nil, nil
	_fallback_origin, _fallback_stage = nil, nil
end

return M
