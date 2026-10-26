--- _shared/lua/quit_admission.lua

--- ==============================================================================
--- MODULE: Quit Admission
--- DESCRIPTION:
--- The one decision of when the tray's Quit is refused, shared by the macOS and
--- Linux drivers. A refused Quit changes nothing and tells the user with the
--- same notification (`notify.quit_refused`, see feature_notice.lua) on both.
---
--- FEATURES & RATIONALE:
--- 1. Pure Decision: the driver reads four facts from its own owners and this
---    module answers admitted or refused with a cause. It never touches an owner,
---    so a driver cannot grow a refusal the other one lacks without editing the
---    shared contract test both replay.
--- 2. Four Causes, In Order: the global action owner is missing; a reload or an
---    exit already owns the process; a global configuration writer (a reset, a
---    scope restore, a retained rollback) is still active; a hotstring
---    publication or its recovery is pending. The first matching cause names the
---    refusal.
--- 3. One Wording: the cause carries the log line, so the same refusal reads the
---    same in both user logs, followed by the one user notification.
--- 4. Reload Is A Deferral On macOS: its menu holds a Quit click made during a
---    reload and replays it once the reload ends (ui.menu.click_gate), so
---    `terminal_pending` is reached there only by a caller outside the menu.
---    Linux restarts the process on reload and has no hand-off to the successor,
---    so it refuses the click instead and the user retries.
--- ==============================================================================

local FeatureNotice = require("feature_notice")

local M = {}

--- The refusal causes, in the order they are tested.
M.CAUSE_OWNER_UNAVAILABLE = "owner_unavailable"
M.CAUSE_TERMINAL_PENDING = "terminal_pending"
M.CAUSE_WRITER_ACTIVE = "writer_active"
M.CAUSE_PUBLICATION_PENDING = "publication_pending"

--- The fact names a driver supplies, in the order of the causes they gate.
M.FACTS = { "owner_available", "terminal_pending", "writer_active", "publication_pending" }

local MESSAGES = {
	[M.CAUSE_OWNER_UNAVAILABLE] = "Quit refused: the global action owner is unavailable.",
	[M.CAUSE_TERMINAL_PENDING] = "Quit refused: a reload or an exit already owns the process.",
	[M.CAUSE_WRITER_ACTIVE] = "Quit refused: a global configuration writer is still active.",
	[M.CAUSE_PUBLICATION_PENDING] = "Quit refused: a hotstring publication is still pending.",
}

--- Decides whether Quit may start.
--- @param facts table Booleans: owner_available (the driver can run a global
---   action), terminal_pending (a reload or an exit owns the process),
---   writer_active (a global configuration writer or its retained rollback is
---   active), publication_pending (a hotstring publication or recovery is pending).
--- @return table decision { admitted = boolean, cause = string|nil, message = string|nil }
function M.decide(facts)
	if type(facts) ~= "table" then error("quit admission needs its facts", 2) end
	for _, name in ipairs(M.FACTS) do
		if type(facts[name]) ~= "boolean" then
			error("quit admission fact '" .. name .. "' must be a boolean", 2)
		end
	end
	local cause
	if not facts.owner_available then
		cause = M.CAUSE_OWNER_UNAVAILABLE
	elseif facts.terminal_pending then
		cause = M.CAUSE_TERMINAL_PENDING
	elseif facts.writer_active then
		cause = M.CAUSE_WRITER_ACTIVE
	elseif facts.publication_pending then
		cause = M.CAUSE_PUBLICATION_PENDING
	end
	if cause == nil then return { admitted = true } end
	return { admitted = false, cause = cause, message = MESSAGES[cause] }
end

--- Logs the cause of a refusal, then tells the user.
--- @param ports table { send, info, warn } as feature_notice.lua expects.
--- @param translate function Locale lookup: key -> localized text.
--- @param decision table A refused decision from decide().
function M.refuse(ports, translate, decision)
	if type(decision) ~= "table" or decision.admitted ~= false or type(decision.message) ~= "string" then
		error("quit admission can only report a refused decision", 2)
	end
	assert(type(ports) == "table" and type(ports.warn) == "function", "quit admission needs a warn port")
	ports.warn("%s", decision.message)
	FeatureNotice.quit_refused(ports, translate)
end

return M
