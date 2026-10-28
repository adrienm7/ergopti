-- _shared/lua/llm/request_plan/live.lua

--- ==============================================================================
--- MODULE: LLM Request Plan — Live Prompt
--- DESCRIPTION:
--- Decides what a live-mode keystroke asks for. The timing comes from live.json
--- (shared by the three drivers), the prompt is the one live mode was started
--- with, looked up again at every request, and the count is the live receipt's
--- own or else the menu's.
---
--- FEATURES & RATIONALE:
--- 1. Pure: the decoded file, the live receipt, the menu count and the looked-up
---    profile in, a decision out. The driver does the file read, the JSON decode,
---    the profile lookup and the stop itself.
--- 2. A prompt deleted while live mode ran stops live mode and asks for nothing:
---    the keystroke never falls back to the menu's prompt, which the user did not
---    choose for live typing.
--- 3. live.json is validated strictly, so a number the three drivers would read
---    differently (a fraction, a negative) is refused instead of rounded.
---
--- Pinned by _shared/tests/corpus/llm/request_plan_live_vectors.json.
--- ==============================================================================

local M = {}




-- =================================
-- =================================
-- ======= 1/ Public API ===========
-- =================================
-- =================================

local function is_count(value, minimum)
	return type(value) == "number" and value == value and value >= minimum and value % 1 == 0
end

--- Validates live.json once decoded.
--- @param decoded any The decoded file.
--- @return table|nil config { debounce_ms, min_words }
--- @return string|nil reason Why the file is unusable.
function M.config(decoded)
	if type(decoded) ~= "table" then return nil, "live.json is missing or not JSON" end
	if not is_count(decoded.debounce_ms, 0) then
		return nil, "live.json debounce_ms is not a non-negative integer"
	end
	if not is_count(decoded.min_words, 0) then
		return nil, "live.json min_words is not a non-negative integer"
	end
	return { debounce_ms = decoded.debounce_ms, min_words = decoded.min_words }, nil
end

--- What one live keystroke asks for.
--- @param config table The validated live.json (see config).
--- @param receipt table { profile_id, num_predictions? } the live mode receipt.
--- @param menu_count number The menu's prediction count (at least 1).
--- @param profile table|nil The prompt looked up now, nil when it no longer exists.
--- @return table decision { action = "request", profile, num_predictions, min_words }
---   or { action = "stop", cause = "prompt deleted" }
function M.decide(config, receipt, menu_count, profile)
	if type(config) ~= "table" or not is_count(config.min_words, 0) then error("config must come from config()", 2) end
	if type(receipt) ~= "table" or type(receipt.profile_id) ~= "string" or receipt.profile_id == "" then
		error("receipt needs a profile_id", 2)
	end
	if not is_count(menu_count, 1) then error("menu_count must be a whole number from 1", 2) end
	if receipt.num_predictions ~= nil and not is_count(receipt.num_predictions, 1) then
		error("receipt num_predictions must be a whole number from 1", 2)
	end
	if type(profile) ~= "table" then return { action = "stop", cause = "prompt deleted" } end
	return {
		action = "request",
		profile = profile,
		num_predictions = receipt.num_predictions or menu_count,
		min_words = config.min_words,
	}
end

return M
