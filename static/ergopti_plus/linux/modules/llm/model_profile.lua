--- modules/llm/model_profile.lua

--- ==============================================================================
--- MODULE: LLM Model-to-Profile Recommendation (Linux)
--- DESCRIPTION:
--- Maps an Ollama model name to the same raw/basic/advanced/batch_advanced
--- profile policy used by the other drivers. Catalogue facts come from
--- models.json and thresholds come from inference.json.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Paths = require("infra.paths")
local Json = require("json")

local LOG = "modules.llm.model_profile"
local _catalogue = nil
local _policy = nil

local function read_shared(name)
	local path = Paths.shared("modules/llm/" .. name)
	local handle = path and io.open(path, "r") or nil
	if not handle then return nil end
	local body = handle:read("*a")
	handle:close()
	local ok, decoded = pcall(Json.decode, body)
	return ok and type(decoded) == "table" and decoded or nil
end

local function normalise_model_name(value)
	if type(value) ~= "string" then return "" end
	return value:lower():gsub("%s+", ""):gsub(":latest$", "")
end

local function parse_billions(value)
	if type(value) == "number" then return value end
	if type(value) ~= "string" then return 0 end
	return tonumber(value:match("([%d%.]+)%s*[bB]")) or 0
end

local function aliases_for(model)
	local aliases = { normalise_model_name(model.name) }
	local url = type(model.urls) == "table" and model.urls.ollama or nil
	if type(url) == "string" then
		local tag = url:match("/library/([^/?#]+)")
		if tag then aliases[#aliases + 1] = normalise_model_name(tag) end
	end
	return aliases
end

local function find_model(name, catalogue)
	local wanted = normalise_model_name(name)
	for _, provider in ipairs(catalogue or {}) do
		for _, family in ipairs(provider.families or {}) do
			for _, model in ipairs(family.models or {}) do
				for _, alias in ipairs(aliases_for(model)) do
					if alias ~= "" and alias == wanted then return model end
				end
			end
		end
	end
	return nil
end

--- Pure recommendation seam used by tests.
--- @param model_name string
--- @param catalogue table Decoded models.json.
--- @param policy table { advanced_min_parameters_b, batch_min_parameters_b }.
--- @return string
function M.recommend_from(model_name, catalogue, policy)
	policy = type(policy) == "table" and policy or {}
	local advanced = tonumber(policy.advanced_min_parameters_b)
	local batch = tonumber(policy.batch_min_parameters_b)
	if not advanced or not batch or advanced <= 0 or batch < advanced then return "basic" end

	local info = find_model(model_name, catalogue)
	local lower = normalise_model_name(model_name)
	local completion = info and info.type == "completion"
		or lower:match("[-_:]base$") ~= nil
		or lower:match("[-_:]base[-_:]") ~= nil
	if completion then return "raw" end

	local params = 0
	if info and type(info.parameters) == "table" then
		params = parse_billions(info.parameters.active)
		if params <= 0 then params = parse_billions(info.parameters.total) end
	end
	if params <= 0 then
		for value in lower:gmatch("([%d%.]+)[bB]") do params = tonumber(value) or params end
	end
	if params >= batch then return "batch_advanced" end
	if params >= advanced then return "advanced" end
	return "basic"
end

local function canonicals()
	if not _catalogue then _catalogue = read_shared("models.json") end
	if not _policy then
		local inference = read_shared("inference.json")
		_policy = inference and inference.profile_recommendation or nil
	end
	if type(_catalogue) ~= "table" or type(_policy) ~= "table" then
		Logger.error(LOG, "Shared model catalogue or profile policy is unavailable.")
		return nil, nil
	end
	return _catalogue, _policy
end

--- Returns the recommended built-in profile for an Ollama model name.
--- @param model_name string
--- @return string
function M.recommend(model_name)
	local catalogue, policy = canonicals()
	if not catalogue then return "basic" end
	return M.recommend_from(model_name, catalogue, policy)
end

--- Test seam: forgets loaded shared files.
function M._reset()
	_catalogue = nil
	_policy = nil
end

return M
