--- ai/engine/ollama/install_error_messages.lua

--- ==============================================================================
--- MODULE: Managed Ollama Install Error Messages (macOS)
--- DESCRIPTION:
--- Reads _shared/ai/data/ollama_install_errors.json once and names the message
--- of a failed managed runtime install from the evidence line
--- ai/engine/ollama/managed_ollama_runtime.py prints (OLLAMA_INSTALL_FAILURE):
--- a full disk, an unreachable host and a corrupted download each show their
--- own cause, not « send the diagnostics report » (OLL-04, OLL-05). A model
--- pull that filled the disk names it too (OLL-14).
--- ==============================================================================

local M = {}
local InstallErrors = require("ai.engine.ollama.install_errors")

local _classifier = nil

--- The shared classifier; an unreadable or malformed data file raises.
--- @return table classifier
function M.classifier()
	if _classifier then return _classifier end
	local path = require("core.fs.engine.paths").shared("ai/data/ollama_install_errors.json")
	if type(path) ~= "string" or path == "" then error("ollama_install_errors.json is not in the shared tree", 2) end
	-- The shared pure-Lua decoder, as Linux reads the same file: the classes
	-- hold no value hs.json would type differently.
	local handle, open_error = io.open(path, "rb")
	if not handle then error("ollama_install_errors.json is unreadable: " .. tostring(open_error), 2) end
	local raw = handle:read("*a")
	handle:close()
	local ok, decoded = pcall(require("core.text.engine.json").decode, raw)
	if not ok or type(decoded) ~= "table" then error("ollama_install_errors.json is not JSON: " .. tostring(decoded), 2) end
	_classifier = InstallErrors.new(decoded)
	return _classifier
end

--- The locale key and class of one install failure.
--- @param evidence string The words after OLLAMA_INSTALL_FAILURE.
--- @return string key
--- @return string class
function M.for_evidence(evidence)
	local classifier = M.classifier()
	local class = classifier.classify(evidence)
	return classifier.message_key(class), class
end

--- The locale key and install class of a failed model pull whose class is an
--- install class too (a full disk, OLL-14).
--- @param pull_class string The class the pull worker printed (OLLAMA_PULL_ERROR).
--- @return string|nil key Its %s is the model tag; nil keeps the generic pull failure.
--- @return string|nil class
function M.for_pull(pull_class)
	local class, key = M.classifier().pull_failure(pull_class)
	return key, class
end

return M
