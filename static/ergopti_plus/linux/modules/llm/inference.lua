--- modules/llm/inference.lua

--- ==============================================================================
--- MODULE: Shared Inference Policy (Linux)
--- DESCRIPTION:
--- Reads _shared/modules/llm/inference.json, the file the macOS and Windows
--- backends read, for the two rules the Linux engine applies to every request:
--- the minimum interval between requests per backend, and the temperature of
--- each variant when several predictions are asked for one after another.
---
--- WHY THIS EXISTS:
--- The Linux engine sent every variant at the same temperature, so a second
--- and third request mostly repeated the first and deduplication left one
--- suggestion; and it sent a request on every word end, which a paid or
--- rate-limited API (Cerebras' free tier) answers with HTTP 429.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Json = require("json")
local Paths = require("infra.paths")
local Temperature = require("llm.temperature")

local LOG = "modules.llm.inference"

local _policy = nil

--- The parsed policy file. Missing sections fail loudly at first use.
--- @return table
local function policy()
	if _policy then return _policy end
	local path = Paths.shared("modules/llm/inference.json")
	local fh = path and io.open(path, "r")
	local root = fh and Json.decode(fh:read("*a")) or nil
	if fh then fh:close() end
	if type(root) ~= "table" or type(root.rate_limit_min_interval_ms) ~= "table"
		or type(root.diversity_temperature) ~= "table" then
		error("inference.json is missing or malformed: " .. tostring(path), 0)
	end
	_policy = root
	return _policy
end

--- One required number of the policy.
--- @param section string
--- @param key string
--- @return number
local function number(section, key)
	local value = tonumber(policy()[section][key])
	if not value then error(string.format("inference.json %s.%s is not a number", section, key), 0) end
	return value
end

--- Minimum milliseconds between two requests to one backend.
--- @param backend string "ollama" or "api"
--- @return number
function M.min_interval_ms(backend)
	return number("rate_limit_min_interval_ms", backend)
end

--- Temperature of one variant of a sequential multi-prediction, through the
--- shared algorithm (_shared/lua/llm/temperature.lua) the macOS backends use.
--- The first keeps the user's setting; each next one is warmer, from a raised
--- floor, so variants differ without drifting into nonsense.
--- @param base number The user's temperature.
--- @param index integer 1-based variant index.
--- @return number
function M.variant_temperature(base, index)
	return Temperature.variant(policy().diversity_temperature, base, index)
end

--- Forgets the parsed file (tests).
function M._reset_for_test()
	_policy = nil
	Logger.debug(LOG, "Inference policy cache cleared.")
end

return M
