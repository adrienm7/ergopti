--- _shared/lua/llm/remote_response_classifier.lua

--- ==============================================================================
--- MODULE: Remote LLM Response Classifier — Shared Lua Implementation
--- DESCRIPTION:
--- Decodes one remote-provider response root and derives both the assistant
--- text and the canonical token usage from that same root, then prices that
--- usage from the model_prices table of _shared/modules/llm/api_providers.json.
--- macOS and Linux both call it, so the dashboard's AI tab reads the same token
--- and cost figures whichever Lua driver answered the request.
---
--- FEATURES & RATIONALE:
--- 1. One decode per response: completion and usage come from one immutable
---    root, decoded losslessly so an explicit "error": null envelope is seen.
--- 2. Each format reads only its own top-level usage map; a nested usage block
---    (metadata, a provider echo) never stands in for the request's tokens.
--- 3. A price row is admitted only with finite nonnegative "in" and "out"
---    prices in US dollars per million tokens; an unpriced model costs 0.
---
--- Windows reads the same catalogue in windows/modules/llm/api_remote.ahk. Both
--- Lua drivers replay _shared/tests/corpus/llm/remote_usage_vectors.json.
--- ==============================================================================

local M = {}

local Formats = require("llm.remote_formats")
local Json    = require("json")

-- Prices in model_prices are US dollars per this many tokens
local TOKENS_PER_PRICE_UNIT = 1000000




-- ===========================
-- ===========================
-- ======= 1/ Usage ==========
-- ===========================
-- ===========================

--- @return table Zero usage, the shape every classification returns.
local function empty_usage()
	return { prompt_tokens = 0, completion_tokens = 0, total_tokens = 0, est_cost_usd = 0.0 }
end

local function nonnegative_number(value)
	if type(value) ~= "number" or value < 0 or value ~= value then return 0 end
	return value
end

--- The token usage a decoded response root reports, cost left at 0.
--- @param format string "openai" | "anthropic" | "gemini" | "backboard"
--- @param root any Decoded response root.
--- @return table { prompt_tokens, completion_tokens, total_tokens, est_cost_usd }
function M.usage(format, root)
	local out = empty_usage()
	if type(root) ~= "table" then return out end
	if format == "gemini" then
		local usage = root.usageMetadata
		if type(usage) == "table" then
			out.prompt_tokens     = nonnegative_number(usage.promptTokenCount)
			out.completion_tokens = nonnegative_number(usage.candidatesTokenCount)
			out.total_tokens      = nonnegative_number(usage.totalTokenCount)
		end
	elseif format == "anthropic" then
		local usage = root.usage
		if type(usage) == "table" then
			out.prompt_tokens     = nonnegative_number(usage.input_tokens)
			out.completion_tokens = nonnegative_number(usage.output_tokens)
			out.total_tokens      = out.prompt_tokens + out.completion_tokens
		end
	else
		local usage = root.usage
		if type(usage) == "table" then
			out.prompt_tokens     = nonnegative_number(usage.prompt_tokens)
			out.completion_tokens = nonnegative_number(usage.completion_tokens)
			out.total_tokens      = nonnegative_number(usage.total_tokens)
		end
	end
	if out.total_tokens == 0 and out.prompt_tokens > 0 then
		out.total_tokens = out.prompt_tokens + out.completion_tokens
	end
	return out
end




-- ==========================
-- ==========================
-- ======= 2/ Text ==========
-- ==========================
-- ==========================

local function extract_text(format, root)
	if type(root) ~= "table" then return "" end
	if format == "backboard" then return Formats.backboard_text(root) or "" end
	if format == "anthropic" then
		local content = root.content
		if type(content) == "table" then
			for _, block in ipairs(content) do
				if type(block) == "table" and block.type == "text" then
					return type(block.text) == "string" and block.text or ""
				end
			end
		end
		return ""
	end
	if format == "gemini" then
		local candidates = root.candidates
		if type(candidates) == "table" and type(candidates[1]) == "table" then
			local content = candidates[1].content
			if type(content) == "table" and type(content.parts) == "table" then
				for _, part in ipairs(content.parts) do
					if type(part) == "table" and part.thought ~= true
						and type(part.text) == "string" then
						return part.text
					end
				end
			end
		end
		return ""
	end
	local choices = root.choices
	if type(choices) == "table" and type(choices[1]) == "table" then
		local message = choices[1].message
		if type(message) == "table" then
			return type(message.content) == "string" and message.content or ""
		end
	end
	return ""
end

--- Decodes exactly once so completion and usage have one immutable owner. A
--- top-level error envelope carries no completion, even beside a choices
--- array: its text is the provider's decoy, never an answer.
--- @param format string "openai" | "anthropic" | "gemini" | "backboard"
--- @param body string Raw provider response body.
--- @return table { text, usage, valid_json }
function M.classify(format, body)
	if type(body) ~= "string" or body == "" then
		return { text = "", usage = empty_usage(), valid_json = false }
	end
	local root = Json.decode_lossless(body)
	if type(root) ~= "table" or Json.is_null(root) then
		return { text = "", usage = empty_usage(), valid_json = false }
	end
	return {
		text = Formats.response_has_error(root) and "" or extract_text(format, root),
		usage = M.usage(format, root),
		valid_json = true,
	}
end




-- ==========================
-- ==========================
-- ======= 3/ Cost ==========
-- ==========================
-- ==========================

--- @param value any
--- @return boolean Whether value is a finite nonnegative price.
local function price_is_valid(value)
	return type(value) == "number" and value == value and value >= 0
		and value ~= math.huge and value ~= -math.huge
end

--- Admits the valid rows of the catalogue's model_prices map.
--- @param raw any The decoded model_prices member.
--- @return table prices { [model] = { in, out } }
--- @return table skipped Sorted model ids whose row was refused, for the caller to log.
function M.parse_prices(raw)
	local prices, skipped = {}, {}
	if type(raw) ~= "table" or Json.is_null(raw) then return prices, skipped end
	for model, row in pairs(raw) do
		if type(model) == "string" and model ~= "" and type(row) == "table"
			and price_is_valid(row["in"]) and price_is_valid(row["out"])
		then
			prices[model] = { ["in"] = row["in"], ["out"] = row["out"] }
		else
			skipped[#skipped + 1] = tostring(model)
		end
	end
	table.sort(skipped)
	return prices, skipped
end

--- The estimated US dollar cost of one request.
--- @param prices table parse_prices() output.
--- @param model string|nil Model id the request named.
--- @param prompt_tokens number
--- @param completion_tokens number
--- @return number Cost in US dollars, 0 for an unpriced model.
function M.estimate_cost(prices, model, prompt_tokens, completion_tokens)
	local row = type(prices) == "table" and type(model) == "string" and prices[model] or nil
	if not row then return 0.0 end
	return (prompt_tokens * row["in"] + completion_tokens * row["out"]) / TOKENS_PER_PRICE_UNIT
end

return M
