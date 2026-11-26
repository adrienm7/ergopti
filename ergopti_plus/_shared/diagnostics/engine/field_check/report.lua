--- _shared/diagnostics/engine/field_check/report.lua

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
--- 4. The log line keeps the closed codes the maintainer reads; the window
---    text shows each value token through field_check.value.<token>, so no raw
---    code follows a translated label (the Windows composer check renders the
---    same way in ComposerCheck_DisplayValue).
--- ==============================================================================

local LabelValue = require("core.i18n.engine.label_value")

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
	-- The closed code of a prerequisite that kept the check from running, or nil.
	local not_run = nil
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

	--- Marks the check as not run: a prerequisite it does not own was missing, so
	--- the run proves nothing either way (a field run records it as a skip).
	--- @param code string Closed code of the missing prerequisite.
	function report.not_run(code)
		assert(M.sanitize_value(code) == code and code ~= M.REDACTED, "field check: not-run code must be a closed code")
		assert(not_run == nil, "field check: not-run recorded twice")
		not_run = code
	end

	--- Snapshot of the run so far.
	function report.result()
		local copy, passed = {}, true
		for index, step in ipairs(steps) do
			copy[index] = { id = step.id, state = step.state, value = step.value }
			if step.state == M.STATE_FAIL then passed = false end
		end
		return { check = check_id, steps = copy, passed = passed, not_run = not_run }
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
	local verdict = result.not_run and "skip" or result.passed and "pass" or "fail"
	return string.format("check=%s verdict=%s steps=%d %s", result.check,
		verdict, #result.steps, table.concat(parts, " "))
end

--- The locale key prefix of a step value token (field_check.value.<token>).
M.VALUE_KEY_PREFIX = "field_check.value."

-- Tokens that carry a number or a name inside them: the pattern, the key that
-- spells them, and the part the key's {1} receives.
local VALUE_FAMILIES = {
	{ pattern = "^http_(%d+)_direct$", key = "http_n_direct" },
	{ pattern = "^http_(%d+)$", key = "http_n" },
	{ pattern = "^required_(%w+)$", key = "required_scheme" },
}

--- The text of a locale key, nil when the catalogue does not hold it (the
--- lookup answers with the key itself and has already reported the miss).
local function lookup(translate, key)
	local text = translate(key)
	if type(text) ~= "string" or text == key then return nil end
	return text
end

--- Fills the {1} slot of a template with literal text.
local function fill(template, text)
	return (template:gsub("{1}", function() return text end))
end

--- One token of a value in the user's language.
--- @param token string
--- @param translate function
--- @return string text
--- @return boolean known Whether the catalogue spells this token itself.
function M.display_token(token, translate)
	-- Counts, durations and versions read the same in every language.
	if token:match("^%-?%d[%d%.]*$") then return token, true end
	local text = lookup(translate, M.VALUE_KEY_PREFIX .. token)
	if text then return text, true end
	for _, family in ipairs(VALUE_FAMILIES) do
		local part = token:match(family.pattern)
		if part then
			local template = lookup(translate, M.VALUE_KEY_PREFIX .. family.key)
			if template then return fill(template, part), true end
		end
	end
	-- An open code (a native failure stage) is named as a code, never shown
	-- bare after a translated label.
	local other = lookup(translate, M.VALUE_KEY_PREFIX .. "other")
	return other and fill(other, token) or token, false
end

--- The tokens of a value the catalogue does not spell (shown as « code … »).
--- @param value string
--- @param translate function
--- @return table tokens
function M.unknown_tokens(value, translate)
	local unknown = {}
	for token in tostring(value):gmatch("[^+:]+") do
		local _, known = M.display_token(token, translate)
		if not known then unknown[#unknown + 1] = token end
	end
	return unknown
end

--- A step value in the user's language: "+" joins alternatives and ":" pairs
--- a name with its detail (registry:direct+blob:direct).
--- @param value string Sanitized step value.
--- @param translate function key → localized text.
--- @return string
function M.display_value(value, translate)
	local parts = {}
	for part in tostring(value):gmatch("[^+]+") do
		local head, rest = part:match("^([^:]*):(.+)$")
		if head and head ~= "" then
			parts[#parts + 1] = LabelValue.compose(translate, (M.display_token(head, translate)),
				M.display_value(rest, translate))
		else
			parts[#parts + 1] = (M.display_token((part:gsub(":$", "")), translate))
		end
	end
	return table.concat(parts, ", ")
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
		if step.value then line = LabelValue.compose(translate, line, M.display_value(step.value, translate)) end
		lines[#lines + 1] = line
	end
	return table.concat(lines, "\n")
end

return M
