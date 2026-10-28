--- infra/reload_outcome.lua

--- ==============================================================================
--- MODULE: Hotstring Reload Outcome
--- DESCRIPTION:
--- Runs one hotstring catalogue reload and states its outcome truthfully. The
--- loader answers (count, published, refusal): published is false when it
--- refused to publish (a personal-source transaction pending, the engine not
--- ready), and the previous catalogue stays live.
---
--- FEATURES & RATIONALE:
--- 1. A refusal is never reported as success. The log line, the boolean and
---    the local reload control all say "refused" with the loader's reason; the
---    old code logged "Hotstrings reloaded" and answered `completed`.
--- 2. A raised error is a failure, a refusal is a refusal: the control maps
---    them to different result reasons.
--- 3. Shared by the SIGHUP, tray, magic key and file-watcher paths, so no path
---    keeps its own success message.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "infra.reload_outcome"

--- Runs the reload and logs its outcome.
--- @param reload function Loader reload: returns count, published, refusal.
--- @return boolean reloaded True only when the loader published the catalogue.
--- @return string|nil why "failed" when it raised, "refused" when it declined.
--- @return number|nil count Active mapping count when reloaded.
function M.run(reload)
	assert(type(reload) == "function", "a reload function is required")
	local ok, count, published, refusal = pcall(reload)
	if not ok then
		Logger.error(LOG, "Hotstrings reload failed: %s.", tostring(count))
		return false, "failed"
	end
	if published ~= true then
		Logger.warn(LOG, "Hotstrings reload refused (%s); the previous catalogue stays active.",
			tostring(refusal or "no reason given"))
		return false, "refused"
	end
	Logger.success(LOG, "Hotstrings reloaded: %d mapping(s) active.", count or 0)
	return true, nil, count
end

return M
