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
---    acquire no descriptor; a system Ollama is a PATH lookup.
--- 2. A server that answers is never greyed: models in the inventory, or an
---    Ollama the user points at elsewhere than this computer, are available
---    whatever this computer has installed.
--- 3. The failure is the owned repair's own result (prediction_engine records
---    it through note_repair); the next successful repair clears it.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "modules.llm.ollama_install_state"
local REASON = "model_browser.reason_ollama_missing"

-- The error of the last owned runtime repair that failed, nil after a success.
local _failure = nil
-- The cause last reported, so the log names each change once.
local _last_cause = nil
-- The read-only managed-runtime resolver, built on the first capture.
local _resolver = nil

--- Records the result of one owned runtime repair.
--- @param result table { ok, error? } as the repair controller reports it.
function M.note_repair(result)
	if type(result) ~= "table" then return end
	if result.ok == true then
		if _failure ~= nil then Logger.info(LOG, "Local Ollama repair succeeded; its failure is cleared.") end
		_failure = nil
	elseif result.ok == false and result.error ~= "runtime_cancelled" then
		_failure = tostring(result.error)
		Logger.warn(LOG, "Local Ollama repair failed (%s); the page greys Ollama.", _failure)
	end
end

--- The error of the last owned repair that failed, nil after a success.
--- @return string|nil failure
function M.failure() return _failure end

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
	system_command = function() return require("adapters.shell_runner").has_command("ollama") == true end,
	loopback = function(origin) return require("llm.runtime_repair").loopback_origin(origin) ~= nil end,
}

--- Whether the local Ollama can run a model now.
--- @param llm table Prediction engine (get_cached_models, get_base_url).
--- @param ports table|nil { failure, managed, system_command, loopback } (tests).
--- @return boolean available
--- @return string|nil reason_key Locale key of why it cannot.
--- @return string cause installed|answering|remote|system|absent|install_failed.
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
	elseif ports.system_command() then
		cause = "system"
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

--- Test seam: forgets the recorded failure, the resolver and the last cause.
function M._reset()
	_failure, _resolver, _last_cause = nil, nil, nil
end

return M
