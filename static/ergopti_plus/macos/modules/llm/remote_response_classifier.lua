--- modules/llm/remote_response_classifier.lua

--- ==============================================================================
--- MODULE: Remote LLM Response Classifier
--- DESCRIPTION:
--- Decodes one remote-provider response root and derives both assistant text and
--- canonical token usage from that same root. The module is stateless so tests
--- can exercise the production parser without loading the remote HTTP lifecycle.
--- ==============================================================================

local M = {}

local JsonCodec = require("adapters.json_codec")

local function empty_usage()
	return { prompt_tokens = 0, completion_tokens = 0, total_tokens = 0, est_cost_usd = 0.0 }
end

local function nonnegative_number(value)
	if type(value) ~= "number" or value < 0 or value ~= value then return 0 end
	return value
end

local function extract_usage(format, root)
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

local function extract_text(format, root)
	if type(root) ~= "table" then return "" end
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

--- Decode exactly once so completion and usage have one immutable owner.
--- @param format string "openai" | "anthropic" | "gemini"
--- @param body string Raw provider response body.
--- @return table { text, usage, valid_json }
function M.classify(format, body)
	if type(body) ~= "string" or body == "" then
		return { text = "", usage = empty_usage(), valid_json = false }
	end
	local root, _ = JsonCodec.decode(body)
	if type(root) ~= "table" then
		return { text = "", usage = empty_usage(), valid_json = false }
	end
	return {
		text = extract_text(format, root),
		usage = extract_usage(format, root),
		valid_json = true,
	}
end

return M
