--- _shared/lua/llm/context_buffer.lua

--- ==============================================================================
--- MODULE: AI Context Buffer — Shared Lua Implementation
--- DESCRIPTION:
--- The text the prediction engine completes: a rolling window of what the user
--- typed, kept apart from the hotstring matcher's word buffer so the two have
--- their own lifetimes. macOS keeps the same text in its `llm_buffer`; Linux
--- feeds this object from the hotstring engine's edits. Both drivers decide
--- what a navigation or Escape does to it through the same rule, pinned by
--- _shared/tests/corpus/llm/context_buffer_vectors.json.
---
--- FEATURES & RATIONALE:
--- 1. The hotstring buffer forgets a word on many events (a pause, an arrow,
---    a click, a shortcut) because a trigger must never fire against text the
---    caret has left. The AI context has a different question: should the
---    sentence be sent to the model after the caret moved? That is the
---    `llm.generation.reset_on_nav` preference, nothing else.
--- 2. Edits mirror the engine's: typed text is appended, a Backspace drops the
---    last codepoint, and an expansion deletes its trigger and appends what
---    was really produced, so the context is the text actually in the field.
--- 3. The window is counted in codepoints and cut at a codepoint boundary,
---    wide enough for the largest `llm.generation.context_length` the prompt
---    builder will ever use.
--- 4. Strict input: a non-string text or a malformed count is a caller bug and
---    raises, so the context can never silently drift from the field.
--- ==============================================================================

local M = {}

-- Resolved here rather than assumed to be a global: LuaJIT has no utf8 table.
local utf8_lib = (type(utf8) == "table" and utf8.offset and utf8.len) and utf8 or require("compat.utf8")




-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

--- The rolling window, in codepoints. Larger than every context_length the
--- menu offers, so the prompt builder is the only place the context is capped.
M.CAPACITY_CODEPOINTS = 2048




-- =============================================
-- =============================================
-- ======= 2/ Pure Policy ======================
-- =============================================
-- =============================================

--- What a navigation (arrow, Enter, click) or Escape leaves of the context.
--- @param text string The context before the event.
--- @param reset_on_nav boolean The `llm.generation.reset_on_nav` preference.
--- @return string text The context after the event.
function M.retained_after_navigation(text, reset_on_nav)
	if type(text) ~= "string" then error("context text must be a string", 2) end
	if type(reset_on_nav) ~= "boolean" then error("reset_on_nav must be a boolean", 2) end
	if reset_on_nav then return "" end
	return text
end




-- =============================================
-- =============================================
-- ======= 3/ Buffer Object ====================
-- =============================================
-- =============================================

--- Counts the codepoints of a string that must be valid UTF-8.
--- @param text string
--- @param what string Name of the argument, for the error.
--- @return integer
local function strict_length(text, what)
	if type(text) ~= "string" then error(what .. " must be a string", 3) end
	local length = utf8_lib.len(text)
	if length == nil then error(what .. " is not valid UTF-8", 3) end
	return length
end

--- What the model may see of a mirrored typing buffer after a private expansion.
---
--- macOS mirrors the hotstring buffer instead of editing a separate window, so
--- the text of a private expansion (personal information) stays inside the
--- mirrored text. The mark is the buffer content up to and including that
--- expansion; only what was typed after it is visible. The mark follows the
--- tail edits the buffer undergoes: typing leaves it, a Backspace into it keeps
--- the surviving part marked, and any other divergence (another field, a reset)
--- keeps only the common prefix. Linux needs none of this: its context object
--- clears on a private replacement and appends from there.
--- @param text string The mirrored buffer.
--- @param mark string The buffer content through the last private expansion, "" for none.
--- @return string visible The part of `text` that may reach a prompt.
--- @return string mark The mark to keep for the next call.
function M.after_private(text, mark)
	if type(text) ~= "string" then error("context text must be a string", 2) end
	if type(mark) ~= "string" then error("private mark must be a string", 2) end
	if mark == "" then return text, "" end
	if text:sub(1, #mark) == mark then return text:sub(#mark + 1), mark end
	local limit = math.min(#text, #mark)
	local common = 0
	while common < limit and text:byte(common + 1) == mark:byte(common + 1) do common = common + 1 end
	-- Never cut inside a codepoint: the visible text must stay valid UTF-8.
	while common > 0 and text:byte(common + 1) and text:byte(common + 1) >= 0x80
		and text:byte(common + 1) < 0xC0 do
		common = common - 1
	end
	return text:sub(common + 1), mark:sub(1, common)
end

--- Creates an empty context buffer.
--- @return table buffer With text(), length(), set(), append(), backspace(),
---   replace_tail(), clear() and navigated().
function M.new()
	local current = ""
	local count = 0

	local buffer = {}

	--- Drops the oldest codepoints beyond the window.
	local function trim()
		if count <= M.CAPACITY_CODEPOINTS then return end
		local start = utf8_lib.offset(current, count - M.CAPACITY_CODEPOINTS + 1)
		current = current:sub(start)
		count = M.CAPACITY_CODEPOINTS
	end

	--- The context as a string.
	--- @return string
	function buffer:text() return current end

	--- The context length in codepoints.
	--- @return integer
	function buffer:length() return count end

	--- Replaces the whole context with text known to be in the field.
	--- @param text string
	function buffer:set(text)
		count = strict_length(text, "context text")
		current = text
		trim()
	end

	--- Appends typed text.
	--- @param text string
	function buffer:append(text)
		count = count + strict_length(text, "appended text")
		current = current .. text
		trim()
	end

	--- Mirrors a Backspace: drops the last codepoint, if any.
	function buffer:backspace()
		if count == 0 then return end
		current = current:sub(1, utf8_lib.offset(current, count) - 1)
		count = count - 1
	end

	--- Mirrors an expansion: deletes the trigger from the tail, appends what the
	--- application received. Deleting more than is known removes all of it, as the
	--- hotstring engine does for its own window.
	--- @param deletes integer Non-negative count of codepoints erased.
	--- @param text string The text that replaced them.
	function buffer:replace_tail(deletes, text)
		if type(deletes) ~= "number" or deletes < 0 or deletes ~= math.floor(deletes) then
			error("delete count must be a non-negative integer", 2)
		end
		local added = strict_length(text, "replacement text")
		local removed = math.min(deletes, count)
		if removed == count then
			current, count = "", 0
		elseif removed > 0 then
			current = current:sub(1, utf8_lib.offset(current, count - removed + 1) - 1)
			count = count - removed
		end
		current = current .. text
		count = count + added
		trim()
	end

	--- Forgets the context: another field, a pause, a password, the AI off, a
	--- text change the driver cannot describe.
	function buffer:clear()
		current, count = "", 0
	end

	--- Applies a navigation or Escape.
	--- @param reset_on_nav boolean The `llm.generation.reset_on_nav` preference.
	--- @return boolean cleared Whether text was forgotten.
	function buffer:navigated(reset_on_nav)
		local retained = M.retained_after_navigation(current, reset_on_nav)
		if retained == current then return false end
		self:clear()
		return true
	end

	return buffer
end

return M
