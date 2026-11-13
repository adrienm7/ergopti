--- diagnostics/engine/field_check/owned_activation.lua

--- ==============================================================================
--- MODULE: Field Checks Of The Owned Runtime Activation Rule
--- DESCRIPTION:
--- The developer field run's proof, on the maintainer's Mac and with no manual
--- action, of the maintainer's rule of 2026-10-31 for Ergopti's own Karabiner
--- runtime (ADR 011; keyboard/adapters/runtime/activation.lua):
--- 1. owned_start: Ergopti runs, so the pinned artifact is verified in its own
---    folder, its runtime is ready, and a user Karabiner is closed with the
---    close recorded. After a resume the driver reloads and starts the same
---    way, so this check also proves close-on-resume on the run after a pause;
--- 2. owned_pause: the field run's own controlled pause stops Ergopti's runtime
---    and gives the user's Karabiner back, clearing the record. The resume is
---    queued for after the run has written its results, because a resume
---    reloads the driver (one capture per Lua VM) and must not cut the run.
--- 3. owned_install: a missing runtime is installed with no click of Ergopti's (the
---    macOS administrator prompt is the one human step), then the driver approval
---    is waited for; the field run's next step reloads so the owner admits it.
--- Restore-on-quit cannot run inside a field run, which ends with the app; it
--- shares restore_if_closed with the pause and is pinned by the unit suite.
---
--- FEATURES & RATIONALE:
--- 1. Skips Honestly: a boot on the shared runtime skips every step with
---    `shared_runtime`; a Mac where no user Karabiner was closed skips the close
---    and restore steps with `no_user_karabiner`, never passes them.
--- 2. Bounded: every wait ends after M.WAIT_SEC.
--- 3. Ports Only: every fact and effect comes through `ports.owned_activation`
---    (diagnostics/adapters/field_check_ports.lua), so the portable suite drives each step.
--- 4. Tokens Only: states, counts and reason tokens; no path or URL is reported.
--- ==============================================================================

local M = {}

--- Seconds between two looks while a transition settles.
M.POLL_SEC = 0.5
--- Seconds one transition may take: the owner's own readiness timeout (30 s)
--- plus the closer's exit wait (10 s), with a margin.
M.WAIT_SEC = 45

local ACTIVE = { starting = true, admitted = true, peers_starting = true, ready = true, stopping = true }
local SETTLED_ON = { ready = true, unavailable = true, failed = true }

--- Polls until `settled(value)` holds or the wait ends.
--- @param ports table Field check ports (after).
--- @param read function fn(callback(value)) one observation.
--- @param settled function fn(value) -> boolean.
--- @param callback function fn(value, settled).
local function wait_for(ports, read, settled, callback)
	local waited = 0
	local function look()
		read(function(value)
			if settled(value) or waited >= M.WAIT_SEC then return callback(value, settled(value)) end
			waited = waited + M.POLL_SEC
			ports.after(M.POLL_SEC, look)
		end)
	end
	look()
end

--- Reports every step id as skipped with one reason.
local function skip_all(report, ids, reason)
	for _, id in ipairs(ids) do report.step(id, "skip", reason) end
end

--- Close-on-start: the artifact, the runtime and the user's Karabiner.
--- @param ports table Field check ports; uses `owned_activation` and `after`.
--- @param report table Step reporter.
--- @param finish function Settles the check.
function M.start(ports, report, finish)
	local port = ports.owned_activation
	local ids = { "artifact", "runtime_ready", "user_karabiner_closed" }
	if type(port) ~= "table" or port.selected() ~= true then
		skip_all(report, ids, "shared_runtime")
		return finish()
	end
	port.fetch(function(ok, value)
		report.step("artifact", ok and "pass" or "fail", ok and "verified" or tostring(value))
		if port.paused() then
			skip_all(report, { "runtime_ready", "user_karabiner_closed" }, "paused")
			return finish()
		end
		local function state(callback) callback(port.owner_state()) end
		wait_for(ports, state, function(value) return SETTLED_ON[value] == true end, function(value)
			report.step("runtime_ready", value == "ready" and "pass" or "fail",
				value == "ready" and "ready" or (tostring(value) .. ":" .. tostring(port.owner_reason())))
			-- A runtime that never became ready closes nothing: leaving the
			-- user's Karabiner-Elements running is then correct, and the
			-- runtime_ready step already names why (field report 2026-11-05)
			if value ~= "ready" then
				report.step("user_karabiner_closed", "skip", "runtime_not_ready")
				return finish()
			end
			port.other_active(function(count)
				if port.marker() ~= true then
					-- Nothing was closed: a running user Karabiner here is the failure.
					if type(count) == "number" and count > 0 then
						report.step("user_karabiner_closed", "fail", count)
					else
						report.step("user_karabiner_closed", "skip", "no_user_karabiner")
					end
					return finish()
				end
				report.step("user_karabiner_closed", count == 0 and "pass" or "fail", count == nil and "unknown" or count)
				finish()
			end)
		end)
	end)
end

--- Restore-on-pause, then a resume queued for after the run.
--- @param ports table Field check ports; uses `owned_activation`, `after` and `after_run`.
--- @param report table Step reporter.
--- @param finish function Settles the check.
function M.pause(ports, report, finish)
	local port = ports.owned_activation
	local ids = { "paused", "runtime_stopped", "user_karabiner_restored", "resume_queued" }
	if type(port) ~= "table" or port.selected() ~= true then
		skip_all(report, ids, "shared_runtime")
		return finish()
	end
	local was_paused = port.paused()
	local closed_before = port.marker() == true
	if not was_paused then port.pause() end
	local function paused(callback) callback(port.paused()) end
	wait_for(ports, paused, function(value) return value == true end, function(_, done)
		report.step("paused", done and "pass" or "fail", done and "paused" or "not_paused")
		local function state(callback) callback(port.owner_state()) end
		wait_for(ports, state, function(value) return not ACTIVE[value] end, function(value, stopped)
			report.step("runtime_stopped", stopped and "pass" or "fail", tostring(value))
			local function restored(callback)
				port.other_active(function(count) callback({ count = count, marker = port.marker() }) end)
			end
			local function finish_with_resume()
				if was_paused then
					report.step("resume_queued", "skip", "was_paused")
				else
					report.step("resume_queued", ports.after_run(port.resume) == true and "pass" or "fail",
						"after_run")
				end
				finish()
			end
			if not closed_before then
				report.step("user_karabiner_restored", "skip", "no_user_karabiner")
				return finish_with_resume()
			end
			wait_for(ports, restored, function(value)
				return type(value.count) == "number" and value.count > 0 and value.marker ~= true
			end, function(value, back)
				report.step("user_karabiner_restored", back and "pass" or "fail",
					value.count == nil and "unknown" or value.count)
				finish_with_resume()
			end)
		end)
	end)
end

--- Seconds the administrator prompt, the install and the driver approval may
--- take together, inside the step's own deadline (diagnostics/data/field_run.json).
M.INSTALL_WAIT_SEC = 840
--- Seconds between two looks at the driver while macOS waits for the approval.
M.DRIVER_POLL_SEC = 5

--- Seconds the install check waits for the owner to leave a transient state.
--- The owner reads "starting" while it downloads and verifies the artifact,
--- which took 14 s for a new pin behind the maintainer's proxy. With the
--- driver wait it stays within the step's 900 s deadline (field_run.json).
M.OWNER_SETTLE_SEC = 60

--- Seconds between two looks at the owner while it settles.
M.OWNER_POLL_SEC = 1

--- Owner states that say nothing yet about the installed runtime: the check
--- decides only once the owner has left them.
M.TRANSIENT_OWNER_STATES = { uninitialized = true, idle = true, starting = true, stopping = true }

--- The first install with no click of Ergopti's: when the owner reports a
--- missing runtime, the install runs directly (the macOS administrator prompt
--- is the one human step), then the driver approval pane opens and the check
--- waits for macOS to report pqrs' driver active. The reload step that follows
--- in the field run lets the next owner admit the runtime.
--- @param ports table Field check ports; uses `owned_activation` and `after`.
--- @param report table Step reporter.
--- @param finish function Settles the check.
function M.install(ports, report, finish)
	local port = ports.owned_activation
	if type(port) ~= "table" or port.selected() ~= true then
		skip_all(report, { "install_needed", "installed", "driver_active" }, "shared_runtime")
		return finish()
	end
	local function driver()
		local waited, pane_opened = 0, false
		local function look()
			port.driver_active(function(active)
				if active == true then report.step("driver_active", "pass", "active"); return finish() end
				if not pane_opened then
					pane_opened = true
					port.open_driver_pane()
				end
				if waited >= M.INSTALL_WAIT_SEC then
					report.step("driver_active", "fail", active == nil and "unreadable" or "not_approved")
					return finish()
				end
				waited = waited + M.DRIVER_POLL_SEC
				ports.after(M.DRIVER_POLL_SEC, look)
			end)
		end
		look()
	end
	local function decide()
		local reason = port.owner_reason()
		if port.install_reasons()[reason] ~= true then
			report.step("install_needed", "info", "no:" .. tostring(port.owner_state()) .. ":" .. tostring(reason))
			report.step("installed", "skip", "not_needed")
			return driver()
		end
		report.step("install_needed", "info", "yes:" .. tostring(reason))
		port.install(function(ok, why)
			if ok ~= true then
				report.step("installed", "fail", tostring(why))
				report.step("driver_active", "skip", "not_installed")
				return finish()
			end
			report.step("installed", "pass", "installed")
			driver()
		end)
	end
	-- Field report 2026-11-09: the check read "starting" while the owner was
	-- still fetching a new artifact, took it for an installed runtime and
	-- skipped the install that the owner reported missing 11 s later.
	local settled_wait = 0
	local function settle()
		local state = port.owner_state()
		if M.TRANSIENT_OWNER_STATES[state] ~= true then return decide() end
		if settled_wait >= M.OWNER_SETTLE_SEC then
			report.step("install_needed", "fail", "owner_unsettled:" .. tostring(state))
			report.step("installed", "skip", "owner_unsettled")
			report.step("driver_active", "skip", "owner_unsettled")
			return finish()
		end
		settled_wait = settled_wait + M.OWNER_POLL_SEC
		ports.after(M.OWNER_POLL_SEC, settle)
	end
	settle()
end

return M
