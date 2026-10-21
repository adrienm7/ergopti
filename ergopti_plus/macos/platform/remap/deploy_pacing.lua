--- platform/remap/deploy_pacing.lua

--- ==============================================================================
--- MODULE: Karabiner Deploy Pacing
--- DESCRIPTION:
--- Decides whether a lease recovery deploy waits for the user to stop typing.
--- A recovery generation rewrites karabiner.json under a fresh token, and
--- Karabiner reloads every rule, personal ones included, when that file changes;
--- a reload while keys move can lose one. The fenced generation's rules are
--- already inert, so its replacement can wait for a short input silence.
---
--- FEATURES & RATIONALE:
--- 1. Bounded: the wait never exceeds MAX_DEFER_SEC, so recovery still completes
---    while someone types without pause.
--- 2. Fail-open on the probe only: an unknown idle time never delays a deploy.
--- 3. Visible: every deferral and every bound reached is one INFO line.
--- ==============================================================================

local M = {}

local Logger     = require("infra.logger")
local SystemInfo = require("adapters.system_info")

local LOG = "karabiner"

-- Input silence that counts as "between words", the recheck interval, and the
-- longest a recovery deploy may wait for it.
M.QUIET_SEC = 0.75
M.RECHECK_SEC = 0.25
M.MAX_DEFER_SEC = 5.0

--- Decides one recovery deploy.
--- @param waited number Seconds this attempt has already waited.
--- @param attempt number Recovery attempt number, for the log.
--- @return number|nil recheck_sec Delay before the next check, or nil to deploy now.
function M.recheck_after(waited, attempt)
	local probed, idle = pcall(SystemInfo.input_idle_seconds)
	if not probed or type(idle) ~= "number" or idle >= M.QUIET_SEC then return nil end
	if waited >= M.MAX_DEFER_SEC then
		Logger.info(LOG,
			"Karabiner deploy decision: deploying during input after the %.1f s typing deferral bound (recovery attempt %d).",
			waited, attempt)
		return nil
	end
	if waited == 0 then
		Logger.info(LOG,
			"Karabiner deploy decision: deferred-for-typing (input %.0f ms ago; recovery attempt %d waits up to %.1f s for %.0f ms of quiet).",
			idle * 1000, attempt, M.MAX_DEFER_SEC, M.QUIET_SEC * 1000)
	end
	return M.RECHECK_SEC
end

return M
