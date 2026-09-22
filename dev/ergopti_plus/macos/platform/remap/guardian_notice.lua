--- platform/remap/guardian_notice.lua

--- ==============================================================================
--- MODULE: Remap Guardian Approval Notice
--- DESCRIPTION:
--- Tells the user, once, when macOS is holding the remap engine's background
--- helper until it is approved in Login Items. A click opens those settings.
---
--- FEATURES & RATIONALE:
--- 1. Proactive: this used to be a status row inside the tray's Karabiner
---    submenu, reachable only by someone who opened that submenu and read it.
---    The engine is an implementation detail now and has no row, so the one
---    fact that needs the user must come to them.
--- 2. Once per episode: every guardian probe re-reports `requires_approval`
---    while it lasts; one notice per transition into that state, not per poll.
--- 3. Owned: an instance is created by the remap bridge that probes the status,
---    so its state lives and dies with that bridge's lifecycle.
--- ==============================================================================

local M = {}

local REQUIRES_APPROVAL = "requires_approval"

--- Creates the notice owned by one remap bridge lifecycle.
--- @param deps table { notify = fn(msg, body, kind, on_click), text = fn(key) -> string,
---        open_settings = fn(on_done) -> boolean, logger = table, log = string }.
--- @return table notice Object with observe(status).
function M.new(deps)
	if type(deps) ~= "table" or type(deps.notify) ~= "function"
		or type(deps.text) ~= "function" or type(deps.open_settings) ~= "function"
		or type(deps.logger) ~= "table" or type(deps.log) ~= "string" then
		error("guardian_notice.new(): notify, text, open_settings, logger and log are required", 2)
	end
	local announced = false
	local notice = {}

	--- Opens Login Items from the notification, and says so when it cannot.
	local function open_settings()
		local accepted = deps.open_settings(function(ok, reason)
			if ok ~= true then
				deps.logger.error(deps.log, "Could not open Login Items settings: %s.", tostring(reason))
				deps.notify(deps.text("karabiner.guardian_settings_open_failed"), nil, "error")
			end
		end)
		return accepted == true
	end

	--- Records one exact guardian observation, notifying on entry into approval.
	--- @param status string|nil Canonical guardian status, nil when unknown.
	--- @return boolean notified True only when this call raised the notice.
	function notice.observe(status)
		if status ~= REQUIRES_APPROVAL then
			-- Unknown is not "approved": a failed probe keeps the episode open.
			if status ~= nil then announced = false end
			return false
		end
		if announced then return false end
		local sent, err = deps.notify(deps.text("karabiner.guardian_approval_required"), nil, "warning",
			open_settings)
		if sent ~= true then
			deps.logger.error(deps.log, "Guardian approval notice was not delivered: %s.", tostring(err))
			return false
		end
		announced = true
		deps.logger.warn(deps.log, "Remap engine awaits Login Items approval — user notified.")
		return true
	end

	return notice
end

return M
