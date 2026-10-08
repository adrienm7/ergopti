--- modules/keylogger/physical_history_owner.lua

--- Owns one boot-selected, unavailable physical history manager without native activation.
local M = {}
local Logger = require("infra.logger")
local Session = require("modules.keylogger.physical_history_session")
local SessionInit = assert(rawget(Session, "init"))
local SessionStop = assert(rawget(Session, "stop"))
local SessionRetired = assert(rawget(Session, "retired"))
local MAX_HISTORY = require("keylogger.physical_history_coordinator").MAX_HISTORY
local LOG = "keylogger.physical_history_owner"
local UNAVAILABLE = "Verified installed physical runtime binding is unavailable."
local manager, ports
local attempted, busy, wanted, final = false, false, false, false
local revision, reason = 0, nil
local notice_attempted, notice_delivered = false, false

--- Checks that the retained public module still exposes its original lifecycle ports.
--- @return boolean current
local function current()
	return rawequal(rawget(package.loaded, "modules.keylogger.physical_history_session"), Session)
		and rawequal(rawget(Session, "init"), SessionInit)
		and rawequal(rawget(Session, "stop"), SessionStop)
		and rawequal(rawget(Session, "retired"), SessionRetired)
end

--- Makes one status-notice attempt before entering foreign localization or delivery.
local function notice()
	if notice_attempted then return end
	notice_attempted = true
	local called, delivered = pcall(function()
		local i18n = require("infra.i18n")
		return require("infra.notifications").notify(i18n.get("menu.metrics.physical_source"),
			i18n.get("menu.metrics.physical_source_unavailable"), "warning")
	end)
	notice_delivered = called and delivered == true
	if not notice_delivered then Logger.warn(LOG, "Physical source unavailable notice was not delivered.") end
end

--- Retains the first terminal refusal before any foreign logging callback.
--- @param failure string Original manager refusal.
local function refused(failure)
	final, wanted = true, false
	revision = revision + 1
	reason = reason or failure
	Logger.warn(LOG, "Physical source manager refused: %s.", tostring(reason))
end

--- Selects unavailable GAP before producer acquisition; no native start options exist here.
--- @return boolean prepared Only unavailable source custody was established.
function M.prepare()
	if busy or final or not current() then return false end
	wanted, busy = true, true
	revision = revision + 1
	local generation = revision
	local called, accepted = pcall(function()
		if not attempted then
			attempted = true
			local candidate, failure = SessionInit(MAX_HISTORY, refused, { managed = true })
			if type(candidate) ~= "table" then reason = failure; return false end
			manager = candidate
			ports = {}
			for _, name in ipairs({ "select_unavailable", "resume", "suspend", "quiescent", "status" }) do
				ports[name] = assert(rawget(candidate, name), "Missing physical history manager port")
				assert(type(ports[name]) == "function", "Invalid physical history manager port")
			end
		end
		if not ports or generation ~= revision or not wanted or final or not current() then return false end
		if ports.resume() ~= true then return false end
		if generation ~= revision or not wanted or final or not current() then return false end
		if ports.select_unavailable(UNAVAILABLE) ~= true then return false end
		if generation ~= revision or not wanted or final or not current() then return false end
		notice()
		return generation == revision and wanted and not final and current()
	end)
	busy = false
	if not called then reason = reason or "physical_history_owner_preparation_failed" end
	return called and accepted == true
end

--- Observes the original Session only after its current callback has unwound.
--- @return boolean retired Actual final retirement, never a request acknowledgement.
function M.retired()
	if busy or not current() then return false end
	local called, retired = pcall(SessionRetired)
	return called and retired == true and current()
end

--- Fences dependent cleanup while retaining the same selected owner across ordinary OFF.
--- @param process_exit boolean True for terminal shutdown, false for ordinary OFF.
--- @return boolean settled Actual retirement or nonterminal quiescence was observed.
function M.stop(process_exit)
	assert(type(process_exit) == "boolean", "Invalid physical owner stop intent")
	wanted = false
	revision = revision + 1
	if process_exit then final = true end
	if not current() then return false end
	-- Root termination can retire this same Session before dependent feature cleanup.
	local observed, retired = pcall(SessionRetired)
	if not observed then return false end
	if retired == true then return not busy and current() end
	if process_exit then
		local called, accepted = pcall(SessionStop)
		if not called or accepted ~= true then return false end
		return M.retired()
	end
	if not ports then return not busy and not attempted end
	local called, accepted = pcall(ports.suspend)
	if not called or accepted ~= true or busy then return false end
	local checked, quiescent = pcall(ports.quiescent)
	return checked and quiescent == true and current()
end

--- Returns a detached observation, without turning unavailability into native readiness.
--- @return table status State and once-only notice observations.
function M.status()
	local state = attempted and "refused" or "unselected"
	if manager and current() then
		local called, actual = pcall(ports.status)
		if called and type(actual) == "table" then state = actual.state end
	end
	return { state = state, reason = reason or UNAVAILABLE,
		notice_attempted = notice_attempted, notice_delivered = notice_delivered }
end

return M
