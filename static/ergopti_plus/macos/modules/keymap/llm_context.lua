--- modules/keymap/llm_context.lua
--- Bounded independent text and privacy boundary for the AI typing context.
local ContextBuffer = require("ai.engine.policy.context_buffer")
local LlmContextLimit = require("infra.llm_context_limit")
local ComposedText = require("infra.composed_text")
local text_utils = require("core.text.engine.utils_core")
local M = {}

local function update(state, text, mark)
	local length = utf8.len(text)
	if not length then error("invalid UTF-8 AI context", 2) end
	local capacity = state.llm_context_capacity or ContextBuffer.CAPACITY_CODEPOINTS
	local start = length > capacity and utf8.offset(text, length - capacity + 1) or 1
	if start > 1 then
		mark = #mark < start and "" or mark:sub(start)
		text = text:sub(start)
	end
	local visible, remaining = ContextBuffer.after_private(text, mark)
	state.llm_context_text, state.llm_context_mark, state.llm_buffer = text, remaining, visible
	state.llm_context_generation = (state.llm_context_generation or 0) + 1
end

--- Preserve the largest configured capacity for the life of the current context:
--- a setting can be rolled back after its runtime setter returns. A smaller
--- limit becomes active on reset; the prompt builder enforces the current value.
--- Increasing a setting cannot restore text discarded under an earlier limit.
function M.configure(state, configured)
	if not LlmContextLimit.valid(configured) then return false end
	local value = tonumber(configured)
	local capacity = ContextBuffer.CAPACITY_CODEPOINTS
	if value and value == value and value ~= math.huge and value > capacity then
		capacity = math.ceil(value)
	end
	state.llm_context_requested_capacity = capacity
	state.llm_context_capacity = math.max(state.llm_context_capacity or capacity, capacity)
	state.llm_context_generation = (state.llm_context_generation or 0) + 1
	return true
end

--- Seeds the observed text and its exact private prefix.
function M.seed(state, text, mark)
	update(state, text, mark or "")
end

function M.reset(state)
	state.llm_context_capacity = state.llm_context_requested_capacity or ContextBuffer.CAPACITY_CODEPOINTS
	update(state, "", "")
end

function M.append(state, text)
	update(state, (state.llm_context_text or "") .. text, state.llm_context_mark or "")
end

function M.backspace(state)
	local text = state.llm_context_text or ""
	if text == "" then return end
	local start = ComposedText.last_start(text)
	if not start then M.reset(state); return end
	update(state, text:sub(1, start - 1), state.llm_context_mark or "")
end

function M.replace_tail(state, deletes, replacement)
	local current = state.llm_context_text or ""
	local length = utf8.len(current)
	if not length then error("invalid UTF-8 AI context", 2) end
	if type(deletes) ~= "number" or deletes < 0 or deletes % 1 ~= 0 then
		error("invalid AI context deletion", 2)
	end
	local text, err = text_utils.replace_utf8_tail(current, math.min(deletes, length), replacement)
	if not text then error(err or "invalid AI context replacement", 2) end
	update(state, text, state.llm_context_mark or "")
end

function M.mark_private(state)
	local text = state.llm_context_text or ""
	update(state, text, text)
end

return M
