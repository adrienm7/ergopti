--- infra/field_check.lua

--- ==============================================================================
--- MODULE: Field Check Engine
--- DESCRIPTION:
--- Runs the one-click Mac checks of the Debug menu (Karabiner lease, owned
--- Karabiner runtime dormancy, key accounting) and turns each run into a
--- compact, privacy-safe evidence record: one step per line, a state and an
--- optional short value. The maintainer pastes that record back from the log
--- or from the result window's « Copy report » button.
---
--- FEATURES & RATIONALE:
--- 1. Ports: a check never touches Hammerspoon, the file system or a process
---    itself. It receives a table of ports (path_exists, exec, after, ...), so
---    the same steps run against fixtures in the portable suite and against
---    the real Mac through adapters/field_check_ports.lua.
--- 2. Privacy by construction: a step value must match a closed grammar (letters,
---    digits and . _ : + -, 48 characters at most). Anything else, such as a
---    path, a URL or a user name, is replaced by "redacted". Checks report
---    counts and enumerated states, never key codes, characters or paths.
--- 3. One run at a time: a second click while a check is pending is refused, so
---    two key counters never overlap and the log lines never interleave.
--- 4. Settle once: a check finishes exactly once, even if a port calls back
---    twice; a check that raises is recorded as a failed step, not lost.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "field_check"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

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

-- Check currently running, or nil. One at a time.
local _running = nil





-- =================================
-- =================================
-- ======= 2/ Evidence model =======
-- =================================
-- =================================

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





-- ==========================
-- ==========================
-- ======= 3/ Running =======
-- ==========================
-- ==========================

--- Reports whether a check is pending.
--- @return boolean
function M.is_running()
	return _running ~= nil
end

--- Runs one check and delivers its result exactly once.
--- @param check_id string Identity in infra.field_check_checks.
--- @param ports table The ports the check needs.
--- @param on_done function Receives the result table.
--- @return boolean started False when a check is already pending or unknown.
function M.run(check_id, ports, on_done)
	assert(type(on_done) == "function", "field check: on_done must be a function")
	if _running ~= nil then
		Logger.warn(LOG, "Check '%s' refused: '%s' is still running.", tostring(check_id), _running)
		return false
	end
	local definition = require("infra.field_check_checks").checks[check_id]
	if type(definition) ~= "function" then
		Logger.error(LOG, "Unknown check '%s'.", tostring(check_id))
		return false
	end
	_running = check_id
	Logger.start(LOG, "Field check '%s' started.", check_id)
	local report, settled = M.new_report(check_id), false
	local function finish()
		if settled then return end
		settled = true
		_running = nil
		local result = report.result()
		Logger.info(LOG, "Field check result: %s", M.format_log_line(result))
		Logger.done(LOG, "Field check '%s' finished: %s.", check_id, result.passed and "pass" or "fail")
		on_done(result)
	end
	local ran, err = pcall(definition, ports, report, finish)
	if not ran then
		Logger.error(LOG, "Field check '%s' raised: %s", check_id, tostring(err))
		pcall(report.step, "internal_error", M.STATE_FAIL, "raised")
		finish()
	end
	return true
end

--- Forgets a pending run; tests only.
function M._reset()
	_running = nil
end

return M
