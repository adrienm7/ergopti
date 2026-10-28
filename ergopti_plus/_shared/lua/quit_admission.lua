--- _shared/lua/quit_admission.lua

--- ==============================================================================
--- MODULE: Quit Admission
--- DESCRIPTION:
--- The one decision of what the tray's Quit does, shared by the macOS and Linux
--- drivers. The user asked to quit, so Quit wins: it is refused only when it
--- cannot mean anything, and otherwise it waits for a configuration write that is
--- already running and then proceeds, abandoning a reload that was in flight.
---
--- FEATURES & RATIONALE:
--- 1. Pure Decision: the driver reads five facts from its own owners and this
---    module answers admitted, deferred or refused. It never touches an owner, so
---    a driver cannot grow a behaviour the other one lacks without editing the
---    shared contract test both replay.
--- 2. Refused: the global action owner is missing, or an exit already owns the
---    process (a second click while quitting). The user is told with the single
---    `notify.quit_refused` notice (feature_notice.lua).
--- 3. Deferred: a global configuration writer (a reset, a scope restore, a
---    retained rollback) or a hotstring publication is still running. It is
---    allowed to finish or roll back first, so Quit never cuts a write in half;
---    `await` polls it and gives up with the refusal notice after the bound the
---    driver passes (the user-quit deadline).
--- 4. Reload Abandoned: a reload in flight does not delay or refuse Quit. The
---    decision carries `abandon_reload` and the driver turns the reload into the
---    exit (macOS upgrades the coordinator transaction, Linux cancels the pending
---    restart). A Quit click is therefore never held and replayed after a reload.
--- 5. One Wording: the cause carries the log line, so the same outcome reads the
---    same in both user logs.
--- ==============================================================================

local FeatureNotice = require("feature_notice")

local M = {}

--- The causes that refuse or defer Quit, in the order they are tested.
M.CAUSE_OWNER_UNAVAILABLE = "owner_unavailable"
M.CAUSE_EXIT_PENDING = "exit_pending"
M.CAUSE_WRITER_ACTIVE = "writer_active"
M.CAUSE_PUBLICATION_PENDING = "publication_pending"

--- The fact names a driver supplies.
M.FACTS = { "owner_available", "exit_pending", "reload_pending", "writer_active", "publication_pending" }

local MESSAGES = {
	[M.CAUSE_OWNER_UNAVAILABLE] = "Quit refused: the global action owner is unavailable.",
	[M.CAUSE_EXIT_PENDING] = "Quit refused: an exit already owns the process.",
	[M.CAUSE_WRITER_ACTIVE] = "Quit waits: a global configuration writer is still active.",
	[M.CAUSE_PUBLICATION_PENDING] = "Quit waits: a hotstring publication is still pending.",
}

--- Decides what Quit does now.
--- @param facts table Booleans: owner_available (the driver can run a global
---   action), exit_pending (an exit already owns the process), reload_pending (a
---   reload is in flight), writer_active (a global configuration writer or its
---   retained rollback is active), publication_pending (a hotstring publication
---   or recovery is pending).
--- @return table decision { admitted = boolean, abandon_reload = boolean|nil,
---   deferred = boolean|nil, cause = string|nil, message = string|nil }
function M.decide(facts)
	if type(facts) ~= "table" then error("quit admission needs its facts", 2) end
	for _, name in ipairs(M.FACTS) do
		if type(facts[name]) ~= "boolean" then
			error("quit admission fact '" .. name .. "' must be a boolean", 2)
		end
	end
	if not facts.owner_available then
		return { admitted = false, cause = M.CAUSE_OWNER_UNAVAILABLE, message = MESSAGES[M.CAUSE_OWNER_UNAVAILABLE] }
	end
	if facts.exit_pending then
		return { admitted = false, cause = M.CAUSE_EXIT_PENDING, message = MESSAGES[M.CAUSE_EXIT_PENDING] }
	end
	local deferral = facts.writer_active and M.CAUSE_WRITER_ACTIVE
		or facts.publication_pending and M.CAUSE_PUBLICATION_PENDING or nil
	if deferral then
		return { admitted = false, deferred = true, cause = deferral, message = MESSAGES[deferral] }
	end
	return { admitted = true, abandon_reload = facts.reload_pending }
end

--- Runs Quit once admitted, waiting out a deferral within a bound.
--- @param ports table
---   facts          function Reads the current facts table.
---   schedule       function (seconds, callback) -> boolean; false when it cannot arm.
---   now            function Monotonic seconds.
---   timeout        number   Seconds a deferral may last (the user-quit deadline).
---   poll           number   Seconds between two reads while deferred.
---   on_admitted    function (decision) Starts the exit.
---   on_refused     function (decision) Tells the user; `decision.timed_out` marks a deferral that expired.
---   warn           function (fmt, ...) Log port.
--- @return string state "admitted", "refused" or "waiting"
function M.await(ports)
	assert(type(ports) == "table", "quit admission needs its ports")
	for _, name in ipairs({ "facts", "schedule", "now", "on_admitted", "on_refused", "warn" }) do
		assert(type(ports[name]) == "function", "quit admission needs the " .. name .. " port")
	end
	assert(type(ports.timeout) == "number" and ports.timeout > 0, "quit admission needs a positive timeout")
	assert(type(ports.poll) == "number" and ports.poll > 0, "quit admission needs a positive poll")
	local started = ports.now()
	local first = true
	local function step()
		local decision = M.decide(ports.facts())
		if decision.admitted then
			ports.on_admitted(decision)
			return "admitted"
		end
		if not decision.deferred then
			ports.on_refused(decision)
			return "refused"
		end
		if first then
			first = false
			ports.warn("%s", decision.message)
		end
		if ports.now() - started >= ports.timeout then
			decision.timed_out = true
			ports.warn("Quit gave up waiting after %.1f s: %s", ports.timeout, decision.message)
			ports.on_refused(decision)
			return "refused"
		end
		if ports.schedule(ports.poll, step) ~= true then
			decision.timed_out = true
			ports.warn("Quit cannot wait: its poll timer was not armed.")
			ports.on_refused(decision)
			return "refused"
		end
		return "waiting"
	end
	return step()
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
	-- A deferral that expired was already logged by await with its bound.
	if decision.timed_out ~= true then ports.warn("%s", decision.message) end
	FeatureNotice.quit_refused(ports, translate)
end

return M
