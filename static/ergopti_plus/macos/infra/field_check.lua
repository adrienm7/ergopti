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





-- =================================
-- =================================
-- ======= 1/ Evidence model =======
-- =================================
-- =================================

-- The model is shared with the Linux checks (_shared/lua/field_check_report.lua):
-- one grammar for every record the maintainer pastes back.
local Report = require("field_check_report")

--- Step states. A run passes when no step failed; info and skip never fail it.
M.STATE_PASS = Report.STATE_PASS
M.STATE_FAIL = Report.STATE_FAIL
M.STATE_INFO = Report.STATE_INFO
M.STATE_SKIP = Report.STATE_SKIP

--- Longest value a step may carry.
M.MAX_VALUE_LENGTH = Report.MAX_VALUE_LENGTH

--- What replaces a value outside the closed grammar.
M.REDACTED = Report.REDACTED

M.sanitize_value = Report.sanitize_value
M.new_report = Report.new_report
M.format_log_line = Report.format_log_line
M.format_text = Report.format_text

-- Check currently running, or nil. One at a time.
local _running = nil






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
		Logger.evidence(LOG, "Field check result: %s", M.format_log_line(result))
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
