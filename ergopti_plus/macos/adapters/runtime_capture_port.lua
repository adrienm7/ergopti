--- adapters/runtime_capture_port.lua

--- ==============================================================================
--- MODULE: Owned Runtime Capture Port (Hammerspoon)
--- DESCRIPTION:
--- The production capture owner behind platform/remap/runtime_owner.lua: it
--- prepares the managed physical history session over the installed-source task
--- port, starts it from the pinned capture declaration, reports its first
--- admitted stream and its loss, and stops it with exact settlement. The
--- session, the accounting mode, the privacy and pause history and the periodic
--- lease rotation are the existing physical_* modules; this adapter only drives
--- them. Required only when the user opts in to the owned runtime.
---
--- FEATURES & RATIONALE:
--- 1. Pinned Declaration Only: the executable is the bundle-bound launcher, the
---    role is the installed-source stream and the requirement and limits come from
---    the pinned artifact. No caller-supplied path or argument is accepted.
--- 2. One Session Per Lua VM: the managed session is single-use by design, so a
---    second start is refused and named, never replaced silently. Changing the
---    capture takes a reload.
--- 3. Normalized Status: the policy's many internal states collapse to the three
---    the runtime owner understands (starting, admitted, stopped), so the owner
---    never depends on the history policy's vocabulary.
--- 4. Loss Is Pushed: a refusal of the session after it started reaches the owner
---    once through the registered callback; nothing here retries.
--- 5. Final Release: once the session is retired the native owner is asked to
---    shut down, so the launcher image and publisher lease are released.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "adapters.runtime_capture_port"

--- The fields a pinned capture declaration must carry.
M.PIN_FIELDS = { "requirement", "batch_limit", "frame_limit", "history_capacity" }

local STARTING = { prepared = true, starting = true, waiting = true, suspended = true, suspending = true }

--- Validates a pinned capture declaration.
--- @param pin any Candidate declaration.
--- @return boolean valid
--- @return string|nil reason
local function validate_pin(pin)
	if type(pin) ~= "table" then return false, "the capture declaration is missing" end
	if type(pin.requirement) ~= "string" or pin.requirement == "" or pin.requirement:find("[%z\r\n]") then
		return false, "the pinned requirement is missing or malformed"
	end
	for _, name in ipairs({ "batch_limit", "frame_limit", "history_capacity" }) do
		local value = pin[name]
		if math.type(value) ~= "integer" or value < 1 then
			return false, "the pinned " .. name .. " is not a positive integer"
		end
	end
	return true
end

--- Creates the capture port.
--- @param dependencies table|nil Optional test seams: source (installed-source port with
---   available, launcher, spawn, shutdown, closed), history (prepare_managed_metrics).
--- @return table port { start, stop, status, on_lost, closed }.
function M.new(dependencies)
	dependencies = dependencies or {}
	local Source = require("adapters.installed_physical_source")
	local source = dependencies.source or Source.new()
	local history = dependencies.history or require("modules.keystats.physical_history_session")
	local manager, lost_observer, lost_reported, finalized = nil, nil, false, false
	local stop_target

	--- Tells the owner, once, that the session is gone.
	--- @param reason any Reason text.
	local function report_loss(reason)
		if lost_reported then return end
		lost_reported = true
		Logger.error(LOG, "The physical capture session was refused: %s.", tostring(reason))
		if lost_observer then
			local ok, failure = pcall(lost_observer, reason)
			if not ok then Logger.error(LOG, "The capture loss observer failed: %s.", tostring(failure)) end
		end
	end

	--- Releases the native owner once the session is retired.
	local function finalize()
		if finalized then return end
		finalized = true
		source.shutdown()
	end

	--- The one observer identity handed to the session for its stop.
	--- @param value any True once the session is retired.
	local function stop_notify(value)
		if value ~= true then return end
		finalize()
		if stop_target then stop_target(true) end
	end

	local port = {}

	--- Registers the one loss observer.
	--- @param observer function fn(reason).
	function port.on_lost(observer)
		assert(type(observer) == "function", "Invalid capture loss observer")
		lost_observer = observer
	end

	--- Prepares and starts the managed session from the pinned declaration.
	--- @param pin table { requirement, batch_limit, frame_limit, history_capacity }.
	--- @return boolean accepted
	function port.start(pin)
		local valid, why = validate_pin(pin)
		if not valid then
			Logger.error(LOG, "Physical capture not started: %s.", why)
			return false
		end
		if manager ~= nil then
			Logger.error(LOG, "Physical capture not started: a managed session is single-use in one Lua VM; reload to restart.")
			return false
		end
		local available, unavailable = source.available()
		if not available then
			Logger.error(LOG, "Physical capture not started: the installed source is unavailable (%s).", tostring(unavailable))
			return false
		end
		local launcher, launcher_reason = source.launcher()
		if not launcher then
			Logger.error(LOG, "Physical capture not started: no launcher (%s).", tostring(launcher_reason))
			return false
		end
		local prepared, reason = history.prepare_managed_metrics(pin.history_capacity, report_loss, source.spawn)
		if prepared == nil then
			Logger.error(LOG, "Physical capture not started: the managed session was refused (%s).", tostring(reason))
			return false
		end
		manager = prepared
		Logger.start(LOG, "Starting the physical capture session…")
		local started, failure = manager.start({
			executable = launcher,
			arguments = { Source.STREAM_ROLE },
			requirement = pin.requirement,
			batch_limit = pin.batch_limit,
			frame_limit = pin.frame_limit,
		})
		if started ~= true then
			Logger.error(LOG, "Physical capture session did not start (%s).", tostring(failure))
			return false
		end
		return true
	end

	--- Stops the session. `on_settled(true)` is delivered once it is retired.
	--- @param on_settled function|nil fn(true).
	--- @return boolean settled True only when the session is already retired.
	function port.stop(on_settled)
		assert(on_settled == nil or type(on_settled) == "function", "Invalid capture stop observer")
		if manager == nil then return true end
		-- The session keeps one observer identity for its whole stop, while the
		-- owner retries with a new closure each time; the target follows the latest.
		if on_settled then stop_target = on_settled end
		manager.stop(on_settled and stop_notify or nil)
		if manager.retired() == true then
			finalize()
			return true
		end
		return false
	end

	--- The normalized state of the session.
	--- @return table status { state = starting|admitted|stopped }.
	function port.status()
		if manager == nil then return { state = "stopped" } end
		local state = manager.status().state
		if state == "admitted" then return { state = "admitted" } end
		if STARTING[state] then return { state = "starting" } end
		return { state = "stopped" }
	end

	--- Whether the native owner released its image and publisher lease.
	--- @return boolean closed
	function port.closed() return source.closed() end

	return port
end

return M
