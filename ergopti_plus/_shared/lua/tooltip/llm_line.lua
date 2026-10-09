--- _shared/lua/tooltip/llm_line.lua

--- ==============================================================================
--- MODULE: LLM Prediction Line (Shared)
--- DESCRIPTION:
--- Decides what one line of the prediction tooltip reads: the prefix in front
--- of it, and the pieces of its text with the role each one plays.
---
--- WHY IT IS SHARED:
--- macOS drew this first, inside its canvas code. Linux then drew plain text
--- with the indentation read the other way round, and Windows painted a whole
--- line in the correction colour. One rule, read by the two Lua drivers and
--- ported by the Windows one (ui/tooltip/llm.ahk), pinned on the three by
--- _shared/tests/corpus/tooltip/llm_line_vectors.json.
---
--- FEATURES & RATIONALE:
--- 1. Roles, not colours. A piece is "typed" (already in the document),
---    "corrected" (what the model changed) or "next" (the continuation); each
---    driver maps a role to its own colour object.
--- 2. No drawing. Pure strings in, pure tables out, so the rule is tested
---    without a canvas.
--- ==============================================================================

local M = {}

-- From this indentation down, the lines stay aligned and only the mark moves.
local ALIGNED_FROM = -3




-- =============================================
-- =============================================
-- ======= 1/ Prefixes =========================
-- =============================================
-- =============================================

--- The prefix of the selected line and the one of every other line.
---
--- The indentation is a signed number of spaces:
---   above 0  the selected line is pushed right, mark included;
---   0        the mark sits where the other lines start;
---   -1, -2   the other lines are pushed right by as many spaces;
---   -3       every line starts at the same column and only the mark moves
---            (the other lines carry the mark's own width, drawn invisible);
---   below    the other lines are pushed right past the selected one.
--- With a single line there is nothing to align and the mark stands alone.
--- @param indent number The user's indentation setting.
--- @param line_count number Lines the tooltip shows, reserved ones included.
--- @param mark string The cursor mark of the selected line.
--- @param align string What compensates the mark's side bearing on the others.
--- @return string selected, string unselected
function M.prefixes(indent, line_count, mark, align)
	local level = math.floor(tonumber(indent) or 0)
	local selected = mark
	if line_count >= 2 and level > 0 then selected = string.rep(" ", level) .. mark end

	local unselected = ""
	if level < 0 and level > ALIGNED_FROM then
		unselected = string.rep(" ", -level)
	elseif level <= ALIGNED_FROM then
		unselected = selected .. string.rep(" ", ALIGNED_FROM - level)
	end
	if level > ALIGNED_FROM then unselected = unselected .. align end
	return selected, unselected
end




-- =============================================
-- =============================================
-- ======= 2/ Segments =========================
-- =============================================
-- =============================================

--- The pieces of one prediction line, in reading order.
---
--- The chunks are the end of what the user typed as the model corrected it:
--- an "equal" chunk is text left as typed, an "insert" chunk is a correction.
--- The next words follow. The leading spacing of the line is dropped, and a
--- space is restored between the corrected tail and the next words when
--- neither side brings one.
---
--- On a line that is not selected, the corrections and the next words are bold
--- when the line both corrects something and shows typed text to compare it
--- with: that is what tells a correcting line from a plain continuation while
--- every unselected line wears the same colour.
--- @param prediction table { chunks?, nw?, has_corrections?, disable_bold? }
--- @param is_selected boolean
--- @return table Array of { text, role = "typed"|"corrected"|"next", bold }.
function M.segments(prediction, is_selected)
	local segments = {}
	if type(prediction) ~= "table" then return segments end

	local chunks = type(prediction.chunks) == "table" and prediction.chunks or {}
	local has_typed_reference = false
	for _, chunk in ipairs(chunks) do
		if type(chunk) == "table" and chunk.type == "equal"
			and tostring(chunk.text or ""):match("%S")
		then
			has_typed_reference = true
			break
		end
	end
	local emphasis = (not is_selected) and prediction.has_corrections == true
		and has_typed_reference and not prediction.disable_bold

	local leading_dropped = false
	local function without_leading_spacing(value)
		local text = tostring(value or "")
		if not leading_dropped and text ~= "" then
			text = text:gsub("^%s+", "")
			if text ~= "" then leading_dropped = true end
		end
		return text
	end

	local last_character = ""
	for _, chunk in ipairs(chunks) do
		if type(chunk) == "table" then
			local text = without_leading_spacing(chunk.text)
			if text ~= "" then
				last_character = text:sub(-1)
				if chunk.type == "insert" then
					segments[#segments + 1] = { text = text, role = "corrected", bold = emphasis }
				elseif chunk.type == "equal" then
					segments[#segments + 1] = { text = text, role = "typed", bold = false }
				end
			end
		end
	end

	local next_words = without_leading_spacing(prediction.nw)
	if next_words ~= "" then
		if last_character ~= "" and not last_character:match("%s")
			and not next_words:match("^%s")
		then
			next_words = " " .. next_words
		end
		segments[#segments + 1] = { text = next_words, role = "next", bold = emphasis }
	end

	return segments
end

return M
