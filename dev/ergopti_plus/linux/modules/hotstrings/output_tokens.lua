--- modules/hotstrings/output_tokens.lua

--- ==============================================================================
--- MODULE: Hotstring Output Tokens (Linux)
--- DESCRIPTION:
--- Reads a hotstring output through the shared grammar (send_input.parse_output)
--- over the shared vocabulary (_shared/modules/actions/send_keys.json), which
--- holds each key's evdev code.
---
--- FEATURES & RATIONALE:
--- 1. Lazy: the vocabulary is read the first time an output holds a brace or a
---    control character, which the thousands of plain entries never do.
--- 2. A missing or malformed vocabulary raises: the outputs would otherwise be
---    typed as the literal tokens the user asked to press.
--- ==============================================================================

local M = {}

local Paths = require("infra.paths")
local SendInput = require("send_input")

local SEND_KEYS_REL_PATH = "modules/actions/send_keys.json"

local _vocabulary = nil

--- @return table The decoded vocabulary.
local function vocabulary()
	if _vocabulary then return _vocabulary end
	local path = Paths.shared(SEND_KEYS_REL_PATH)
	local handle = path and io.open(path, "r")
	if not handle then error("output_tokens: cannot read " .. tostring(path)) end
	local body = handle:read("*a")
	handle:close()
	local ok, parsed = pcall(require("json").decode, body)
	if not ok or type(parsed) ~= "table" or type(parsed.keys) ~= "table" then
		error("output_tokens: " .. tostring(path) .. " is not a send-input vocabulary")
	end
	_vocabulary = parsed
	return parsed
end

--- @param output string A hotstring output.
--- @return table { tokens, text, has_keys }, as send_input.parse_output.
function M.parse(output)
	if not SendInput.output_needs_parsing(output) then
		return {
			tokens = output == "" and {} or { { kind = "text", value = output } },
			text = output,
			has_keys = false,
		}
	end
	return SendInput.parse_output(output, vocabulary())
end

--- What a loader stores for an output: its characters when it presses no key, so
--- the matcher and the case forms see them; the output as written otherwise.
--- @param output string A hotstring output.
--- @return string replacement
--- @return boolean has_keys
function M.resolve(output)
	local parsed = M.parse(output)
	if parsed.has_keys then return output, true end
	return parsed.text, false
end

return M
