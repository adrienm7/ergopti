--- _shared/tap_hold/engine/one_shot_timeout.lua

--- ==============================================================================
--- MODULE: One-Shot Modifier Timeout (shared)
--- DESCRIPTION:
--- How long an armed one-shot modifier (one-shot Shift and every sticky_*
--- action) waits for its key: config.toml [tap_holds] sticky_timeout_ms.
---
--- FEATURES & RATIONALE:
--- 1. 0 means no time limit: the one-shot stays armed until a key spends it
---    (maintainer decision of 2026-11-13, replacing the 2026-11-06 refusal).
--- 2. Any positive whole number of milliseconds up to the shared value
---    schema's maximum (2147483647 ms, the Windows timer ceiling) is valid,
---    with no other minimum: a fast typist presses the next key almost at once.
--- 3. A negative, fractional, non-numeric or non-finite value is refused.
--- 4. The one rule for the Lua drivers (macOS and Linux) at entry, at load and
---    at the engine boundary; the Windows driver ports it in AHK
---    (platform/remap/constants.ahk TapHoldValidOneShotTimeoutMs).
--- ==============================================================================

local M = {}

local ValueCheck = require("settings.engine.value_check")

-- The setting's shared value schema declaration, read by every check below.
local KEY = ValueCheck.KEY.TAP_HOLDS_STICKY_TIMEOUT_MS

-- The value that disables the auto-cancel.
M.NO_LIMIT_MS = 0

--- Reports whether a value is an admitted one-shot timeout.
--- @param ms any Candidate milliseconds.
--- @return boolean valid True for a value its declaration admits.
function M.is_valid(ms)
	return ValueCheck.check_value(ValueCheck.declaration(KEY), ms).ok
end

--- Validates a one-shot timeout, failing fast on a refused value.
--- @param ms any Candidate milliseconds.
--- @return number ms The admitted value.
function M.validate(ms)
	if not M.is_valid(ms) then
		error(string.format(
			"tap_holds.sticky_timeout_ms must be 0 (no time limit) or a positive whole number of milliseconds, got %s",
			tostring(ms)), 2)
	end
	return ms
end

--- Reports whether a validated timeout disables the auto-cancel.
--- @param ms number An admitted timeout.
--- @return boolean unlimited
function M.is_unlimited(ms)
	return M.validate(ms) == M.NO_LIMIT_MS
end

--- The deadline of an arm made at `now` (any unit, the timeout's own).
--- @param now number The arm's clock.
--- @param timeout number An admitted timeout in the same unit as now.
--- @return number deadline math.huge when there is no time limit.
function M.deadline(now, timeout)
	assert(type(now) == "number" and type(timeout) == "number" and timeout >= 0 and timeout < math.huge,
		"a one-shot deadline needs a clock and an admitted timeout")
	if timeout == 0 then return math.huge end
	return now + timeout
end

return M
