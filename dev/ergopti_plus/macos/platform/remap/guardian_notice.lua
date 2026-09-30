--- platform/remap/guardian_notice.lua

--- ==============================================================================
--- MODULE: Remap Guardian Approval Notice
--- DESCRIPTION:
--- Tells the user, once per episode, when the remap engine's background helper
--- is not running: held by macOS until approved in Login Items, or not
--- registered at all. A click opens those settings.
---
--- FEATURES & RATIONALE:
--- 1. Proactive: this used to be a status row inside the tray's Karabiner
---    submenu, reachable only by someone who opened that submenu and read it.
---    The engine is an implementation detail now and has no row, so the one
---    fact that needs the user must come to them.
--- 2. Once per episode: every guardian probe re-reports its status while it
---    lasts; one notice per transition into a blocking state, not per poll.
--- 3. Never silent: `unavailable` (the launcher could not register the helper,
---    e.g. after an app update left a stale Background Items entry) keeps the
---    rules just as inert as `requires_approval`. It used to reach the user
---    as nothing at all, so it gets its own notice and an ERROR log line.
---    Its click opens Login Items directly: the approval opener refuses any
---    state other than `requires_approval` by design.
--- 4. Owned: an instance is created by the remap bridge that probes the status,
---    so its state lives and dies with that bridge's lifecycle.
--- 5. Steps before a banner: `requires_approval` is first offered to the
---    presenter the boot registered, which opens the numbered Login Items steps
---    in the permission dialog. The banner goes out only when it declines
---    (already offered in this launch, or unavailable), so one episode never
---    announces itself twice.
--- ==============================================================================

local M = {}

local REQUIRES_APPROVAL = "requires_approval"
local UNAVAILABLE = "unavailable"

--- Creates the notice owned by one remap bridge lifecycle.
--- @param deps table { notify = fn(msg, body, kind, on_click), text = fn(key) -> string,
---        open_settings = fn(on_done) -> boolean (approval opener),
---        open_login_items = fn(on_done) -> boolean (unconditional opener),
---        present_approval = fn() -> boolean (true when the Login Items steps
---        took the announcement), logger = table, log = string }.
--- @return table notice Object with observe(status).
function M.new(deps)
	if type(deps) ~= "table" or type(deps.notify) ~= "function"
		or type(deps.text) ~= "function" or type(deps.open_settings) ~= "function"
		or type(deps.open_login_items) ~= "function" or type(deps.present_approval) ~= "function"
		or type(deps.logger) ~= "table" or type(deps.log) ~= "string" then
		error("guardian_notice.new(): notify, text, open_settings, open_login_items, present_approval,"
			.. " logger and log are required", 2)
	end
	-- Blocking status whose notice was delivered in the current episode.
	local announced = nil
	-- Blocking status whose ERROR line was written in the current episode.
	local logged = nil
	local notice = {}

	--- Returns a click handler that opens Login Items and says so when it cannot.
	--- @param opener function fn(on_done) -> boolean.
	--- @return function on_click
	local function click_opener(opener)
		return function()
			local accepted = opener(function(ok, reason)
				if ok ~= true then
					deps.logger.error(deps.log, "Could not open Login Items settings: %s.", tostring(reason))
					deps.notify(deps.text("karabiner.guardian_settings_open_failed"), nil, "error")
				end
			end)
			return accepted == true
		end
	end

	-- Notice per blocking status: message key, kind and click opener.
	local NOTICES = {
		[REQUIRES_APPROVAL] = { key = "karabiner.guardian_approval_required", kind = "warning",
			on_click = click_opener(deps.open_settings) },
		[UNAVAILABLE] = { key = "karabiner.guardian_unavailable", kind = "error",
			on_click = click_opener(deps.open_login_items) },
	}

	--- Records one exact guardian observation, notifying on entry into a blocking state.
	--- @param status string|nil Canonical guardian status, nil when unknown.
	--- @return boolean notified True only when this call raised the notice.
	function notice.observe(status)
		-- Unknown is not "ready": a failed probe keeps the episode open.
		if status == nil then return false end
		local spec = NOTICES[status]
		if spec == nil then
			announced, logged = nil, nil
			return false
		end
		if announced == status then return false end
		if status == UNAVAILABLE and logged ~= status then
			deps.logger.error(deps.log,
				"Remap guardian status is '%s': the background helper is not registered, so tap-holds and remaps stay inert.",
				status)
		end
		logged = status
		if status == REQUIRES_APPROVAL and deps.present_approval() == true then
			announced = status
			deps.logger.warn(deps.log, "Remap engine awaits Login Items approval — steps shown to the user.")
			return true
		end
		local sent, err = deps.notify(deps.text(spec.key), nil, spec.kind, spec.on_click)
		if sent ~= true then
			deps.logger.error(deps.log, "Guardian '%s' notice was not delivered: %s.", status, tostring(err))
			return false
		end
		announced = status
		if status == REQUIRES_APPROVAL then
			deps.logger.warn(deps.log, "Remap engine awaits Login Items approval — user notified.")
		else
			-- The ERROR above already carries the status; this only records delivery.
			deps.logger.info(deps.log, "Remap guardian unavailable — user notified.")
		end
		return true
	end

	return notice
end

return M
