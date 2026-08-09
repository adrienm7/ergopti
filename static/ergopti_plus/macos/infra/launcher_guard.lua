--- infra/launcher_guard.lua

--- ==============================================================================
--- MODULE: Swift Launcher Liveness Guard
--- DESCRIPTION:
--- Keeps the embedded Hammerspoon process coupled to the exact ErgoptiPlus
--- launcher process that spawned it, including when Activity Monitor delivers
--- SIGKILL and Cocoa therefore cannot run applicationWillTerminate.
---
--- FEATURES & RATIONALE:
--- 1. Exact parent identity: a launcher-exported PID is the primary identity;
---    a live PID lookup must also expose the expected bundle identifier, while
---    its exact termination event remains authoritative after metadata vanishes.
--- 2. Race-free native observation: the application watcher is strongly held
---    and started before an immediate PID lookup closes the boot-time gap.
--- 3. Event-loss backstop: a low-frequency retained-instance probe catches a
---    missed termination event without PID re-trust, shell polling, or eventtap work.
--- 4. One-shot emergency path: all loss signals share one latch, and a throw
---    from injected teardown is caught and persisted through the central logger.
--- 5. Standalone development: a directly launched Hammerspoon without launcher
---    environment variables remains supported and does not invent a parent.
--- ==============================================================================

local M = {}

local hs = hs
local Logger = require("infra.logger")

local LOG = "infra.launcher_guard"





-- =====================================
-- =====================================
-- ======= 1/ Constants ================
-- =====================================
-- =====================================

local LAUNCHER_PID_ENV = "ERGOPTI_LAUNCHER_PID"
local LAUNCHER_BUNDLE_ID_ENV = "ERGOPTI_LAUNCHER_BUNDLE_ID"

-- The application watcher is the immediate path; this timer only repairs an
-- event that macOS failed to deliver and therefore does not need a hot cadence
local BACKSTOP_INTERVAL_SEC = 2

-- macOS pid_t is a signed 32-bit integer
local MAX_PROCESS_ID = 2147483647





-- =====================================
-- =====================================
-- ======= 2/ Module State =============
-- =====================================
-- =====================================

local _initialized = false
local _managed_launch = false
local _emergency_requested = false
local _launcher_pid = nil
local _launcher_bundle_id = nil
local _launcher_app = nil
local _emergency_quit = nil
local _app_watcher = nil
local _backstop_timer = nil





-- =====================================
-- =====================================
-- ======= 3/ Resource Lifecycle =======
-- =====================================
-- =====================================

--- Stops one native watcher or timer without allowing teardown failure to
--- abort the emergency path.
--- @param resource table|userdata|nil Native object exposing stop().
--- @param label string Developer-facing resource label.
--- @return boolean stopped Whether native release completed.
local function stop_resource(resource, label)
	if not resource then return true end
	local ok, result_or_err = xpcall(function() return resource:stop() end, debug.traceback)
	if not ok or result_or_err == false then
		Logger.error(LOG, "Failed to stop launcher %s; retaining it for retry: %s",
			label, tostring(result_or_err))
		return false
	end
	return true
end

--- Releases every native liveness handle held strongly by this module.
--- Failed native stops remain retained so a later teardown pass can retry the
--- same object; logical callbacks are fenced separately by lifecycle state.
--- @return boolean complete Whether both native resources were released.
local function release_resources()
	local watcher = _app_watcher
	local timer = _backstop_timer
	local watcher_stopped = stop_resource(watcher, "application watcher")
	local timer_stopped = stop_resource(timer, "process-instance backstop")
	if watcher_stopped and _app_watcher == watcher then _app_watcher = nil end
	if timer_stopped and _backstop_timer == timer then _backstop_timer = nil end
	return watcher_stopped and timer_stopped
end

--- Requests injected emergency teardown at most once for the whole Lua state.
--- @param reason string Stable machine-readable loss reason.
local function request_emergency_quit(reason)
	if _emergency_requested then return end
	_emergency_requested = true
	_managed_launch = false
	_launcher_app = nil
	release_resources()

	Logger.error(LOG, "Swift launcher liveness lost (%s) — requesting emergency quit.", reason)
	local ok, err = xpcall(function()
		_emergency_quit(reason)
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Emergency quit callback raised: %s", tostring(err))
	end
end





-- =====================================
-- =====================================
-- ======= 4/ Identity Verification ====
-- =====================================
-- =====================================

--- Parses a canonical positive pid_t environment value.
--- @param raw string|nil Raw environment value.
--- @return integer|nil pid Validated process identifier.
local function parse_process_id(raw)
	if type(raw) ~= "string" or not raw:match("^[1-9]%d*$") then return nil end
	local pid = tonumber(raw)
	if not pid or pid > MAX_PROCESS_ID or pid % 1 ~= 0 then return nil end
	return pid
end

--- Reads an application PID through the native object without letting an API
--- exception escape an asynchronous watcher callback.
--- @param app table|userdata|nil Native application object.
--- @return integer|nil pid Observable process identifier.
local function read_application_pid(app)
	if not app then return nil end
	local ok, pid_or_err = xpcall(function() return app:pid() end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Failed to read terminated application PID: %s", tostring(pid_or_err))
		return nil
	end
	return type(pid_or_err) == "number" and pid_or_err or nil
end

--- Strictly verifies the expected bundle identifier for one live PID lookup.
--- A terminated-event object may legitimately lose this metadata and therefore
--- does not use this live-process verifier.
--- @param app table|userdata Native application object for the exact live PID.
--- @return boolean matches Whether the observable identity is trustworthy.
--- @return string|nil failure Stable reason when identity cannot be trusted.
local function bundle_identity_matches(app)
	local ok, bundle_or_err = xpcall(function() return app:bundleID() end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Failed to read live launcher bundle ID: %s", tostring(bundle_or_err))
		return false, "launcher_identity_unverifiable"
	end

	if type(bundle_or_err) ~= "string" or bundle_or_err == "" then
		Logger.error(LOG, "Live launcher bundle ID is not observable — refusing PID-only trust.")
		return false, "launcher_identity_unverifiable"
	end

	if bundle_or_err ~= _launcher_bundle_id then
		return false, "launcher_identity_mismatch"
	end
	return true, nil
end

--- Resolves and verifies the exact launcher through Hammerspoon's native
--- process lookup.
--- @return table|userdata|nil app Verified application object.
--- @return string|nil failure Stable failure reason when verification fails.
local function resolve_launcher()
	if not hs or not hs.application
		or type(hs.application.applicationForPID) ~= "function" then
		Logger.error(LOG, "Native applicationForPID lookup is unavailable.")
		return nil, "launcher_probe_unavailable"
	end

	local ok, app_or_err = xpcall(function()
		return hs.application.applicationForPID(_launcher_pid)
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Native launcher PID lookup raised: %s", tostring(app_or_err))
		return nil, "launcher_probe_failed"
	end
	if not app_or_err then return nil, "launcher_missing" end
	local bundle_matches, bundle_failure = bundle_identity_matches(app_or_err)
	if not bundle_matches then
		if bundle_failure == "launcher_identity_mismatch" then
			Logger.error(LOG,
				"PID %d no longer belongs to launcher bundle %s.",
				_launcher_pid, tostring(_launcher_bundle_id))
		end
		return nil, bundle_failure
	end
	return app_or_err, nil
end

--- Checks the exact parent instance retained at initialization. Hammerspoon
--- application objects remain tied to one process instance even after a later
--- application reuses its PID, so the recurring check must never re-resolve and
--- trust a fresh same-bundle process.
--- @return boolean alive Whether the exact launcher is still live.
local function check_launcher()
	if not _managed_launch or _emergency_requested then return false end
	if not _launcher_app then
		local app, failure = resolve_launcher()
		if not app then
			request_emergency_quit(failure)
			return false
		end
		_launcher_app = app
	end

	local ok, running_or_err = xpcall(function()
		return _launcher_app:isRunning()
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Failed to probe exact launcher instance: %s", tostring(running_or_err))
		request_emergency_quit("launcher_probe_failed")
		return false
	end
	if running_or_err ~= true then
		request_emergency_quit("launcher_missing")
		return false
	end
	return true
end





-- =====================================
-- =====================================
-- ======= 5/ Async Boundaries =========
-- =====================================
-- =====================================

--- Handles native application events after matching the exact launcher PID.
--- @param _ string Application name, deliberately not used as identity.
--- @param event_type any Native watcher event constant.
--- @param app table|userdata|nil Native application object.
local function handle_application_event(_, event_type, app)
	if not _managed_launch or _emergency_requested then return end
	if event_type ~= hs.application.watcher.terminated then return end

	local pid = read_application_pid(app)
	if pid == nil then
		-- The official watcher contract permits a nil application object. Probe
		-- the retained exact instance immediately so launcher SIGKILL does not wait
		-- for the periodic backstop; unrelated terminations leave it running.
		check_launcher()
		return
	end
	if pid ~= _launcher_pid then return end
	-- macOS may discard bundle metadata before publishing `terminated`; the
	-- matching event PID itself is the exact process whose liveness was lost
	request_emergency_quit("launcher_terminated")
end

--- Guards the native application callback because Hammerspoon otherwise sends
--- callback exceptions only to its Console, bypassing the file logger.
--- @param ... any Native application watcher callback arguments.
local function guarded_application_event(...)
	local ok, err = xpcall(handle_application_event, debug.traceback, ...)
	if not ok then
		Logger.error(LOG, "Uncaught launcher application-watcher callback error: %s", tostring(err))
	end
end

--- Guards the recurring backstop for the same async error-visibility reason.
local function guarded_backstop_check()
	local ok, err = xpcall(check_launcher, debug.traceback)
	if not ok then
		Logger.error(LOG, "Uncaught launcher PID-backstop callback error: %s", tostring(err))
	end
end

--- Creates and starts the strongly retained native application watcher.
--- @return boolean started Whether the watcher is active.
local function arm_application_watcher()
	if not hs or not hs.application or not hs.application.watcher
		or type(hs.application.watcher.new) ~= "function" then
		Logger.error(LOG, "Native application watcher is unavailable.")
		return false
	end

	local ok, err = xpcall(function()
		local watcher = hs.application.watcher.new(guarded_application_event)
		if not watcher then error("watcher constructor returned nil") end
		_app_watcher = watcher
		if not watcher:start() then error("watcher start returned a false value") end
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Failed to arm launcher application watcher: %s", tostring(err))
		release_resources()
		return false
	end
	return true
end

--- Creates the strongly retained low-frequency exact-instance backstop. The native
--- terminated callback may legally receive a nil application object, so the
--- retained liveness probe is part of the safety mechanism, not optional telemetry.
--- @return boolean armed Whether the backstop is retained.
local function arm_backstop_timer()
	if not hs or not hs.timer or type(hs.timer.doEvery) ~= "function" then
		Logger.error(LOG, "Launcher process-instance backstop is unavailable.")
		return false
	end

	local ok, timer_or_err = xpcall(function()
		return hs.timer.doEvery(BACKSTOP_INTERVAL_SEC, guarded_backstop_check)
	end, debug.traceback)
	if not ok or not timer_or_err then
		Logger.error(LOG, "Failed to arm launcher process-instance backstop: %s",
			tostring(timer_or_err or "timer constructor returned nil"))
		return false
	end
	_backstop_timer = timer_or_err
	return true
end





-- =====================================
-- =====================================
-- ======= 6/ Public Lifecycle =========
-- =====================================
-- =====================================

--- Initializes and arms the launcher guard when the Swift launcher exported an
--- exact PID; direct developer Hammerspoon remains intentionally unguarded.
--- @param emergency_quit function Callback invoked once with a reason string.
--- @return boolean started Whether standalone mode is valid or the guard armed.
function M.init(emergency_quit)
	if _initialized then
		Logger.warn(LOG, "init() called more than once — ignoring duplicate call.")
		return false
	end
	Logger.start(LOG, "Initializing Swift launcher liveness guard…")
	if type(emergency_quit) ~= "function" then
		Logger.error(LOG, "init(): emergency_quit must be a function — guard not armed.")
		return false
	end

	_initialized = true
	_emergency_quit = emergency_quit
	local raw_pid = os.getenv(LAUNCHER_PID_ENV)
	if raw_pid == nil or raw_pid == "" then
		Logger.success(LOG, "Swift launcher liveness guard disabled for standalone Hammerspoon.")
		return true
	end

	_launcher_pid = parse_process_id(raw_pid)
	if not _launcher_pid then
		_managed_launch = true
		Logger.error(LOG, "Invalid %s value %q — failing closed.",
			LAUNCHER_PID_ENV, tostring(raw_pid))
		request_emergency_quit("launcher_pid_invalid")
		return false
	end

	local raw_bundle_id = os.getenv(LAUNCHER_BUNDLE_ID_ENV)
	if type(raw_bundle_id) ~= "string" or raw_bundle_id == "" then
		_managed_launch = true
		Logger.error(LOG, "Missing %s value for managed launch — failing closed.",
			LAUNCHER_BUNDLE_ID_ENV)
		request_emergency_quit("launcher_bundle_id_invalid")
		return false
	end
	_launcher_bundle_id = raw_bundle_id
	_managed_launch = true

	if not arm_application_watcher() then
		request_emergency_quit("launcher_watcher_unavailable")
		return false
	end

	-- Starting the watcher before this lookup closes both sides of the boot race
	if not check_launcher() then return false end
	if not arm_backstop_timer() then
		request_emergency_quit("launcher_backstop_unavailable")
		return false
	end

	Logger.success(LOG, "Swift launcher liveness guard armed for PID %d.", _launcher_pid)
	return true
end

--- Detaches native liveness resources before an ordinary Hammerspoon shutdown.
--- Without this explicit transition, the launcher's normal termination event
--- can race Hammerspoon's own shutdown callback and invoke teardown twice.
--- Idempotent so emergency teardown may call it after the guard already released
--- its resources.
function M.stop()
	_managed_launch = false
	_launcher_app = nil
	return release_resources()
end

return M
