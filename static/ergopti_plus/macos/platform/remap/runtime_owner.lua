--- platform/remap/runtime_owner.lua

--- ==============================================================================
--- MODULE: Owned Karabiner Runtime Owner
--- DESCRIPTION:
--- The one Lua owner of the Ergopti background Karabiner runtime (ADR 011,
--- HS-274): it decides whether the runtime may run on this Mac, starts its
--- user-side process after the owned configuration exists, restarts it only on
--- explicit request, and stops it together with the physical capture. Dormant:
--- nothing requires this module at default boot, and every effect goes through a
--- port, so the whole state machine is testable with fakes.
---
--- FEATURES & RATIONALE:
--- 1. Explicit Ownership: `init` binds the ports once and refuses a second
---    binding; invalid ports raise. `release` is the only way back to
---    uninitialized, and only once nothing is retained.
--- 2. Named Unavailability, Never a Fallback: a missing install, an
---    incompatible VirtualHIDDevice, another running Karabiner or an unpinned
---    artifact each produce `unavailable` with a stable reason and a sentence
---    explaining it. The owner never selects the shared runtime on its own.
--- 3. Read-Only Admission: the privileged jobs (VirtualHIDDevice daemon, Core
---    service) belong to the installer, so admission only observes them. The
---    one process this module spawns is the user-side Console, with the owned
---    XDG_CONFIG_HOME and an owner PID that makes it exit with Hammerspoon.
--- 4. Capture Before Peer: stopping revokes the physical capture first, so no
---    credit is recorded while the keyboard returns to native input.
--- 5. No Retry Loop: a lost peer is reported once as `failed`; restarting is a
---    caller decision. A stop settles only on observed exits and may be called
---    again to retry the same retained handles.
--- ==============================================================================

local Logger = require("infra.logger")
local KePaths = require("platform.remap.ke_paths")
local Vhid = require("platform.remap.runtime_vhid")

local M = {}

local LOG = "remap.runtime_owner"

--- Lifecycle states. `admitted` means every precondition holds and the
--- configuration may be deployed; `ready` means the user-side process runs.
M.STATE = {
	UNINITIALIZED = "uninitialized",
	IDLE = "idle",
	STARTING = "starting",
	ADMITTED = "admitted",
	PEERS_STARTING = "peers_starting",
	READY = "ready",
	UNAVAILABLE = "unavailable",
	FAILED = "failed",
	STOPPING = "stopping",
	STOPPED = "stopped",
}
local STATE = M.STATE

--- ADR 011 decision 3: quitting another active Karabiner is on by default.
M.CLOSE_OTHER_INSTANCES_DEFAULT = true

--- Stable reasons of the `unavailable` and `failed` states.
M.REASON = {
	ARTIFACT_UNPINNED = "artifact_unpinned",
	CAPTURE_UNPINNED = "capture_unpinned",
	CAPTURE_UNBOUND = "capture_unbound",
	NOT_INSTALLED = "runtime_not_installed",
	JOB_NOT_LOADED = "runtime_job_not_loaded",
	LAUNCHD_UNREADABLE = "launchd_unreadable",
	LISTING_FAILED = "system_extension_listing_failed",
	OTHER_RUNNING = "other_karabiner_running",
	CLOSE_UNSUPPORTED = "close_other_unsupported",
	CLOSE_FAILED = "close_other_failed",
	OTHER_STILL_RUNNING = "other_karabiner_still_running",
	PROBE_FAILED = "coexistence_probe_failed",
	CONFIG_MISSING = "owned_configuration_missing",
	PEER_SPAWN_FAILED = "peer_spawn_failed",
	PEER_EXITED = "peer_exited",
	CAPTURE_REFUSED = "capture_start_refused",
}
local REASON = M.REASON

local PORT_FUNCTIONS = {
	fs = { "exists", "expand" },
	launchd = { "loaded" },
	system_extensions = { "listing" },
	coexistence = { "detect" },
	process = { "spawn", "owner_pid" },
	artifact = { "pinned" },
}

local ports
local state = STATE.UNINITIALIZED
local state_reason, state_explanation
local run
local peer
local capture_started, capture_settled = false, true
local current_options
local stop_observer
local ready_waiters = {}





-- ==================================
-- ==================================
-- ======= 1/ State And Ports =======
-- ==================================
-- ==================================

--- Moves to a state and tells the optional observer, whose failure is logged.
--- @param next_state string One of M.STATE.
--- @param why string|nil Stable reason.
--- @param detail string|nil Explanation sentence.
local function set_state(next_state, why, detail)
	state, state_reason, state_explanation = next_state, why, detail
	Logger.debug(LOG, "Owned runtime state: %s%s.", next_state, why and (" (" .. why .. ")") or "")
	if ports and ports.observer then
		local ok, failure = pcall(ports.observer, next_state, why)
		if not ok then Logger.error(LOG, "Owned runtime state observer failed: %s.", tostring(failure)) end
	end
end

--- Checks that every required port function exists.
--- @param candidate table Ports table.
local function validate_ports(candidate)
	assert(type(candidate) == "table", "Missing owned runtime ports")
	for group, names in pairs(PORT_FUNCTIONS) do
		assert(type(candidate[group]) == "table", "Missing owned runtime port group: " .. group)
		for _, name in ipairs(names) do
			assert(type(candidate[group][name]) == "function", "Missing owned runtime port: " .. group .. "." .. name)
		end
	end
	assert(candidate.coexistence.close == nil or type(candidate.coexistence.close) == "function",
		"Invalid owned runtime port: coexistence.close")
	if candidate.capture ~= nil then
		assert(type(candidate.capture) == "table" and type(candidate.capture.start) == "function"
			and type(candidate.capture.stop) == "function", "Invalid owned runtime capture port")
	end
	assert(candidate.observer == nil or type(candidate.observer) == "function", "Invalid owned runtime observer")
end

--- Binds the ports once, without touching the system.
--- A second binding is refused so that two owners can never run one runtime.
--- Port contracts, all asynchronous results delivered once:
---   fs.exists(path) -> boolean; fs.expand(path) -> absolute path;
---   launchd.loaded(label, fn(loaded|nil)) reads, never changes, a job;
---   system_extensions.listing(fn(text|nil)) is the `systemextensionsctl list` output;
---   coexistence.detect(fn(count|nil)) counts other active Karabiner processes and
---     coexistence.close(fn(ok)) (optional) asks them to quit;
---   process.spawn(executable, arguments, environment, fn(exit_code)) -> handle with
---     start() -> boolean, terminate() and isSettled() -> boolean; process.owner_pid() -> integer;
---   artifact.pinned() -> table { virtual_hid_version, capture = start options|nil } or nil, reason;
---   capture.start(options) -> boolean, capture.stop(fn) -> settled boolean (the
---     modules.keystats.physical_capture contract), capture.status() -> table.
--- @param candidate table fs, launchd, system_extensions, coexistence, process, artifact; optional capture, observer.
--- @return boolean initialized False when already initialized.
function M.init(candidate)
	if ports then
		Logger.warn(LOG, "Owned runtime owner is already initialized; second initialization refused.")
		return false
	end
	validate_ports(candidate)
	Logger.start(LOG, "Initializing the owned runtime owner…")
	ports = candidate
	set_state(STATE.IDLE)
	Logger.success(LOG, "Owned runtime owner initialized; nothing is started.")
	return true
end

--- Returns the ports back to unbound once nothing is retained.
--- @return boolean released False while a start, a peer or a capture is retained.
function M.release()
	if not ports then return true end
	local retained = state == STATE.STARTING or state == STATE.ADMITTED or state == STATE.PEERS_STARTING
		or state == STATE.READY or state == STATE.STOPPING or peer ~= nil or not capture_settled
	if retained then
		Logger.warn(LOG, "Owned runtime owner release refused while state is %s.", state)
		return false
	end
	ports, run, current_options, stop_observer = nil, nil, nil, nil
	ready_waiters = {}
	state, state_reason, state_explanation = STATE.UNINITIALIZED, nil, nil
	Logger.info(LOG, "Owned runtime owner released.")
	return true
end

--- Reports the lifecycle without exposing live handles.
--- @return table status { state, reason, explanation, peer, capture }.
function M.status()
	local capture
	if ports and ports.capture and type(ports.capture.status) == "function" then
		local ok, value = pcall(ports.capture.status)
		capture = ok and value or { state = "unreadable" }
	end
	local peer_state = "none"
	if peer then peer_state = peer.exited and "exited" or "running" end
	return { state = state, reason = state_reason, explanation = state_explanation, peer = peer_state,
		capture = capture }
end

--- True while the generated configuration may be deployed to the owned path.
--- @return boolean admitted
function M.admitted()
	return state == STATE.ADMITTED or state == STATE.PEERS_STARTING or state == STATE.READY
end





-- ============================
-- ============================
-- ======= 2/ Admission =======
-- ============================
-- ============================

--- Settles one start attempt exactly once.
--- @param attempt table The attempt being settled.
--- @param next_state string ADMITTED, UNAVAILABLE or FAILED.
--- @param why string|nil Stable reason.
--- @param detail string|nil Explanation sentence.
local function settle_start(attempt, next_state, why, detail)
	if run ~= attempt or attempt.done then return end
	attempt.done = true
	run = nil
	set_state(next_state, why, detail)
	if next_state == STATE.ADMITTED then
		Logger.success(LOG, "Owned runtime admitted: every precondition holds.")
	elseif next_state == STATE.UNAVAILABLE then
		Logger.warn(LOG, "Owned runtime unavailable (%s): %s", tostring(why), tostring(detail))
	else
		Logger.error(LOG, "Owned runtime start failed (%s): %s", tostring(why), tostring(detail))
	end
	if attempt.on_settled then
		local ok, failure = pcall(attempt.on_settled, next_state == STATE.ADMITTED, why, detail)
		if not ok then Logger.error(LOG, "Owned runtime start callback failed: %s.", tostring(failure)) end
	end
end

--- Lists the files an installed runtime must have.
--- @return table paths Absolute paths.
local function installed_paths()
	local owned = KePaths.OWNED
	return { owned.CLI, owned.CORE_SERVICE, owned.CONSOLE, owned.CORE_JOB_FILE }
end

--- Checks coexistence with another active Karabiner, closing it only when the
--- option allows and a closer is bound.
--- @param attempt table Current attempt.
local function check_coexistence(attempt)
	ports.coexistence.detect(function(count)
		if run ~= attempt then return end
		if type(count) ~= "number" then
			return settle_start(attempt, STATE.FAILED, REASON.PROBE_FAILED,
				"Another running Karabiner could not be detected.")
		end
		if count == 0 then return settle_start(attempt, STATE.ADMITTED) end
		if not attempt.options.close_other_instances then
			return settle_start(attempt, STATE.UNAVAILABLE, REASON.OTHER_RUNNING,
				"Another Karabiner is running and the option to close other Karabiner instances is off, "
					.. "so the owned runtime will not fight it for the keyboards.")
		end
		if not ports.coexistence.close then
			return settle_start(attempt, STATE.UNAVAILABLE, REASON.CLOSE_UNSUPPORTED,
				"Another Karabiner is running and this build cannot close it.")
		end
		Logger.info(LOG, "Closing %d other Karabiner process(es) as the option asks.", count)
		ports.coexistence.close(function(closed)
			if run ~= attempt then return end
			if closed ~= true then
				return settle_start(attempt, STATE.FAILED, REASON.CLOSE_FAILED,
					"Another Karabiner could not be asked to quit.")
			end
			ports.coexistence.detect(function(remaining)
				if run ~= attempt then return end
				if remaining == 0 then return settle_start(attempt, STATE.ADMITTED) end
				settle_start(attempt, STATE.UNAVAILABLE, REASON.OTHER_STILL_RUNNING,
					"Another Karabiner is still running after it was asked to quit.")
			end)
		end)
	end)
end

--- Checks that both privileged jobs are loaded, in order.
--- @param attempt table Current attempt.
local function check_jobs(attempt)
	local labels = { KePaths.OWNED.VIRTUAL_HID_LABEL, KePaths.OWNED.CORE_LABEL }
	local function check(index)
		if index > #labels then return check_coexistence(attempt) end
		ports.launchd.loaded(labels[index], function(loaded)
			if run ~= attempt then return end
			if loaded == nil then
				return settle_start(attempt, STATE.FAILED, REASON.LAUNCHD_UNREADABLE,
					"launchd could not be queried for " .. labels[index] .. ".")
			end
			if loaded ~= true then
				return settle_start(attempt, STATE.UNAVAILABLE, REASON.JOB_NOT_LOADED,
					"The launchd job " .. labels[index] .. " is not loaded; reinstall the owned runtime.")
			end
			check(index + 1)
		end)
	end
	check(1)
end

--- Starts admission: observes the machine and reaches `admitted` or names why not.
--- Nothing is started, written or closed unless the close option asks for it.
--- @param options table { close_other_instances = boolean, capture = boolean }.
--- @param on_settled function|nil fn(admitted, reason, explanation) called once.
--- @return boolean accepted False in a state that cannot start.
function M.start(options, on_settled)
	assert(ports, "Owned runtime owner is not initialized")
	assert(type(options) == "table" and type(options.close_other_instances) == "boolean"
		and type(options.capture) == "boolean", "Invalid owned runtime start options")
	assert(on_settled == nil or type(on_settled) == "function", "Invalid owned runtime start callback")
	local startable = state == STATE.IDLE or state == STATE.UNAVAILABLE or state == STATE.FAILED
		or state == STATE.STOPPED
	if not startable or peer ~= nil or not capture_settled then
		Logger.warn(LOG, "Owned runtime start refused in state %s; stop it first if a process is retained.", state)
		return false
	end
	local attempt = { options = { close_other_instances = options.close_other_instances,
		capture = options.capture }, on_settled = on_settled, done = false }
	run = attempt
	current_options = attempt.options
	set_state(STATE.STARTING)
	Logger.start(LOG, "Admitting the owned runtime…")
	local pinned, pinned_reason = ports.artifact.pinned()
	if type(pinned) ~= "table" or type(pinned.virtual_hid_version) ~= "string" or pinned.virtual_hid_version == "" then
		settle_start(attempt, STATE.UNAVAILABLE, REASON.ARTIFACT_UNPINNED,
			"No pinned runtime artifact is available: " .. tostring(pinned_reason or "invalid manifest") .. ".")
		return true
	end
	if attempt.options.capture and not ports.capture then
		settle_start(attempt, STATE.UNAVAILABLE, REASON.CAPTURE_UNBOUND,
			"This build binds no physical capture owner.")
		return true
	end
	if attempt.options.capture and type(pinned.capture) ~= "table" then
		settle_start(attempt, STATE.UNAVAILABLE, REASON.CAPTURE_UNPINNED,
			"The pinned artifact declares no physical capture executable.")
		return true
	end
	attempt.pinned = pinned
	for _, path in ipairs(installed_paths()) do
		if ports.fs.exists(path) ~= true then
			settle_start(attempt, STATE.UNAVAILABLE, REASON.NOT_INSTALLED,
				"The owned runtime is not installed: " .. path .. " is missing.")
			return true
		end
	end
	ports.system_extensions.listing(function(output)
		if run ~= attempt then return end
		if type(output) ~= "string" then
			return settle_start(attempt, STATE.FAILED, REASON.LISTING_FAILED,
				"The system extension listing could not be read.")
		end
		local verdict = Vhid.assess(Vhid.parse(output), pinned.virtual_hid_version)
		if not verdict.ok then
			return settle_start(attempt, STATE.UNAVAILABLE, verdict.reason, verdict.explanation)
		end
		check_jobs(attempt)
	end)
	return true
end





-- ===================================
-- ===================================
-- ======= 3/ Peer And Capture =======
-- ===================================
-- ===================================

--- Calls every waiter of ensure_peers once.
--- @param ok boolean Whether the runtime is ready.
--- @param why string|nil Reason.
local function flush_waiters(ok, why)
	local waiters = ready_waiters
	ready_waiters = {}
	for _, waiter in ipairs(waiters) do
		local called, failure = pcall(waiter, ok, why)
		if not called then Logger.error(LOG, "Owned runtime ready callback failed: %s.", tostring(failure)) end
	end
end

--- Records that a started peer or capture can no longer be trusted.
--- @param why string Stable reason.
--- @param detail string Explanation.
local function lose(why, detail)
	set_state(STATE.FAILED, why, detail)
	Logger.error(LOG, "Owned runtime lost (%s): %s", why, detail)
	if capture_started and not capture_settled then
		-- A selected stream never falls back: revoke its credits now, the gap is
		-- recorded by the capture owner.
		local ok, failure = pcall(ports.capture.stop, function() capture_settled = true end)
		if not ok then Logger.error(LOG, "Physical capture stop after a lost runtime failed: %s.", tostring(failure)) end
	end
	flush_waiters(false, why)
end

local finish_stop

--- Handles the exit of the user-side process.
--- @param candidate table The peer that exited.
--- @param code any Exit code.
local function peer_exited(candidate, code)
	candidate.exited, candidate.code = true, code
	if peer ~= candidate then return end
	if state == STATE.STOPPING then return finish_stop() end
	if state == STATE.READY or state == STATE.PEERS_STARTING then
		lose(REASON.PEER_EXITED, "The runtime's user-side process exited with code " .. tostring(code) .. ".")
	end
end

--- Starts the user-side process once the owned configuration exists, then the
--- physical capture when it was requested. Calls `on_ready` exactly once when
--- the request is accepted.
--- @param on_ready function fn(ready, reason).
--- @return boolean accepted False when the state cannot start peers (no callback).
function M.ensure_peers(on_ready)
	assert(type(on_ready) == "function", "Missing owned runtime ready callback")
	if state == STATE.READY then
		on_ready(true, "already-ready")
		return true
	end
	if state == STATE.PEERS_STARTING then
		ready_waiters[#ready_waiters + 1] = on_ready
		return true
	end
	if state ~= STATE.ADMITTED then
		Logger.warn(LOG, "Owned runtime peers refused in state %s.", state)
		return false
	end
	local owned = KePaths.OWNED
	local config_file = ports.fs.expand(owned.CONFIG_FILE)
	if ports.fs.exists(config_file) ~= true then
		Logger.error(LOG, "Owned runtime peers not started: the owned configuration is missing.")
		on_ready(false, REASON.CONFIG_MISSING)
		return true
	end
	set_state(STATE.PEERS_STARTING)
	ready_waiters[#ready_waiters + 1] = on_ready
	Logger.start(LOG, "Starting the owned runtime's user-side process…")
	local candidate = { exited = false }
	local environment = { XDG_CONFIG_HOME = ports.fs.expand(owned.CONFIG_HOME) }
	local arguments = { "--owner-pid", tostring(ports.process.owner_pid()) }
	candidate.handle = ports.process.spawn(owned.CONSOLE, arguments, environment, function(code)
		peer_exited(candidate, code)
	end)
	peer = candidate
	if type(candidate.handle) ~= "table" or candidate.handle.start() ~= true then
		candidate.exited = true
		peer = nil
		set_state(STATE.FAILED, REASON.PEER_SPAWN_FAILED, "The user-side process could not be started.")
		Logger.error(LOG, "Owned runtime user-side process could not be started.")
		flush_waiters(false, REASON.PEER_SPAWN_FAILED)
		return true
	end
	if current_options.capture then
		local pinned = ports.artifact.pinned()
		local accepted = ports.capture and type(pinned) == "table" and ports.capture.start(pinned.capture)
		if accepted ~= true then
			-- The peer stays retained so a stop can settle it; nothing is credited.
			set_state(STATE.FAILED, REASON.CAPTURE_REFUSED, "The physical capture refused to start.")
			Logger.error(LOG, "Owned runtime physical capture refused to start.")
			flush_waiters(false, REASON.CAPTURE_REFUSED)
			return true
		end
		capture_started, capture_settled = true, false
	end
	set_state(STATE.READY)
	Logger.success(LOG, "Owned runtime user-side process started.")
	flush_waiters(true, "ready")
	return true
end





-- =======================
-- =======================
-- ======= 4/ Stop =======
-- =======================
-- =======================

--- Completes a stop once the capture and the peer are both observed settled.
--- @return boolean settled
--- @return string|nil pending Which part is still pending.
finish_stop = function()
	-- A synchronous exit report may already have completed this very stop.
	if state == STATE.STOPPED then return true end
	if state ~= STATE.STOPPING then return false, "not_stopping" end
	if capture_started and not capture_settled then return false, "capture_pending" end
	if peer and not peer.exited and not (peer.handle.isSettled() == true) then return false, "peer_pending" end
	peer, capture_started, capture_settled, current_options = nil, false, true, nil
	set_state(STATE.STOPPED)
	Logger.success(LOG, "Owned runtime stopped.")
	local observer = stop_observer
	stop_observer = nil
	if observer then
		local ok, failure = pcall(observer, true)
		if not ok then Logger.error(LOG, "Owned runtime stop observer failed: %s.", tostring(failure)) end
	end
	return true
end

--- Terminates the process once the capture is settled, then completes the stop
--- if both parts are observed gone.
--- @return boolean settled
--- @return string|nil pending
local function advance_stop()
	if state ~= STATE.STOPPING then return finish_stop() end
	if capture_settled and peer and not peer.exited then
		local ok, failure = pcall(peer.handle.terminate)
		if not ok then Logger.error(LOG, "Owned runtime user-side process termination failed: %s.", tostring(failure)) end
	end
	return finish_stop()
end

--- Stops the capture, then the user-side process. Safe to call again while a
--- part is pending: it retries the same retained handles and never spawns.
--- @param on_stopped function|nil Called once with true after exact settlement.
--- @return boolean settled True only when both parts are observed settled.
--- @return string|nil pending Reason while something remains.
function M.stop(on_stopped)
	assert(on_stopped == nil or type(on_stopped) == "function", "Invalid owned runtime stop observer")
	if not ports then return true end
	if state == STATE.STOPPED then return true end
	if on_stopped then
		if stop_observer and stop_observer ~= on_stopped then return false, "observer_conflict" end
		stop_observer = on_stopped
	end
	if state ~= STATE.STOPPING then
		Logger.start(LOG, "Stopping the owned runtime…")
		run = nil
		set_state(STATE.STOPPING)
		flush_waiters(false, "stopped")
	end
	if capture_started and not capture_settled then
		local settled = ports.capture.stop(function()
			capture_settled = true
			advance_stop()
		end)
		if settled == true then capture_settled = true end
	end
	return advance_stop()
end

--- Stops, then admits again, on an explicit request. There is no automatic
--- restart: a lost runtime stays `failed` until a caller decides.
--- @param options table Same as M.start.
--- @param on_settled function|nil Same as M.start.
--- @return boolean accepted False when the stop could not complete first.
function M.restart(options, on_settled)
	assert(ports, "Owned runtime owner is not initialized")
	Logger.info(LOG, "Restarting the owned runtime on request.")
	local settled = M.stop()
	if settled ~= true then
		Logger.warn(LOG, "Owned runtime restart refused: the previous stop is still pending.")
		return false
	end
	return M.start(options, on_settled)
end

return M
