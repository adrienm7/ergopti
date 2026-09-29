--- _shared/lua/diagnostics/issue_report.lua

--- ==============================================================================
--- MODULE: Bug Report Text (Shared Lua)
--- DESCRIPTION:
--- The text of a bug report, for the macOS and Linux drivers: the full
--- diagnostics as Markdown, copied to the clipboard and prefilled into the
--- GitHub issue form. Pure; the AHK port (windows/infra/issue_report.ahk)
--- replays the same vectors
--- (_shared/tests/corpus/diagnostics/issue_report_vectors.json).
---
--- FEATURES & RATIONALE:
--- 1. dump() writes every field of a diagnostic snapshot, keys sorted, so the
---    report is complete and two reports of one state are byte-identical.
---    Each driver's snapshot differs; the format does not.
--- 2. The whole report is prefilled: GitHub answers 414 a little above 8 KB,
---    so the issue link cuts it to its budget, and the clipboard keeps it
---    whole.
--- 3. Nothing here redacts: the caller redacts the finished text with
---    diagnostics.redact, the single place that decides what leaves the
---    machine.
--- ==============================================================================

local M = {}





-- ================================
-- ================================
-- ======= 1/ Snapshot Dump =======
-- ================================
-- ================================

-- What an empty table and an empty string render as, so a line never ends in
-- a bare colon a reader could take for a missing value
local EMPTY_TABLE = "(none)"
local EMPTY_STRING = "(empty)"

--- Renders a scalar: integral numbers without a fraction, others with two
--- decimals, so every port prints the same digits.
--- @param value any
--- @return string
local function scalar(value)
	if type(value) == "number" then
		if value == math.floor(value) then return string.format("%d", value) end
		return string.format("%.2f", value)
	end
	local text = tostring(value)
	if text == "" then return EMPTY_STRING end
	return text
end

--- True when the table is a non-empty sequence 1..n.
--- @param value table
--- @return boolean
local function is_array(value)
	local count = 0
	for _ in pairs(value) do count = count + 1 end
	return count > 0 and count == #value
end

--- The table's keys, sorted as strings.
--- @param value table
--- @return table
local function sorted_keys(value)
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

--- Appends one labelled value, recursing into tables.
--- @param lines table Output lines.
--- @param indent string
--- @param label string "key:" or "-".
--- @param value any
local function emit(lines, indent, label, value)
	if type(value) == "table" then
		if next(value) == nil then
			lines[#lines + 1] = indent .. label .. " " .. EMPTY_TABLE
			return
		end
		lines[#lines + 1] = indent .. label
		if is_array(value) then
			for _, item in ipairs(value) do emit(lines, indent .. "  ", "-", item) end
		else
			for _, key in ipairs(sorted_keys(value)) do
				emit(lines, indent .. "  ", tostring(key) .. ":", value[key])
			end
		end
		return
	end
	local text = scalar(value):gsub("\r\n", "\n")
	local first = true
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if first then
			lines[#lines + 1] = indent .. label .. " " .. line
			first = false
		else
			lines[#lines + 1] = indent .. "  " .. line
		end
	end
end

--- Writes every field of a snapshot, keys sorted, one per line.
--- @param snapshot table
--- @return string
function M.dump(snapshot)
	if type(snapshot) ~= "table" then error("issue_report: the snapshot must be a table", 2) end
	local lines = {}
	for _, key in ipairs(sorted_keys(snapshot)) do emit(lines, "", tostring(key) .. ":", snapshot[key]) end
	return table.concat(lines, "\n")
end





-- ==================================
-- ==================================
-- ======= 2/ Markdown Report =======
-- ==================================
-- ==================================

--- Escapes a Markdown table cell.
--- @param value any
--- @return string
local function cell(value)
	local text = tostring(value == nil and "" or value):gsub("[\r\n]+", " "):gsub("|", "\\|")
	return text
end

--- A code fence longer than every backtick run in the text, so the report can
--- never close its own block.
--- @param text string
--- @return string
local function fence_for(text)
	local longest = 0
	for run in text:gmatch("`+") do
		if #run > longest then longest = #run end
	end
	return string.rep("`", math.max(3, longest + 1))
end

--- The full report, as a Markdown document.
--- @param info table { version, commit, os, driver, generated_utc, warn_count, err_count }
--- @param body string The dumped snapshot.
--- @return string
function M.markdown(info, body)
	local fence = fence_for(body)
	return table.concat({
		"# ErgoptiPlus diagnostics",
		"",
		"| Field | Value |",
		"| --- | --- |",
		"| Version | " .. cell(info.version) .. " |",
		"| Commit | " .. cell(info.commit) .. " |",
		"| OS | " .. cell(info.os) .. " |",
		"| Driver | " .. cell(info.driver) .. " |",
		"| Generated (UTC) | " .. cell(info.generated_utc) .. " |",
		"| Warnings / errors this session | " .. scalar(info.warn_count) .. " / " .. scalar(info.err_count) .. " |",
		"",
		fence .. "text",
		body,
		fence,
		"",
	}, "\n")
end

return M
