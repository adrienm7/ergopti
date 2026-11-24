--- _shared/diagnostics/engine/reports/issue_link.lua

--- ==============================================================================
--- MODULE: GitHub Issue Link Builder (Shared Lua)
--- DESCRIPTION:
--- Lua port of _shared/ui/issue_link.js for the macOS and Linux drivers: builds
--- the prefilled "new issue" URL of the repository's GitHub issue forms,
--- bounded to the byte budget of _shared/diagnostics/data/issue_templates.json.
---
--- FEATURES & RATIONALE:
--- 1. Pure: the caller passes the templates document and the repository read
---    from _shared/updater/data/defaults.json, so neither is typed here.
--- 2. The budget is measured on the percent-encoded string, where an accented
---    letter costs 6 bytes and an emoji 12.
--- 3. An oversized prefill is cut, never refused: the last parameter first, at
---    a whole code point, ending with the truncation marker; a parameter that
---    cannot keep one code point is dropped; the title goes last and the
---    template never.
--- 4. A cut field can carry a note (one line saying where the complete text is),
---    appended after the truncation marker and counted in the budget: the caller
---    passes it only for the field that holds the complete report.
--- 5. The complete report the user pastes into the form is bounded too:
---    fit_lines keeps whole lines under GitHub's issue body limit, closes a
---    code block it cut open, and ends with the truncation marker and a note
---    saying where the rest is.
--- 6. The JS original and the AHK port (windows/diagnostics/engine/reports/issue_link.ahk) replay the
---    same vectors: _shared/tests/corpus/diagnostics/issue_link_vectors.json.
--- ==============================================================================

local M = {}
local TextUtils = require("core.text.engine.utils_core")





-- ===================================
-- ===================================
-- ======= 1/ Percent-encoding =======
-- ===================================
-- ===================================

-- UTF-8 of U+FFFD: what an invalid byte is encoded as, like a lone UTF-16
-- surrogate in the JS and AHK ports
local REPLACEMENT = "\239\191\189"

--- Splits a UTF-8 string into code points; an invalid byte becomes U+FFFD.
--- @param text string
--- @return table Array of one-code-point strings.
local function code_points(text)
	local out = {}
	local i, n = 1, #text
	while i <= n do
		local b = text:byte(i)
		local len = nil
		if b < 0x80 then len = 1
		elseif b >= 0xC2 and b <= 0xDF then len = 2
		elseif b >= 0xE0 and b <= 0xEF then len = 3
		elseif b >= 0xF0 and b <= 0xF4 then len = 4
		end
		local valid = len ~= nil and i + len - 1 <= n
		if valid then
			for k = i + 1, i + len - 1 do
				local c = text:byte(k)
				if c < 0x80 or c > 0xBF then valid = false break end
			end
		end
		if valid then
			out[#out + 1] = text:sub(i, i + len - 1)
			i = i + len
		else
			out[#out + 1] = REPLACEMENT
			i = i + 1
		end
	end
	return out
end

--- Percent-encodes a query value as UTF-8, only unreserved characters literal.
--- An invalid byte is first replaced by U+FFFD, as in the JS and AHK ports.
--- @param text string
--- @return string
function M.percent_encode(text)
	return TextUtils.percent_encode(table.concat(code_points(tostring(text))))
end





-- ================================
-- ================================
-- ======= 2/ The Issue URL =======
-- ================================
-- ================================

--- Joins the parameters behind the base URL.
--- @param base string
--- @param params table Array of { key, value } pairs.
--- @return string
local function join_url(base, params)
	local query = {}
	for i, pair in ipairs(params) do query[i] = pair[1] .. "=" .. M.percent_encode(pair[2]) end
	return base .. "?" .. table.concat(query, "&")
end

--- Cuts one value so its encoded form fits `budget` bytes with the marker.
--- @param value string
--- @param budget number Encoded bytes the value may take, marker included.
--- @param marker string
--- @return string|nil The cut value, or nil when not one code point fits.
local function cut_value(value, budget, marker)
	local room = budget - #M.percent_encode(marker)
	local parts = code_points(value)
	local kept, used = {}, 0
	-- Strictly shorter than the value: a cut that keeps everything is no cut
	for i = 1, #parts - 1 do
		local cost = #TextUtils.percent_encode(parts[i])
		if used + cost > room then break end
		kept[#kept + 1] = parts[i]
		used = used + cost
	end
	if #kept == 0 then return nil end
	return table.concat(kept) .. marker
end

--- Builds the prefilled issue URL.
--- @param templates table The decoded issue_templates.json document.
--- @param repository table { owner, repo } from the updater defaults.json.
--- @param template_id string Key of templates.templates ("bug", "feature").
--- @param values table|nil Title and field values by id.
--- @param notes table|nil One line per field id, appended on its own line after
---   the truncation marker when that field is cut.
--- @return string The URL, at most templates.max_url_bytes long.
function M.build_url(templates, repository, template_id, values, notes)
	local template = type(templates) == "table" and type(templates.templates) == "table"
		and templates.templates[template_id] or nil
	if type(template) ~= "table" then
		error(string.format("issue_link: unknown template %q", tostring(template_id)), 2)
	end
	if type(repository) ~= "table" or type(repository.owner) ~= "string" or repository.owner == ""
		or type(repository.repo) ~= "string" or repository.repo == "" then
		error("issue_link: the repository needs an owner and a repo", 2)
	end
	local max = templates.max_url_bytes
	local marker = templates.truncation_marker
	-- Plain replacements: an owner is data, never a gsub pattern or replacement
	local base = tostring(templates.issue_new_url)
	local owner_at = base:find("{owner}", 1, true)
	if not owner_at or not base:find("{repo}", 1, true) then
		error("issue_link: issue_new_url must contain {owner} and {repo}", 2)
	end
	base = base:sub(1, owner_at - 1) .. repository.owner .. base:sub(owner_at + #"{owner}")
	local repo_at = base:find("{repo}", 1, true)
	base = base:sub(1, repo_at - 1) .. repository.repo .. base:sub(repo_at + #"{repo}")
	values = type(values) == "table" and values or {}
	notes = type(notes) == "table" and notes or {}

	local params = { { "template", template.file } }
	if type(values.title) == "string" and values.title ~= "" then
		params[#params + 1] = { "title", template.title_prefix .. values.title }
	end
	for _, id in ipairs(template.fields) do
		local value = values[id]
		if value ~= nil and value ~= "" then params[#params + 1] = { id, tostring(value) } end
	end

	for i = #params, 2, -1 do
		local over = #join_url(base, params) - max
		if over <= 0 then break end
		local note = notes[params[i][1]]
		local ending = (type(note) == "string" and note ~= "") and (marker .. "\n\n" .. note) or marker
		local cut = cut_value(params[i][2], #M.percent_encode(params[i][2]) - over, ending)
		if cut == nil then
			table.remove(params, i)
		else
			params[i] = { params[i][1], cut }
			break
		end
	end

	local url = join_url(base, params)
	if #url > max then
		error(string.format("issue_link: %d bytes left after every cut, budget %d", #url, max), 2)
	end
	return url
end





-- ====================================
-- ====================================
-- ======= 3/ The Pasted Report =======
-- ====================================
-- ====================================

-- A line opening or closing a Markdown code block
local FENCE = "```"

--- Bounds a text to a UTF-8 byte budget at whole lines. A text that fits is
--- returned unchanged; otherwise the longest prefix of whole lines that fits
--- with its ending is kept, a code block it leaves open is closed (a kept
--- prefix ending on the opening line drops that line instead), and the
--- truncation marker, a blank line and the note follow.
--- @param text string
--- @param max_bytes number
--- @param marker string
--- @param note string
--- @return string
function M.fit_lines(text, max_bytes, marker, note)
	text = tostring(text)
	if #text <= max_bytes then return text end
	local ending = marker .. "\n\n" .. note
	local lines = {}
	local start = 1
	while true do
		local stop = text:find("\n", start, true)
		if not stop then lines[#lines + 1] = text:sub(start) break end
		lines[#lines + 1] = text:sub(start, stop - 1)
		start = stop + 1
	end
	local prefix_bytes = { [0] = 0 }
	local open, best, best_open = false, 0, false
	-- Strictly fewer lines than the text: a cut that keeps everything is no cut
	for k = 1, #lines - 1 do
		local line = lines[k]
		prefix_bytes[k] = (k == 1 and 0 or prefix_bytes[k - 1] + 1) + #line
		local fence = line:sub(1, #FENCE) == FENCE
		if fence then open = not open end
		-- A block cut right after its opening line keeps nothing of it
		local count, count_open = k, open
		if fence and open then count, count_open = k - 1, false end
		if count >= 1 then
			local cost = prefix_bytes[count] + 1 + (count_open and #FENCE + 1 or 0) + #ending
			if cost <= max_bytes then best, best_open = count, count_open end
		end
	end
	if best < 1 then
		error(string.format("issue_link: not one line fits %d bytes with its ending", max_bytes), 2)
	end
	return table.concat(lines, "\n", 1, best) .. "\n" .. (best_open and FENCE .. "\n" or "") .. ending
end

return M
