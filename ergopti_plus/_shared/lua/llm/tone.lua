--- _shared/lua/llm/tone.lua

--- ==============================================================================
--- MODULE: Tone Ladder — Shared Lua Implementation
--- DESCRIPTION:
--- The pure logic behind the "more formal" / "more familiar" actions: which
--- register a selection moves to, and which text is rewritten into it.
---
--- FEATURES & RATIONALE:
--- 1. Four built-in rewrite profiles form a ladder, from familiar to very
---    formal. A selection the actions did not write starts at neutral.
--- 2. Each step rewrites the ORIGINAL text into the target register, never the
---    previous rewrite, so going back and forth never drifts from what the user
---    wrote. The memory of the last rewrite ties a selection to its original.
--- 3. Two flavours per direction: one stops at the end of the ladder, the
---    other wraps around to the opposite end.
--- 4. The model answers with the rewrite tag; extract() reads that answer
---    without the typing-buffer alignment of the prediction parser, because a
---    selection is replaced whole.
---
--- The AutoHotkey port is windows/modules/llm/tone.ahk. Both are pinned by
--- _shared/tests/corpus/llm/tone_vectors.json.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Built-in profile ids, from the most familiar register to the most formal
M.LADDER = { "tone_familiar", "tone_neutral", "tone_formal", "tone_very_formal" }

-- Level of a selection the tone actions did not write: neutral
M.START_LEVEL = 2

-- Step directions
M.MORE_FORMAL = 1
M.MORE_FAMILIAR = -1

-- Tag the tone prompts ask the model to answer with (the rewrite tag)
M.OUTPUT_TAG = "REWRITE:"

-- Quote pairs a model may wrap its whole answer in
local QUOTE_PAIRS = { { '"', '"' }, { "\226\128\156", "\226\128\157" }, { "\194\171", "\194\187" } }




-- =====================================
-- =====================================
-- ======= 2/ Public API ===============
-- =====================================
-- =====================================

--- Returns the level one step away from `level`.
--- @param level number Current ladder index.
--- @param direction number M.MORE_FORMAL or M.MORE_FAMILIAR.
--- @param cycle boolean Whether to wrap around at the ends of the ladder.
--- @return number|nil level The next index, nil at an end without cycling.
function M.step(level, direction, cycle)
	if direction ~= M.MORE_FORMAL and direction ~= M.MORE_FAMILIAR then
		error("tone.step: direction must be MORE_FORMAL or MORE_FAMILIAR")
	end
	if type(level) ~= "number" or level < 1 or level > #M.LADDER then
		error("tone.step: level out of range: " .. tostring(level))
	end
	local target = level + direction
	if target >= 1 and target <= #M.LADDER then return target end
	if not cycle then return nil end
	return target < 1 and #M.LADDER or 1
end

--- Plans one step for a selection.
--- @param selection string The selected text.
--- @param memory table|nil The last rewrite: { source, output, level }.
--- @param direction number M.MORE_FORMAL or M.MORE_FAMILIAR.
--- @param cycle boolean Whether to wrap around at the ends of the ladder.
--- @return table|nil plan { source, level, profile_id } to rewrite.
--- @return string|nil reason "empty_selection" or "end_of_ladder" when there is nothing to do.
function M.plan(selection, memory, direction, cycle)
	if type(selection) ~= "string" or not selection:find("%S") then
		return nil, "empty_selection"
	end
	local source, level = selection, M.START_LEVEL
	if type(memory) == "table" and memory.output == selection then
		source, level = memory.source, memory.level
	end
	local target = M.step(level, direction, cycle)
	if not target then return nil, "end_of_ladder" end
	return { source = source, level = target, profile_id = M.LADDER[target] }, nil
end

--- Builds the memory that ties the rewrite now selected to its original.
--- @param plan table The plan that was rewritten.
--- @param output string The text that replaced the selection.
--- @return table memory { source, output, level }.
function M.remember(plan, output)
	return { source = plan.source, output = output, level = plan.level }
end

--- Extracts the rewritten text from a model answer.
--- @param block string The raw model answer.
--- @return string|nil text The rewrite, nil when the answer holds none.
function M.extract(block)
	if type(block) ~= "string" then return nil end
	local text = block:match("[Rr][Ee][Ww][Rr][Ii][Tt][Ee]%s*:%s*(.-)%s*$")
	if not text then return nil end
	text = text:match("^([^\r\n]*)") or ""
	text = text:gsub("%*%*", "")
	text = text:match("^%s*(.-)%s*$")
	-- Only a pair that wraps the whole answer is the model quoting it
	for _, pair in ipairs(QUOTE_PAIRS) do
		local open, close = pair[1], pair[2]
		if #text > #open + #close and text:sub(1, #open) == open and text:sub(-#close) == close then
			text = text:sub(#open + 1, #text - #close):match("^%s*(.-)%s*$")
			break
		end
	end
	if text == "" then return nil end
	return text
end

return M
