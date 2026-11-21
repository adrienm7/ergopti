--- ai/engine/ollama/install_error_messages.lua

--- ==============================================================================
--- MODULE: Managed Ollama Install Error Messages (Linux)
--- DESCRIPTION:
--- Reads _shared/ai/data/ollama_install_errors.json once and names the message
--- of a failed runtime repair: an install failure shows its class's own words
--- (a full disk, an unreachable host, a corrupted download), any other repair
--- failure the generic ollama.runtime_repair_failed (OLL-04, OLL-05).
--- ==============================================================================

local M = {}
local InstallErrors = require("ai.engine.ollama.install_errors")

local _classifier = nil

--- The shared classifier; an unreadable or malformed data file raises.
--- @return table classifier
function M.classifier()
	if _classifier then return _classifier end
	local path = require("core.fs.engine.paths").shared("ai/data/ollama_install_errors.json")
	if not path then error("ollama_install_errors.json is not in the shared tree", 2) end
	local data, status = require("core.text.engine.toml_codec.writer").read_classified(path)
	if status ~= "ok" or type(data) ~= "string" then
		error("ollama_install_errors.json is unreadable: " .. tostring(status), 2)
	end
	local ok, decoded = pcall(require("core.text.engine.json").decode, data)
	if not ok then error("ollama_install_errors.json is not JSON: " .. tostring(decoded), 2) end
	_classifier = InstallErrors.new(decoded)
	return _classifier
end

--- The locale key and class of one failed repair result.
--- @param result table { ok = false, error, install_failure? } from the repair controller.
--- @return string key
--- @return string|nil class nil when the repair failed outside the install.
function M.for_result(result)
	if type(result) ~= "table" or type(result.install_failure) ~= "string" then
		return "ollama.runtime_repair_failed", nil
	end
	local classifier = M.classifier()
	local class = classifier.classify(result.install_failure)
	return classifier.message_key(class), class
end

return M
