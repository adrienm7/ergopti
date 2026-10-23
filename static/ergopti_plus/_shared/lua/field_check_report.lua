--- _shared/lua/field_check_report.lua

--- ==============================================================================
--- MODULE: Field Check Report (Shared)
--- DESCRIPTION:
--- The evidence model of the one-click Debug checks on macOS and Linux (the
--- Windows composer check follows the same grammar in AutoHotkey): a report is
--- a list of steps, each with a state and an optional short value, and renders
--- as the one log line the maintainer pastes back and as the text of the result
--- window and its « Copy report » button.
---
--- FEATURES & RATIONALE:
--- 1. Privacy by construction: a step value must match a closed grammar
---    (letters, digits and . _ : + -, 48 characters at most). Anything else,
---    such as a path, a URL or a user name, is replaced by "redacted".
--- 2. A step cannot be recorded twice, and a run passes unless a step failed;
---    info and skip never fail it.
--- 3. PURE Lua: no logger, no file system, no clock. The drivers' engines own
---    running, logging and presentation.
--- ==============================================================================

local M = {}

--- Step states. A run passes when no step failed; info and skip never fail it.
M.STATE_PASS = "pass"
M.STATE_FAIL = "fail"
M.STATE_INFO = "info"
M.STATE_SKIP = "skip"

--- Longest value a step may carry.
M.MAX_VALUE_LENGTH = 48

--- What replaces a value outside the closed grammar.
M.REDACTED = "redacted"

local STATES = {
	[M.STATE_PASS] = true, [M.STATE_FAIL] = true,
	[M.STATE_INFO] = true, [M.STATE_SKIP] = true,
}

--- Returns a value that is safe to log, or the redaction marker.
--- @param value any Candidate value.
--- @return string|nil safe nil when there is no value.
function M.sanitize_value(value)
	if value == nil then return nil end
	local text = tostring(value)
	if text == "" then return nil end
	if #text > M.MAX_VALUE_LENGTH or not text:match("^[%w_%.:%+%-]+$") then
		return M.REDACTED
	end
	return text
end

--- Creates an empty report for one check.
--- @param check_id string Check identity.
--- @return table report With step(id, state, value) and result().
function M.new_report(check_id)
	assert(type(check_id) == "string" and check_id ~= "", "field check: check id must be a non-empty string")
	local steps, seen = {}, {}
	local report = {}

	--- Records one step; a repeated step identity is a bug and raises.
	function report.step(id, state, value)
		assert(type(id) == "string" and id ~= "", "field check: step id must be a non-empty string")
		assert(STATES[state], "field check: unknown step state " .. tostring(state))
		assert(not seen[id], "field check: step recorded twice: " .. id)
		seen[id] = true
		steps[#steps + 1] = { id = id, state = state, value = M.sanitize_value(value) }
	end

	--- Whether a step was already recorded.
	function report.has(id)
		return seen[id] == true
	end

	--- Snapshot of the run so far.
	function report.result()
		local copy, passed = {}, true
		for index, step in ipairs(steps) do
			copy[index] = { id = step.id, state = step.state, value = step.value }
			if step.state == M.STATE_FAIL then passed = false end
		end
		return { check = check_id, steps = copy, passed = passed }
	end

	return report
end

--- Renders a result as the one log line the maintainer pastes back.
--- @param result table From report.result().
--- @return string
function M.format_log_line(result)
	local parts = {}
	for _, step in ipairs(result.steps) do
		local part = step.id .. "=" .. step.state
		if step.value then part = part .. ":" .. step.value end
		parts[#parts + 1] = part
	end
	return string.format("check=%s verdict=%s steps=%d %s", result.check,
		result.passed and "pass" or "fail", #result.steps, table.concat(parts, " "))
end

local MARKS = {
	[M.STATE_PASS] = "✅", [M.STATE_FAIL] = "❌",
	[M.STATE_INFO] = "ℹ️", [M.STATE_SKIP] = "➖",
}

--- Renders a result for the window and the clipboard, one line per step.
--- @param result table From report.result().
--- @param translate function key → localized text.
--- @return string
function M.format_text(result, translate)
	local lines = {
		translate(result.passed and "field_check.verdict_pass" or "field_check.verdict_fail"),
		"",
	}
	for _, step in ipairs(result.steps) do
		local line = MARKS[step.state] .. " " .. translate("field_check.step." .. step.id)
		if step.value then line = line .. " : " .. step.value end
		lines[#lines + 1] = line
	end
	return table.concat(lines, "\n")
end

return M
