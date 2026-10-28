--- adapters/karabiner_coexistence.lua

--- ==============================================================================
--- MODULE: Other Karabiner Detection And Closer (Hammerspoon)
--- DESCRIPTION:
--- Counts the active official Karabiner-Elements on this Mac and, only when the
--- caller holds the user's consent, asks it to quit, for the owned runtime
--- (ADR 011, decision 3). This is the one place the driver is allowed to act on
--- the official application, and only through Karabiner's own supported quit.
---
--- FEATURES & RATIONALE:
--- 1. Karabiner's Own Quit: « Quit Karabiner-Elements » runs the helper's
---    `unregister-*` subcommands. The closer runs exactly those and nothing else:
---    no kill, no signal, no `launchctl`, no edit of the user's configuration.
---    The root daemon stops grabbing by itself when its user-side peer closes.
--- 2. Active Means The Console User Server Runs: that process feeds the daemon
---    the user's rules, so it is what competes for the keyboards. An installed
---    but idle Karabiner is not "another running Karabiner".
--- 3. Named Refusal: a missing helper, a failing required step and a process
---    that outlives the wait each have their own answer; the owner turns them
---    into a stable reason. Nothing is retried and nothing is forced.
--- 4. Read-Only Description: `describe` reports what a close would do without
---    doing it, for the one-click field check.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local KePaths = require("platform.remap.ke_paths")

local LOG = "adapters.karabiner_coexistence"

--- Matches the official user-side process in either of the names its releases used.
M.PROCESS_PATTERN = "karabiner_console_user_server|Karabiner-Console-User-Server"

--- Seconds one observation or one quit step may take.
M.COMMAND_TIMEOUT_SEC = 5

--- Seconds the user-side process may take to exit after the quit steps.
M.EXIT_WAIT_SEC = 10

--- Seconds between two looks at the process while waiting for it to exit.
M.EXIT_POLL_INTERVAL_SEC = 0.25

--- The steps of Karabiner's own quit, in its order. A required step must exit 0;
--- the others belong to some releases only and are logged, never fatal.
M.QUIT_STEPS = {
	{ argument = "unregister-multitouch-extension-agent", required = false },
	{ argument = "unregister-notification-window-agent", required = false },
	{ argument = "unregister-core-agents", required = true },
	-- The menu agent may host this very request in the official application, so
	-- it is asked last, as Karabiner does.
	{ argument = "unregister-menu-agent", required = false },
}

--- Counts the non-empty lines of a command output.
--- @param text any Command output.
--- @return integer
local function count_lines(text)
	local count = 0
	for line in tostring(text or ""):gmatch("[^\r\n]+") do
		if line:match("%S") then count = count + 1 end
	end
	return count
end

--- Creates the detector and closer.
--- @param dependencies table|nil Optional test seams: exec(executable, args, timeout, fn(code, output)),
---   exists(path) -> boolean, timer (after, cancel).
--- @return table port { detect, close, describe }.
function M.new(dependencies)
	dependencies = dependencies or {}
	local exec = dependencies.exec or require("adapters.field_check_ports").exec
	local exists = dependencies.exists or require("adapters.file_system").exists
	local timer = dependencies.timer or require("adapters.timer_scheduler")
	local port = {}

	--- Counts the active official user-side processes.
	--- @param callback function fn(count|nil); nil means the observation failed.
	function port.detect(callback)
		exec("/usr/bin/pgrep", { "-f", M.PROCESS_PATTERN }, M.COMMAND_TIMEOUT_SEC, function(code, output)
			-- pgrep exits 1 when nothing matches; a timeout or any other status is unknown.
			if code == 0 then return callback(count_lines(output)) end
			callback(code == 1 and 0 or nil)
		end)
	end

	--- Waits for the user-side process to exit.
	--- @param remaining integer Looks left.
	--- @param callback function fn(ok).
	local function wait_for_exit(remaining, callback)
		port.detect(function(count)
			if count == 0 then return callback(true) end
			if count == nil or remaining <= 1 then
				Logger.warn(LOG, "The official Karabiner user process did not exit after the quit steps.")
				return callback(true)
			end
			local _, committed = timer.after(M.EXIT_POLL_INTERVAL_SEC, function()
				wait_for_exit(remaining - 1, callback)
			end)
			if committed ~= true then
				Logger.error(LOG, "The wait for the official Karabiner to exit could not be scheduled.")
				callback(false)
			end
		end)
	end

	--- Runs the quit steps in order.
	--- @param index integer Next step.
	--- @param callback function fn(ok).
	local function run_steps(index, callback)
		local step = M.QUIT_STEPS[index]
		if not step then
			return wait_for_exit(math.ceil(M.EXIT_WAIT_SEC / M.EXIT_POLL_INTERVAL_SEC), callback)
		end
		exec(KePaths.NON_PRIVILEGED_AGENTS, { step.argument }, M.COMMAND_TIMEOUT_SEC, function(code)
			if code ~= 0 then
				if step.required then
					Logger.error(LOG, "Karabiner's own quit step %s failed (status %s).", step.argument, tostring(code))
					return callback(false)
				end
				Logger.debug(LOG, "Optional Karabiner quit step %s answered %s.", step.argument, tostring(code))
			end
			run_steps(index + 1, callback)
		end)
	end

	--- Asks the official Karabiner to quit, exactly as its own « Quit » does.
	--- The caller must hold the user's consent: this acts on a product the user runs.
	--- @param callback function fn(ok); true means it was asked and has exited or is exiting.
	function port.close(callback)
		if not exists(KePaths.NON_PRIVILEGED_AGENTS) then
			Logger.error(LOG, "The official Karabiner's agents helper is missing; it cannot be asked to quit.")
			return callback(false)
		end
		Logger.warn(LOG, "Asking the official Karabiner-Elements to quit, as the close option consents (ADR 011).")
		run_steps(1, callback)
	end

	--- Describes, without acting, what a close would do.
	--- @param callback function fn({ helper_present, active_processes }).
	function port.describe(callback)
		local helper_present = exists(KePaths.NON_PRIVILEGED_AGENTS) == true
		port.detect(function(count)
			callback({ helper_present = helper_present, active_processes = count })
		end)
	end

	return port
end

return M
