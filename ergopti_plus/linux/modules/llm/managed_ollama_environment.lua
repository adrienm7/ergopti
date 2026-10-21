--- modules/llm/managed_ollama_environment.lua

--- ==============================================================================
--- MODULE: Managed Ollama Serve Environment
--- DESCRIPTION:
--- Reads the shared serve environment that every driver applies to the Ollama
--- server it owns (managed_ollama_environment.json). The managed runtime only
--- serves local models, so OLLAMA_NO_CLOUD keeps the daemon from contacting
--- ollama.com. A user-configured external Ollama never receives it.
--- ==============================================================================

local M = {}

local SOURCE = "modules/llm/managed_ollama_environment.json"
local MAXIMUM_BYTES = 65536

--- Validates the decoded declaration; the launch owner keeps host and models.
--- @param decoded any Decoded JSON document.
--- @return table|nil rows Sorted "NAME=value" entries.
local function rows_from(decoded)
	local Json = require("json")
	if type(decoded) ~= "table" or Json.is_array(decoded) or decoded.schema_version ~= 1 then return nil end
	for key in pairs(decoded) do
		if key ~= "schema_version" and key ~= "serve_environment" then return nil end
	end
	local environment = decoded.serve_environment
	if type(environment) ~= "table" or Json.is_array(environment) then return nil end
	local names = {}
	for name, value in pairs(environment) do
		if type(name) ~= "string" or not name:match("^[A-Z][A-Z0-9_]*$")
			or name == "OLLAMA_HOST" or name == "OLLAMA_MODELS"
			or type(value) ~= "string" or value:find("[%z\r\n]") then
			return nil
		end
		names[#names + 1] = name
	end
	if #names == 0 then return nil end
	table.sort(names)
	local rows = {}
	for _, name in ipairs(names) do rows[#rows + 1] = name .. "=" .. environment[name] end
	return rows
end

--- Decodes one declaration from its bytes.
--- @param data string Raw JSON bytes.
--- @return table|nil rows Sorted "NAME=value" entries.
--- @return string|nil reason Classified refusal.
function M.decode(data)
	if type(data) ~= "string" or #data > MAXIMUM_BYTES then return nil, "managed_environment_invalid" end
	local ok, decoded = pcall(require("json").decode_lossless, data)
	local rows = ok and rows_from(decoded) or nil
	if not rows then return nil, "managed_environment_invalid" end
	return rows
end

--- Reads the packaged canonical declaration through the installed-layout owner.
--- @return table|nil rows Sorted "NAME=value" entries.
--- @return string|nil reason Classified refusal.
function M.load()
	local path = require("infra.paths").shared(SOURCE)
	if not path then return nil, "managed_environment_unreadable" end
	local file = io.open(path, "rb")
	if not file then return nil, "managed_environment_unreadable" end
	local data = file:read(MAXIMUM_BYTES + 1)
	local closed = file:close()
	if not closed or type(data) ~= "string" then return nil, "managed_environment_unreadable" end
	return M.decode(data)
end

return M
