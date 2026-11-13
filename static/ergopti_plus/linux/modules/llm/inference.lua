--- modules/llm/inference.lua

--- ==============================================================================
--- MODULE: Shared Inference Policy (Linux)
--- DESCRIPTION:
--- Reads _shared/ai/data/inference.json, the file the macOS and Windows
--- backends read, for the rules the Linux engine applies to every sequential
--- multi-prediction: the temperature of each variant when several predictions
--- are asked for one after another, and the retry policy that bounds how many
--- attempts may refill failed, empty or duplicate variants. (The minimum
--- interval between requests is the user's llm.trigger.min_request_interval_ms,
--- not a rule of this file.)
---
--- WHY THIS EXISTS:
--- The Linux engine sent every variant at the same temperature, so a second
--- and third request mostly repeated the first and deduplication left one
--- suggestion.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Json = require("core.text.engine.json")
local Paths = require("infra.paths")
local Temperature = require("ai.engine.policy.temperature")

local LOG = "modules.llm.inference"

local _policy = nil

--- The parsed policy file. Missing sections fail loudly at first use.
--- @return table
local function policy()
	if _policy then return _policy end
	local path = Paths.shared("ai/data/inference.json")
	local text, status
	if path then text, status = require("core.text.engine.toml_codec.writer").read_classified(path) end
	local root = status == "ok" and Json.decode(text) or nil
	if type(root) ~= "table" or type(root.diversity_temperature) ~= "table" then
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

--- Temperature of one variant of a sequential multi-prediction, through the
--- shared algorithm (_shared/ai/engine/policy/temperature.lua) the macOS backends use.
--- The first keeps the user's setting; each next one is warmer, from a raised
--- floor, so variants differ without drifting into nonsense.
--- @param base number The user's temperature.
--- @param index integer 1-based variant index.
--- @return number
function M.variant_temperature(base, index)
	return Temperature.variant(policy().diversity_temperature, base, index)
end

--- Attempt budget of a sequential multi-prediction: the shared retry policy's
--- max_multiplier attempts per requested prediction, as on macOS and Windows.
--- Failed, empty and duplicate answers spend it; nothing else can extend it.
--- @param requested integer Predictions the request asks for (at least 1).
--- @return integer
function M.max_attempts(requested)
	if type(requested) ~= "number" or requested < 1 or requested % 1 ~= 0 then
		error("requested must be a whole number from 1", 2)
	end
	local multiplier = math.max(1, math.floor(number("retry", "max_multiplier")))
	return requested * multiplier
end

--- Budget of the attempt that follows a failed or empty one: the failed call's
--- tokens plus the policy's extra room, and its temperature plus the policy's
--- step, capped at the diversity ceiling. Repeating the same call would mostly
--- repeat its failure; a first answer cut short needs room to finish.
--- @param tokens integer The failed call's output token limit.
--- @param temperature number The failed call's temperature.
--- @return integer tokens, number temperature
function M.retry_budget(tokens, temperature)
	local TokenBudget = require("ai.engine.request_plan.token_budget")
	local extra = math.floor(number("retry", "retry_extra_tokens"))
	local ceiling = number("diversity_temperature", "max_temperature")
	return TokenBudget.for_retry(tokens, extra),
		math.min(ceiling, temperature + number("retry", "retry_temperature_step"))
end

--- Forgets the parsed file (tests).
function M._reset_for_test()
	_policy = nil
	Logger.debug(LOG, "Inference policy cache cleared.")
end

return M
