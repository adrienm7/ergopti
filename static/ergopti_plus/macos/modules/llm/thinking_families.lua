--- modules/llm/thinking_families.lua

--- ==============================================================================
--- MODULE: Thinking Families
--- DESCRIPTION:
--- Owns the model families of _shared/modules/llm/thinking_off.json for the
--- macOS driver: read once, at their first use, and shared by every request
--- builder (api_remote's cloud bodies, every Ollama body).
---
--- FEATURES & RATIONALE:
--- 1. One loader: the cloud and local paths cannot read two different tables.
--- 2. Light: it needs only the shared paths and the JSON codec, so an Ollama
---    request builder can use it without loading the remote catalogue.
--- 3. An unreadable table is logged and turns nothing off: no guess.
--- ==============================================================================

local M = {}

local Logger      = require("infra.logger")
local Paths       = require("infra.paths")
local JsonCodec   = require("adapters.json_codec")
local ThinkingOff = require("llm.thinking_off")

local LOG = "llm.thinking_families"

--- Reads the model families (thinking_off.lua parse_families), {} when unreadable.
--- @return table families
local function load_families()
	local path = Paths.shared_llm_path("thinking_off.json")
	local fh = path and io.open(path, "r")
	local raw = fh and fh:read("*a")
	if fh then fh:close() end
	local ok, decoded = pcall(JsonCodec.decode, raw)
	local families, reason = ThinkingOff.parse_families(ok and decoded or nil)
	if not families then
		Logger.error(LOG, "thinking_off.json is unreadable (%s) — no request turns thinking off.", tostring(reason))
		families = {}
	end
	return families
end

-- The parsed families, nil until their first use
local _families = nil

--- The model families (thinking_off.lua parse_families), {} when unreadable.
--- @return table families
function M.families()
	if _families == nil then _families = load_families() end
	return _families
end

--- The think value of an Ollama chat body for a model (thinking_off.json):
--- false, or the effort level of a family that ignores false (gpt-oss).
--- @param model string The model id.
--- @return boolean|string think
function M.ollama_think(model)
	local think = ThinkingOff.ollama_think(M.families(), tostring(model))
	if think ~= false then Logger.debug(LOG, "Ollama think for model %s: %s.", tostring(model), think) end
	return think
end

return M
