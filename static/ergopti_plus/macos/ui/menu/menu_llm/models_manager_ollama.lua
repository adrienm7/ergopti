--- ui/menu/menu_llm/models_manager_ollama.lua

--- ==============================================================================
--- MODULE: Ollama Models Manager
--- DESCRIPTION:
--- Manages Ollama models: installation status and downloads via the CLI.
---
--- FEATURES & RATIONALE:
--- 1. Subprocess Checks: Validates standard installation paths for the daemon.
--- 2. Lightweight Wrapping: No heavy dependencies outside system binaries.
--- ==============================================================================

local M = {}

local hs            = hs
local notifications = require("infra.notifications")
local Logger        = require("infra.logger")
local i18n          = require("infra.i18n")
local text_utils    = require("infra.text_utils")
local OllamaBinary = require("modules.llm.ollama_binary")
local OllamaServerCommand = require("modules.llm.ollama_server_command")
local ShellRunner = require("adapters.shell_runner")
local TaskLifecycle = require("adapters.task_lifecycle")
local TimerScheduler = require("adapters.timer_scheduler")
local HttpClient = require("adapters.http_client")
local RequirementRegistry = require("ui.menu.menu_llm.requirement_operation_registry")

-- GC-root table: hs.task objects pinned here survive until their callback fires.
local _active_tasks = {}

local LOG = "menu_llm.ollama"
local BASH_BIN = "/bin/bash"                         -- Shell used only as an async daemon-launch worker.
local CURL_BIN = "/usr/bin/curl"                    -- Absolute path: Hammerspoon does not inherit login PATH reliably.
local OLLAMA_VERSION_URL = "http://localhost:11434/api/version"
local OLLAMA_READINESS_PROBE_TIMEOUT_SEC = 5         -- Bound each worker without blocking the Lua runloop.
local OLLAMA_READINESS_RETRY_DELAY_SEC = 0.5         -- Preserve the established daemon-start polling cadence.
local OLLAMA_READINESS_MAX_RETRIES = 30              -- Allow thirty bounded probes before terminal failure.

local ok_dw, download_window = pcall(require, "ui.download_window")
if not ok_dw then download_window = nil end





-- ==============================
-- ==============================
-- ======= 1/ CLI Helpers =======
-- ==============================
-- ==============================

--- Finds the absolute path to the Ollama binary.
--- @return string|nil The path or nil if not found.
local function get_ollama_path()
	local path = OllamaBinary.resolve()
	return path
end

--- Resolves the executable for an action that cannot proceed without it.
--- @param operation string Developer-facing operation label.
--- @return string|nil path
local function require_ollama_path(operation)
	local path, resolve_err = OllamaBinary.resolve()
	if path then return path end
	Logger.error(LOG, "Cannot %s because Ollama executable resolution failed: %s",
		tostring(operation), tostring(resolve_err))
	return nil
end





-- ==================================
-- ==================================
-- ======= 2/ Manager Factory =======
-- ==================================
-- ==================================

--- Instantiates the Ollama models manager.
--- @param deps table Module dependencies.
--- @param presets table Global models presets.
--- @param ram_getter function Resolves RAM requirements.
--- @return table The Ollama manager instance.
function M.new(deps, presets, ram_getter)
	local obj = {}
	local requirement_registry = RequirementRegistry.new({
		backend = "Ollama",
		require_owned = deps.script_control ~= nil,
	})
	local maintenance_capability = requirement_registry.create_owner(
		"Ollama model maintenance")
	local maintenance_registration_required = type(deps.script_control) == "table"
		and type(deps.script_control.register_pause_owner) == "function"
	local maintenance_registered = maintenance_registration_required ~= true
	-- Set before joining descendants and clear only after the same capability has
	-- no physical cleanup debt. This keeps admission closed across a failed PAUSE
	-- rollback whose exact task/timer has not reported settlement yet.
	local maintenance_pause_owned = false
	local maintenance_pause_settled = false

	local function release_requirement_task(owner)
		if type(owner) ~= "table" or owner.settled == true then return false end
		owner.settled = true
		local task = owner.task
		if task ~= nil then _active_tasks[task] = nil end
		if type(owner.release_slot) == "function" then owner.release_slot(task) end
		if owner.requirement_registered == true
			and type(owner.requirement_lifecycle) == "table"
			and type(owner.requirement_lifecycle.settle) == "function" then
			owner.requirement_registered = false
			owner.requirement_lifecycle.settle(owner)
		end
		return true
	end

	local function requirement_task_proven_not_running(task, label)
		local ok_method, method = xpcall(function()
			return task and task.isRunning
		end, debug.traceback)
		if not ok_method or type(method) ~= "function" then return false end
		local ok_running, running = xpcall(function()
			return method(task)
		end, debug.traceback)
		if not ok_running then
			Logger.error(LOG, "%s running-state probe raised: %s.",
				tostring(label), tostring(running))
		end
		return ok_running == true and running == false
	end

	local function cancel_requirement_task(owner, label)
		if type(owner) ~= "table" or owner.settled == true then return true end
		owner.authorized = false
		if owner.termination_accepted == true then return false end
		local task = owner.task
		local ok, result = xpcall(function()
			if task == nil or type(task.terminate) ~= "function" then return false end
			return task:terminate()
		end, debug.traceback)
		if owner.settled == true then return true end
		if not ok or result == false or result == nil then
			Logger.error(LOG, "%s termination refused; exact handle retained: %s.",
				tostring(label), tostring(result))
			return false
		end
		owner.termination_accepted = true
		return false
	end

	local function cancel_task(task_key)
		local t = deps.active_tasks and deps.active_tasks[task_key]
		if not t then return true end
		if type(t.terminate) ~= "function" then
			Logger.error(LOG, "Cannot cancel task '%s': terminate() is unavailable.", tostring(task_key))
			return false
		end
		local ok, result = Logger.callback(LOG, "Cancel task " .. tostring(task_key), function()
			return t:terminate()
		end)
		if not ok or result == false or result == nil then
			Logger.error(LOG, "Cancellation of task '%s' was refused: %s.",
				tostring(task_key), tostring(result))
			return false
		end
		-- Native hs.task:terminate() returns the task userdata when SIGTERM was
		-- accepted. That is a signal request, not process settlement; the exact slot
		-- stays owned until its completion callback clears it.
		return true
	end

	local function cancel_pull_and_upgrade()
		local pull_ok = cancel_task("ollama_pull")
		local upgrade_ok = cancel_task("ollama_upgrade")
		return pull_ok == true and upgrade_ok == true
	end

	local function maintenance_admitted()
		if maintenance_registered ~= true then return false end
		if maintenance_pause_owned == true then return false end
		if maintenance_registration_required ~= true then return true end
		local control = deps.script_control
		if type(control.is_paused) ~= "function"
			or type(control.is_pause_transition_pending) ~= "function" then
			return false
		end
		local paused_ok, paused = xpcall(control.is_paused, debug.traceback)
		local pending_ok, pending = xpcall(
			control.is_pause_transition_pending, debug.traceback)
		return paused_ok == true and paused == false
			and pending_ok == true and pending == false
	end

	local function begin_maintenance(label)
		if maintenance_admitted() ~= true then
			Logger.debug(LOG, "%s rejected by model-maintenance pause admission.", label)
			return nil
		end
		local operation, reason = requirement_registry.begin(maintenance_capability)
		if operation == nil then
			Logger.error(LOG, "%s ownership acquisition refused: %s.",
				label, tostring(reason))
		end
		return operation
	end

	if maintenance_registration_required then
		local maintenance_owner = {
			pause = function()
				maintenance_pause_owned = true
				local settled = requirement_registry.pause(maintenance_capability)
				maintenance_pause_settled = settled == true
				return settled == true
			end,
			resume = function()
				-- A rollback may ask to reopen ACTIVE immediately after pause() retained
				-- an ambiguous native owner. Refuse without re-signalling it; the retained
				-- PAUSE step is the sole retry edge for that identical capability.
				if maintenance_pause_settled ~= true then return false end
				maintenance_pause_owned = false
				maintenance_pause_settled = false
				return true
			end,
		}
		local registered_ok, registered = xpcall(function()
			return deps.script_control.register_pause_owner(
				"ollama_model_maintenance", maintenance_owner)
		end, debug.traceback)
		maintenance_registered = registered_ok == true and registered == true
		if maintenance_registered ~= true then
			Logger.error(LOG, "Ollama model-maintenance pause-owner registration refused: %s.",
				tostring(registered))
		end
	end

	local function show_progress_ui(title, terminal_cmd, initial_message, cancel_cb, retry_cb)
		if not download_window then return end
		pcall(download_window.show, {
			kind = "ollama_model",
			model = title,
			terminal_cmd = terminal_cmd,
			on_cancel = cancel_cb or cancel_pull_and_upgrade,
			on_retry = retry_cb,
		})
		if type(initial_message) == "string" and initial_message ~= "" then
			pcall(download_window.update, 0, nil, nil, initial_message)
		end
	end

	local function update_progress_ui(pct, message)
		if not download_window then return end
		if type(message) ~= "string" or message == "" then return end
		pcall(download_window.update, tonumber(pct) or 0, nil, nil, message)
	end

	local function complete_progress_ui(success, title, error_kind)
		if not download_window then return end
		pcall(download_window.complete, success == true, title, error_kind)
	end

	local function sanitize_terminal_stream(raw)
		if type(raw) ~= "string" or raw == "" then return "" end
		
		-- Remove all ANSI escape sequences and control characters systematically
		local clean = raw
		
		-- SCE[0-9;?]*[a-zA-Z] - Standard CSI sequences (cursor, erase, etc)
		clean = clean:gsub("\27%[[%d;?]*[%a]", "")
		
		-- ESC[0-9;?]*m - Color/style codes
		clean = clean:gsub("\27%[[^m]*m", "")
		
		-- ESC] ... BEL - OSC sequences (title, etc)
		clean = clean:gsub("\27%][^\7]*\7", "")
		
		-- ESC ( or ESC ) - Charset selection
		clean = clean:gsub("\27[()][%w]", "")
		
		-- All remaining ESC sequences with non-standard endings
		clean = clean:gsub("\27[^[].-[\128-\255]", "")
		
		-- Remove ALL control characters including CR, but preserve LF (10) and TAB (9)
		-- This handles invisible spinners, progress markers, etc.
		clean = clean:gsub("[\0-\8\11-\31\127]", "")
		
		-- Remove carriage returns explicitly (common in progress bars)
		clean = clean:gsub("\r", "")
		
		-- Clean up redundant whitespace
		clean = clean:gsub("[ \t]+\n", "\n")             -- Trailing spaces/tabs
		clean = clean:gsub("\n[ \t]*\n", "\n")           -- Blank lines
		
		return clean
	end

	local function build_ollama_restart_command()
		local ollama_bin = require_ollama_path("restart the daemon")
		if not ollama_bin then return nil end
		
		-- Launch daemon via bash nohup to ensure it survives subprocess termination.
		-- The shared foreground pipeline uses a `while read` loop because macOS'
		-- default BWK awk lacks gawk's strftime() / fflush(file) builtins.
		local launch_cmd, command_err = OllamaServerCommand.build(
			ollama_bin, Logger.UNIFIED_LOG_FILE)
		if not launch_cmd then
			Logger.error(LOG, "Could not build Ollama daemon command: %s", tostring(command_err))
			return nil
		end
		return "nohup /bin/bash -c " .. text_utils.shell_quote(launch_cmd)
			.. " </dev/null >/dev/null 2>&1 &"
	end

	-- One manager instance owns one readiness transaction. Callers join this
	-- single-flight operation with independent freshness predicates and terminal
	-- callbacks; a rapid A -> B switch therefore cannot launch two Ollama daemons.
	local readiness_operation = nil

	--- Ensures the Ollama daemon is running, starts it otherwise.
	--- @param on_ready function Callback executed when ready.
	--- @param on_fail function Callback executed when failed.
	--- @param opts table|nil Operation options, including the live generation predicate.
	--- @return boolean accepted True when the waiter joined or owned the readiness operation.
	local function ensure_ollama_running(on_ready, on_fail, opts)
		local requirement_lifecycle = type(opts) == "table"
			and opts._requirement_lifecycle or nil
		local waiter = {
			is_current = type(opts) == "table" and opts.is_current or function() return true end,
			on_ready = on_ready,
			on_fail = on_fail,
			terminal_sent = false,
			requirement_lifecycle = requirement_lifecycle,
			requirement_registered = false,
		}

		local function waiter_is_current(candidate)
			local ok, current = Logger.callback(LOG,
				"Ollama readiness waiter freshness check", candidate.is_current)
			return ok == true and current == true
		end

		local function settle_waiter(candidate, ready, reason)
			if candidate.terminal_sent then return false end
			candidate.terminal_sent = true
			local callback = ready and candidate.on_ready or candidate.on_fail
			if type(callback) ~= "function" then return true end
			local label = ready and "Ollama daemon ready" or "Ollama daemon failure"
			local ok, result
			if ready then
				ok, result = Logger.callback(LOG, label, callback)
			else
				ok, result = Logger.callback(LOG, label, callback, reason)
			end
			return ok == true and result ~= false
		end

		if not waiter_is_current(waiter) then
			settle_waiter(waiter, false, "stale")
			return false
		end

		local existing = readiness_operation
		if existing ~= nil and existing.terminal_sent == true then
			settle_waiter(waiter, false, "prior_readiness_unsettled")
			return false
		end
		if existing ~= nil then
			existing.waiters[#existing.waiters + 1] = waiter
			if type(existing.attach_requirement_waiter) == "function"
				and existing.attach_requirement_waiter(waiter) ~= true then
				settle_waiter(waiter, false, "requirement_owner_adoption_refused")
				return false
			end
			return true
		end

		local operation = {
			command = nil,
			retry_timer = nil,
			retries = 0,
			restart_requested = false,
			terminal_sent = false,
			settled = false,
			waiters = {waiter},
			requirement_waiters = {},
		}
		readiness_operation = operation

		local function owns_operation()
			return readiness_operation == operation and operation.terminal_sent ~= true
		end

		local release_operation
		local function release_retry_timer(owner)
			if type(owner) ~= "table" or owner.settled == true then return true end
			if owner.acquiring == true then return false end
			local handle = owner.handle
			if type(handle) == "table" and handle.timer ~= nil then return false end
			owner.settled = true
			if operation.retry_timer == owner then operation.retry_timer = nil end
			if type(release_operation) == "function" then release_operation() end
			return true
		end

		local function observe_retry_timer(owner)
			if type(owner) ~= "table" or owner.settled == true then return true end
			if owner.observer_attached == true then return true end
			local handle = owner.handle
			if type(handle) ~= "table" then return false end
			-- Publish before registration because onSettled() may deliver inline
			owner.observer_attached = true
			local observed_ok, observed = xpcall(function()
				return TimerScheduler.onSettled(handle, function()
					owner.observer_attached = false
					owner.native_settled = true
					if owner.delivery_requested == true
						and type(owner.deliver) == "function" then
						owner.deliver()
					elseif owner.cancel_requested == true
						or owner.acquisition_valid ~= true then
						release_retry_timer(owner)
					end
				end)
			end, debug.traceback)
			if observed_ok ~= true or observed ~= true then
				owner.observer_attached = false
				return false
			end
			return true
		end

		local function cancel_retry_timer()
			local owner = operation.retry_timer
			if not owner then return true end
			owner.cancel_requested = true
			if owner.acquiring == true then return false end
			local handle = owner.handle
			if type(handle) ~= "table" or handle.timer == nil then
				return release_retry_timer(owner)
			end
			local ok, cancelled = Logger.callback(LOG,
				"Ollama readiness retry timer cancellation", TimerScheduler.cancel, handle)
			if ok == true and cancelled == true then
				return release_retry_timer(owner)
			end
			Logger.error(LOG, "Ollama readiness retry timer refused cancellation; exact handle retained.")
			observe_retry_timer(owner)
			return false
		end

		local function release_requirement_waiter(candidate)
			if operation.requirement_waiters[candidate] ~= true then return false end
			operation.requirement_waiters[candidate] = nil
			if candidate.requirement_registered == true
				and type(candidate.requirement_lifecycle) == "table"
				and type(candidate.requirement_lifecycle.settle) == "function" then
				candidate.requirement_registered = false
				candidate.requirement_lifecycle.settle(candidate)
			end
			return true
		end

		release_operation = function()
			if operation.settled == true then return true end
			if operation.command ~= nil or operation.retry_timer ~= nil then return false end
			operation.settled = true
			if readiness_operation == operation then readiness_operation = nil end
			local requirement_waiters = {}
			for candidate in pairs(operation.requirement_waiters) do
				requirement_waiters[#requirement_waiters + 1] = candidate
			end
			for _, candidate in ipairs(requirement_waiters) do
				release_requirement_waiter(candidate)
			end
			return true
		end

		local function settle_operation(ready, reason)
			if operation.terminal_sent then return false end
			operation.terminal_sent = true
			if operation.retry_timer ~= nil then cancel_retry_timer() end
			local delivered = false
			local all_accepted = true
			local waiters = operation.waiters
			operation.waiters = {}
			-- Release the exact readiness owner before invoking business callbacks.
			-- A callback may synchronously start a successor requirement; keeping the
			-- terminal predecessor published until after delivery would reject that
			-- legitimate re-entry as `prior_readiness_unsettled`.
			release_operation()
			for _, candidate in ipairs(waiters) do
				if not candidate.terminal_sent then
					local candidate_ready = ready and waiter_is_current(candidate)
					local candidate_reason = reason
					if ready and not candidate_ready then candidate_reason = "stale" end
					if not ready and not waiter_is_current(candidate) then candidate_reason = "stale" end
					delivered = true
					if settle_waiter(candidate, candidate_ready, candidate_reason) ~= true then
						all_accepted = false
					end
				end
			end
			return delivered and all_accepted
		end

		local function observe_command_settlement(command)
			if operation.command_observed == command then return true end
			if type(command) ~= "table" or type(command.onSettled) ~= "function" then
				return false
			end
			local observed = command.onSettled(function()
				if operation.command == command then operation.command = nil end
				if operation.command_observed == command then
					operation.command_observed = nil
				end
				release_operation()
			end)
			if observed == true and operation.command == command then
				operation.command_observed = command
			end
			return observed == true
		end

		local function cancel_owned_command()
			local command = operation.command
			if command == nil then return true end
			if type(command.isSettled) == "function" and command.isSettled() == true then
				if operation.command == command then operation.command = nil end
				return true
			end
			if type(command.terminate) ~= "function" then return false end
			local ok, accepted, state = xpcall(function()
				return command.terminate()
			end, debug.traceback)
			if operation.command ~= command then return true end
			if type(command.isSettled) == "function" and command.isSettled() == true then
				operation.command = nil
				return true
			end
			observe_command_settlement(command)
			if not ok or accepted ~= true or state ~= "settled" then return false end
			operation.command = nil
			return true
		end

		local function has_current_waiter(excluded)
			for _, candidate in ipairs(operation.waiters) do
				if candidate ~= excluded and not candidate.terminal_sent
					and waiter_is_current(candidate) then
					return true
				end
			end
			return false
		end

		local function cancel_exact_operation(reason)
			if operation.terminal_sent ~= true then
				operation.terminal_sent = true
				for _, candidate in ipairs(operation.waiters) do
					if not candidate.terminal_sent then
						settle_waiter(candidate, false, reason or "stale")
					end
				end
			end
			local timer_settled = cancel_retry_timer()
			local command_settled = cancel_owned_command()
			release_operation()
			return timer_settled == true and command_settled == true
				and operation.settled == true
		end

		operation.attach_requirement_waiter = function(candidate)
			local lifecycle = candidate.requirement_lifecycle
			if type(lifecycle) ~= "table" or type(lifecycle.adopt) ~= "function" then
				return true
			end
			operation.requirement_waiters[candidate] = true
			candidate.pause_join = function()
				if candidate.requirement_registered ~= true then return true end
				candidate.terminal_sent = true
				if has_current_waiter(candidate) then
					release_requirement_waiter(candidate)
					return true
				end
				cancel_exact_operation("script_paused")
				return candidate.requirement_registered ~= true
			end
			if lifecycle.adopt(candidate, candidate.pause_join,
				"Ollama requirement readiness") ~= true then
				operation.requirement_waiters[candidate] = nil
				return false
			end
			candidate.requirement_registered = true
			return true
		end

		local function retain_current_waiters()
			if not owns_operation() then return false end
			local limit = #operation.waiters
			for index = 1, limit do
				local candidate = operation.waiters[index]
				if not candidate.terminal_sent and not waiter_is_current(candidate) then
					settle_waiter(candidate, false, "stale")
				end
			end
			for _, candidate in ipairs(operation.waiters) do
				if not candidate.terminal_sent then return true end
			end
			cancel_exact_operation("stale")
			return false
		end

		local start_probe
		local start_restart
		local schedule_retry

		local function start_owned_command(label, executable, args, on_done, refusal_reason)
			if not retain_current_waiters() then return false end
			if operation.command ~= nil then
				Logger.error(LOG, "%s refused because another readiness command is still owned.", label)
				settle_operation(false, "readiness_command_overlap")
				return false
			end

			local command
			local start_in_progress = true
			local pending_completion = nil
			local function finish_command(exit_code, stdout, stderr)
				if operation.command ~= command then return false end
				operation.command = nil
				if not retain_current_waiters() then return false end
				local done_ok, done_result = Logger.callback(LOG,
					label .. " completion", on_done, exit_code, stdout, stderr)
				if not done_ok then
					settle_operation(false, label .. "_callback_failed")
					return false
				end
				if done_result == false and owns_operation() then
					settle_operation(false, label .. "_completion_refused")
				end
				return done_result ~= false
			end
			local built_ok, candidate = Logger.callback(LOG, label .. " construction",
				ShellRunner.spawn, executable, args, function(exit_code, stdout, stderr)
					-- A hostile/native-faithful task double may deliver completion from
					-- inside :start() before :start() reports whether acquisition
					-- committed.  Buffer that completion until the exact true result;
					-- otherwise downstream model work can start and then be contradicted
					-- by a start-refusal terminal from this same command.
					if start_in_progress then
						if pending_completion == nil then
							pending_completion = table.pack(exit_code, stdout, stderr)
						end
						return true
					end
					return finish_command(exit_code, stdout, stderr)
				end)
			if not built_ok or type(candidate) ~= "table" or type(candidate.start) ~= "function" then
				settle_operation(false, refusal_reason)
				return false
			end

			command = candidate
			operation.command = command
			local start_ok, started = Logger.callback(LOG, label .. " start", command.start)
			start_in_progress = false
			if not start_ok or started ~= true then
				if type(command.isSettled) == "function" and command.isSettled() == true then
					if operation.command == command then operation.command = nil end
				else
					observe_command_settlement(command)
				end
				settle_operation(false, refusal_reason)
				return false
			end
			if pending_completion ~= nil then
				return finish_command(table.unpack(pending_completion, 1, pending_completion.n))
			end
			return true
		end

		schedule_retry = function()
			if not retain_current_waiters() then return false end
			if operation.retry_timer ~= nil then
				Logger.error(LOG, "Ollama readiness retry refused because a timer is already owned.")
				settle_operation(false, "retry_timer_overlap")
				return false
			end

			local owner = {
				handle = nil,
				acquiring = true,
				cancel_requested = false,
				acquisition_valid = false,
				delivery_requested = false,
				delivery_seen = false,
				delivery_during_acquisition = false,
				native_settled = false,
				settled = false,
			}
			operation.retry_timer = owner
			owner.deliver = function()
				if owner.delivery_seen == true or operation.retry_timer ~= owner then
					return false
				end
				owner.delivery_requested = true
				if owner.acquiring == true then
					owner.delivery_during_acquisition = true
					return false
				end
				local handle = owner.handle
				if type(handle) == "table" and handle.timer ~= nil then
					observe_retry_timer(owner)
					return false
				end
				owner.delivery_seen = true
				owner.settled = true
				operation.retry_timer = nil
				if owner.acquisition_valid ~= true
					or owner.cancel_requested == true or not owns_operation() then
					release_operation()
					return false
				end
				if not retain_current_waiters() then
					release_operation()
					return false
				end
				operation.retries = operation.retries + 1
				return start_probe(true)
			end
			local timer_ok, candidate, committed = Logger.callback(LOG,
				"Ollama readiness retry timer", TimerScheduler.after,
				OLLAMA_READINESS_RETRY_DELAY_SEC, function()
					return owner.deliver()
				end)
			if type(candidate) == "table" then owner.handle = candidate end
			owner.acquiring = false
			local acquisition_committed = timer_ok == true
				and type(candidate) == "table" and committed == true
				and candidate.timer ~= nil and operation.retry_timer == owner
				and owner.delivery_during_acquisition ~= true
				and owner.cancel_requested ~= true and owns_operation()
			if acquisition_committed ~= true then
				owner.cancel_requested = true
				if operation.terminal_sent == true then
					cancel_retry_timer()
				else
					settle_operation(false, "retry_timer_refused")
				end
				return false
			end
			owner.acquisition_valid = true
			observe_retry_timer(owner)
			return true
		end

		start_restart = function()
			local command = build_ollama_restart_command()
			if not command then
				pcall(notifications.notify, i18n.get("ollama.fail_title"),
					i18n.get("ollama.daemon_fail"), "error")
				settle_operation(false, "restart_command_unavailable")
				return false
			end
			-- Do not use a login shell: user profile startup is unrelated to this
			-- fixed launch command and can otherwise stall the shared readiness owner.
			return start_owned_command("Ollama daemon restart", BASH_BIN, {"-c", command},
				function(exit_code)
					if exit_code ~= 0 then
						Logger.error(LOG, "Ollama daemon restart worker exited with code %s.",
							tostring(exit_code))
						pcall(notifications.notify, i18n.get("ollama.fail_title"),
							i18n.get("ollama.daemon_fail"), "error")
						settle_operation(false, "restart_failed")
						return false
					end
					return schedule_retry()
				end, "restart_task_start_refused")
		end

		start_probe = function(is_retry)
			return start_owned_command("Ollama readiness probe", CURL_BIN,
				{"-s", "--max-time", tostring(OLLAMA_READINESS_PROBE_TIMEOUT_SEC),
					OLLAMA_VERSION_URL},
				function(exit_code, stdout)
					if exit_code == 0 and type(stdout) == "string"
						and stdout:find('"version"', 1, true) then
						return settle_operation(true)
					end
					if not is_retry and not operation.restart_requested then
						operation.restart_requested = true
						pcall(notifications.notify, i18n.get("ollama.starting_title"),
							i18n.get("ollama.service_stopped"), "info")
						return start_restart()
					end
					if operation.retries < OLLAMA_READINESS_MAX_RETRIES then return schedule_retry() end
					Logger.error(LOG, "Ollama daemon stayed unavailable after %d readiness probes.",
						OLLAMA_READINESS_MAX_RETRIES)
					pcall(notifications.notify, i18n.get("ollama.fail_title"),
						i18n.get("ollama.start_fail"), "error")
					settle_operation(false, "readiness_timeout")
					return false
				end, "readiness_probe_start_refused")
		end

		if operation.attach_requirement_waiter(waiter) ~= true then
			settle_operation(false, "requirement_owner_adoption_refused")
			return false
		end
		return start_probe(false)
	end

	local function get_ollama_repo(model_name)
		for _, provider in ipairs(presets) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					if m.name == model_name and m.urls and m.urls.ollama then
						local url = m.urls.ollama
						local repo = url:gsub("^https?://ollama%.com/library/", "")
						repo = repo:gsub("^https?://ollama%.com/", "")
						return repo
					end
				end
			end
		end
		return model_name
	end

	local function needs_ollama_upgrade(output)
		if type(output) ~= "string" or output == "" then return false end
		local s = output:lower()
		if s:find("requires a newer version of ollama", 1, true) then return true end
		if s:find("please download the latest version", 1, true) then return true end
		if s:find("412", 1, true) and s:find("newer version", 1, true) then return true end
		return false
	end


	local _installed_cache = nil
	local _installed_cache_time = 0
	local INSTALLED_CACHE_TTL = 30  -- Cache valid for 30s; avoids repeated 'ollama list' on same menu open
	local _installed_loading = false
	local _installed_refresh_owner = nil
	local _initial_refresh_timer_owner = nil

	--- Refreshes the installed models cache asynchronously (fire-and-forget).
	local function refresh_installed_async()
		-- The zero-delay warmup owns this identical cache refresh until its timer
		-- settles. A menu read during a refused one-shot self-stop may return stale
		-- cache, but it cannot launch a sibling refresh around that live capability.
		if type(_initial_refresh_timer_owner) == "table"
			and _initial_refresh_timer_owner.settled ~= true then
			return true
		end
		if _installed_loading then
			-- A refused/mutated start deliberately keeps the loading slot and its
			-- exact task pinned. A later menu read is the natural retry edge for
			-- that same cleanup capability, never permission to launch a sibling.
			local retained = _installed_refresh_owner
			if type(retained) == "table" and retained.settled ~= true
				and retained.authorized ~= true then
				cancel_requirement_task(retained,
					"Ollama installed-model refresh cleanup retry")
			end
			return true
		end
		local operation = begin_maintenance("Ollama installed-model refresh")
		if operation == nil then return false end
		_installed_loading = true
		local bin = require_ollama_path("refresh installed models")
		if not bin then
			_installed_loading = false
			operation.finish(nil, "Ollama installed-model refresh path refusal")
			return false
		end
		-- hs.task is non-blocking unlike hs.execute.
		-- Pinned to _active_tasks so the GC cannot SIGTERM it before the callback
		-- fires and resets _installed_loading — a GC kill would deadlock the lock.
		local owner = {
			task = nil,
			authorized = true,
			start_committed = false,
			dispatching = true,
			pending_terminal = nil,
			settled = false,
			termination_accepted = false,
			requirement_lifecycle = operation.lifecycle,
			requirement_registered = false,
		}
		owner.release_slot = function(task)
			if _installed_refresh_owner == owner then _installed_refresh_owner = nil end
			if task == owner.task then _installed_loading = false end
		end
		local task
		local function finish_refresh(code, stdout)
			if owner.settled == true then return false end
			local authorized = owner.authorized == true
				and owner.start_committed == true
				and operation.is_authorized() == true
			release_requirement_task(owner)
			operation.finish(nil, "Ollama installed-model refresh terminal")
			if authorized ~= true then return false end
			local installed = {}
			if code == 0 and type(stdout) == "string" then
				for line in stdout:gmatch("[^\r\n]+") do
					local name = line:match("^(%S+)")
					if name and name ~= "NAME" then installed[name] = true end
				end
			end
			_installed_cache = installed
			_installed_cache_time = hs.timer.secondsSinceEpoch()
			return true
		end
		task = TaskLifecycle.native("Ollama installed-model refresh", bin, function(...)
			if owner.dispatching == true then
				if owner.pending_terminal == nil then
					owner.pending_terminal = table.pack(...)
				end
				return true
			end
			return finish_refresh(...)
		end, {"list"})
		owner.task = task
		if task then
			_installed_refresh_owner = owner
			_active_tasks[task] = true
			owner.pause_join = function()
				return cancel_requirement_task(owner,
					"Ollama installed-model refresh pause")
			end
			if operation.lifecycle.adopt(owner, owner.pause_join,
				"Ollama installed-model refresh") ~= true then
				owner.authorized = false
				if requirement_task_proven_not_running(task,
					"Ollama refresh adoption refusal") then
					release_requirement_task(owner)
				else
					cancel_requirement_task(owner,
						"Ollama refresh adoption refusal")
				end
				operation.finish(nil, "Ollama refresh adoption refusal")
				return false
			end
			owner.requirement_registered = true
			local start_ok, started = xpcall(function()
				return TaskLifecycle.start(task, "Ollama installed-model refresh")
			end, debug.traceback)
			owner.dispatching = false
			if start_ok ~= true or started ~= true then
				if start_ok ~= true then
					Logger.error(LOG,
						"Ollama installed-model refresh start raised; exact task retained: %s.",
						tostring(started))
				end
				owner.authorized = false
				if owner.pending_terminal ~= nil then
					local terminal = owner.pending_terminal
					owner.pending_terminal = nil
					finish_refresh(table.unpack(terminal, 1, terminal.n))
				elseif requirement_task_proven_not_running(task,
					"Ollama installed-model refresh start refusal") then
					release_requirement_task(owner)
				else
					cancel_requirement_task(owner,
						"Ollama installed-model refresh start refusal")
				end
				operation.finish(nil, "Ollama installed-model refresh start refusal")
				return false
			end
			owner.start_committed = true
			if operation.is_authorized() ~= true then
				owner.authorized = false
				cancel_requirement_task(owner,
					"Ollama installed-model refresh post-start fence")
				operation.finish(nil, "Ollama installed-model refresh revoked")
				return false
			end
			if owner.pending_terminal ~= nil then
				local terminal = owner.pending_terminal
				owner.pending_terminal = nil
				return finish_refresh(table.unpack(terminal, 1, terminal.n))
			end
			return true
		else
			owner.dispatching = false
			owner.settled = true
			_installed_loading = false
			operation.finish(nil, "Ollama installed-model refresh construction refusal")
			return false
		end
	end

	function obj.get_installed_models()
		local now = hs.timer.secondsSinceEpoch()
		-- Return cached result if still valid
		if _installed_cache and (now - _installed_cache_time) < INSTALLED_CACHE_TTL then
			return _installed_cache
		end
		-- Trigger async refresh for next menu open; return stale cache or empty table now
		refresh_installed_async()
		return _installed_cache or {}
	end

	--- Pre-warms the installed models cache under the same exact pause owner.
	local function schedule_initial_refresh()
		local operation = begin_maintenance("Ollama initial installed-model refresh")
		if operation == nil then return false end
		local owner = {
			handle = nil,
			acquiring = true,
			cancel_requested = false,
			authorized = true,
			start_committed = false,
			settled = false,
			delivery_requested = false,
			delivery_seen = false,
			delivery_during_acquisition = false,
		}
		_initial_refresh_timer_owner = owner
		local function release_owner()
			if owner.settled == true then return false end
			owner.settled = true
			if _initial_refresh_timer_owner == owner then
				_initial_refresh_timer_owner = nil
			end
			operation.lifecycle.settle(owner)
			return true
		end
		local deliver_owner
		local function observe_settlement()
			if owner.observer_attached == true then return true end
			if type(owner.handle) ~= "table" then return false end
			owner.observer_attached = true
			local observed_ok, observed = xpcall(function()
				return TimerScheduler.onSettled(owner.handle, function()
					owner.observer_attached = false
					if owner.delivery_requested == true then
						deliver_owner()
					else
						release_owner()
					end
				end)
			end, debug.traceback)
			if observed_ok ~= true or observed ~= true then
				owner.observer_attached = false
				return false
			end
			return true
		end
		deliver_owner = function()
			if owner.delivery_seen == true or owner.settled == true
				or owner.acquiring == true then
				return false
			end
			if type(owner.handle) == "table" and owner.handle.timer ~= nil then
				observe_settlement()
				return false
			end
			owner.delivery_seen = true
			local authorized = owner.authorized == true
				and owner.start_committed == true
				and operation.is_authorized() == true
			release_owner()
			operation.finish(nil, "Ollama initial installed-model refresh terminal")
			if authorized ~= true then return false end
			return refresh_installed_async()
		end
		local function cancel_owner()
			owner.authorized = false
			if owner.acquiring == true then
				owner.cancel_requested = true
				return false
			end
			if type(owner.handle) ~= "table" or owner.handle.timer == nil then
				if owner.delivery_requested == true then deliver_owner()
				else release_owner() end
				return true
			end
			local cancel_ok, settled = xpcall(function()
				return TimerScheduler.cancel(owner.handle)
			end, debug.traceback)
			if cancel_ok == true and settled == true then
				if owner.delivery_requested == true then deliver_owner()
				else release_owner() end
				return true
			end
			observe_settlement()
			return false
		end
		owner.pause_join = cancel_owner
		if operation.lifecycle.adopt(owner, owner.pause_join,
			"Ollama initial installed-model refresh") ~= true then
			owner.acquiring = false
			owner.authorized = false
			release_owner()
			operation.finish(nil, "Ollama initial refresh adoption refusal")
			return false
		end
		local timer_ok, handle_or_error, committed = xpcall(function()
			return TimerScheduler.after(0, function()
				owner.delivery_requested = true
				if owner.acquiring == true then
					owner.delivery_during_acquisition = true
					return false
				end
				return deliver_owner()
			end)
		end, debug.traceback)
		if timer_ok and type(handle_or_error) == "table" then
			owner.handle = handle_or_error
		end
		owner.acquiring = false
		if timer_ok ~= true or committed ~= true
			or type(owner.handle) ~= "table" or owner.handle.timer == nil
			or owner.delivery_during_acquisition == true
			or owner.cancel_requested == true or owner.authorized ~= true
			or operation.is_authorized() ~= true
			or _initial_refresh_timer_owner ~= owner then
			cancel_owner()
			operation.finish(nil, "Ollama initial refresh timer refusal")
			return false
		end
		owner.start_committed = true
		if owner.delivery_requested == true then return deliver_owner() end
		return true
	end

	schedule_initial_refresh()

	local function check_model_loadable(target_model, on_success, on_fail, opts)
		local is_current = type(opts) == "table" and opts.is_current or function() return true end
		local requirement_lifecycle = type(opts) == "table"
			and opts._requirement_lifecycle or nil
		local terminal_sent = false
		local function settle(callback, label, ...)
			if terminal_sent then return false end
			terminal_sent = true
			if type(callback) ~= "function" then return true end
			local ok, result = Logger.callback(LOG, label, callback, ...)
			return ok and result ~= false
		end
		local function settle_failure(...)
			return settle(on_fail, "Ollama model-load failure", ...)
		end
		local function still_current()
			local ok, current = Logger.callback(LOG,
				"Ollama model-load freshness check", is_current)
			return ok == true and current == true
		end
		local function current_or_cancel()
			if still_current() then return true end
			settle_failure("stale", false)
			return false
		end

		if not current_or_cancel() then return false end
		if type(target_model) ~= "string" or target_model == "" then
			settle_failure("invalid_model", false)
			return false
		end

		local payload = {
			model = target_model,
			messages = {{ role = "user", content = "ok" }},
			stream = false,
			think = false,
			options = {
				num_predict = 1,
				think = false,
				thinking_budget = 0,
			},
		}

		local ok_enc, body = pcall(hs.json.encode, payload)
		if not ok_enc or type(body) ~= "string" then
			settle_failure("encode_error", false)
			return false
		end

		if not current_or_cancel() then return false end
		local client = HttpClient.new()
		local requirement_registered = false
		local requirement_settled = false
		local function settle_requirement_client()
			if requirement_settled then return false end
			requirement_settled = true
			if requirement_registered and type(requirement_lifecycle) == "table"
				and type(requirement_lifecycle.settle) == "function" then
				requirement_registered = false
				requirement_lifecycle.settle(client)
			end
			return true
		end
		local function pause_requirement_client()
			local ok, settled = xpcall(client.cancel, debug.traceback)
			if ok == true and settled == true then
				settle_requirement_client()
				return true
			end
			return false
		end
		if type(requirement_lifecycle) == "table"
			and type(requirement_lifecycle.adopt) == "function" then
			if requirement_lifecycle.adopt(client, pause_requirement_client,
				"Ollama requirement loadability HTTP") ~= true then
				settle_failure("requirement_owner_adoption_refused", false)
				return false
			end
			requirement_registered = true
		end
		local accepted = client.post("http://127.0.0.1:11434/api/chat",
			{ ["Content-Type"] = "application/json" }, body, function(result)
				if not current_or_cancel() then return end
				if type(result) == "table" and result.status == 200 then
					settle(on_success, "Ollama model-load success")
					return
				end

				local err_text = type(result) == "table"
					and type(result.body) == "string" and result.body or ""
				local load_error = err_text:find("unable to load model", 1, true) ~= nil
				settle_failure(err_text, load_error)
			end)
		if type(client.onSettled) == "function" then
			client.onSettled(settle_requirement_client)
		end
		if accepted ~= true then
			pause_requirement_client()
			settle_failure("http_dispatch_refused", false)
			return false
		end
		return true
	end

	function obj.pull_model(target_model, repo, on_success, on_cancel, opts)
		local is_current = type(opts) == "table" and opts.is_current or function() return true end
		local requirement_lifecycle = type(opts) == "table"
			and opts._requirement_lifecycle or nil
		local terminal_sent = false
		local owner = {
			cancel_requested = false,
			completion_seen = false,
			completion_dispatching = false,
			authorized = true,
			settled = false,
			task_settled = false,
			start_committed = false,
			termination_accepted = false,
			retry_timer = nil,
			retry_timer_observed = nil,
			retry_delivery_seen = false,
			retry_requested = false,
			retry_started = false,
			retry_acquiring = false,
			retry_cancel_requested = false,
			retry_acquisition_valid = false,
			retry_awaiting_delivery = false,
			requirement_lifecycle = requirement_lifecycle,
			requirement_registered = false,
		}
		local task
		local function settle(callback, label, ...)
			if terminal_sent then return false end
			terminal_sent = true
			if type(callback) ~= "function" then return true end
			local ok, result = Logger.callback(LOG, label, callback, ...)
			return ok and result ~= false
		end
		local function settle_cancel(...)
			return settle(on_cancel, "Ollama pull cancellation", ...)
		end
		local function still_current()
			local ok, current = Logger.callback(LOG,
				"Ollama pull freshness check", is_current)
			return ok == true and current == true
		end
		local function current_or_cancel()
			if owner.cancel_requested then return false end
			if still_current() then return true end
			settle_cancel("stale")
			return false
		end
		local function settle_success(...)
			if not current_or_cancel() then return false end
			return settle(on_success, "Ollama pull success", ...)
		end

		if not current_or_cancel() then return false end
		deps.active_tasks = deps.active_tasks or {}
		if deps.active_tasks["ollama_pull"] then
			Logger.warn(LOG, "Ollama pull for %s refused while another pull owns the slot.",
				tostring(target_model))
			settle_cancel("busy")
			return false
		end
		local bin = require_ollama_path("pull a model")
		if not bin then
			pcall(notifications.notify, i18n.get("ollama.fail_title"),
				string.format(i18n.get("ollama.download_error"), tostring(target_model)), "error")
			settle_cancel("binary_unavailable")
			return false
		end
		local pull_output = ""
		local maybe_release_pull_owner
		local launch_retry
		local function settle_pull_task()
			if owner.task_settled == true then return false end
			owner.task_settled = true
			if deps.active_tasks["ollama_pull"] == task then
				deps.active_tasks["ollama_pull"] = nil
			end
			if owner.task == task then owner.task = nil end
			if type(maybe_release_pull_owner) == "function" then
				maybe_release_pull_owner()
			end
			return true
		end
		maybe_release_pull_owner = function()
			if owner.settled == true then return true end
			if owner.task_settled ~= true
				or owner.retry_timer ~= nil
				or owner.retry_acquiring == true
				or owner.retry_awaiting_delivery == true
				or owner.completion_dispatching == true then
				return false
			end
			return release_requirement_task(owner)
		end
		local function observe_retry_timer(handle)
			if owner.retry_timer_observed == handle then return true end
			local ok, observed = Logger.callback(LOG,
				"Ollama pull retry settlement observation",
				TimerScheduler.onSettled, handle, function()
					if owner.retry_timer == handle then owner.retry_timer = nil end
					if owner.retry_timer_observed == handle then
						owner.retry_timer_observed = nil
					end
					if owner.retry_delivery_seen == true
						and owner.retry_acquisition_valid == true
						and type(launch_retry) == "function" then
						launch_retry()
					else
						maybe_release_pull_owner()
					end
				end)
			if ok == true and observed == true and owner.retry_timer == handle then
				owner.retry_timer_observed = handle
			end
			return ok == true and observed == true
		end
		local function cancel_retry_timer()
			owner.retry_acquisition_valid = false
			owner.retry_awaiting_delivery = false
			if owner.retry_acquiring == true then
				owner.retry_cancel_requested = true
				return false
			end
			local handle = owner.retry_timer
			if handle == nil then return true end
			local ok, settled = Logger.callback(LOG,
				"Ollama pull retry cancellation", TimerScheduler.cancel, handle)
			if ok == true and settled == true then
				if owner.retry_timer == handle then owner.retry_timer = nil end
				maybe_release_pull_owner()
				return true
			end
			observe_retry_timer(handle)
			Logger.error(LOG,
				"Ollama pull retry cancellation refused; exact timer retained.")
			return false
		end
		local function cancel_current_pull()
			if owner.task_settled == true then return true end
			if not task or deps.active_tasks["ollama_pull"] ~= task then return false end
			owner.cancel_requested = true
			owner.authorized = false
			if owner.termination_accepted == true then return true end
			if type(task.terminate) ~= "function" then
				Logger.error(LOG, "Ollama pull cancellation refused: terminate() is unavailable.")
				settle_cancel("termination_refused")
				complete_progress_ui(false, target_model)
				return false
			end
			local ok, result = Logger.callback(LOG, "Ollama pull termination", function()
				return task:terminate()
			end)
			if owner.task_settled == true then return true end
			if not ok or result == false or result == nil then
				Logger.error(LOG, "Ollama pull cancellation was refused: %s.", tostring(result))
				settle_cancel("termination_refused")
				complete_progress_ui(false, target_model)
				return false
			end
			owner.termination_accepted = true
			return true
		end

		launch_retry = function()
			if owner.retry_started == true then return false end
			if owner.retry_acquisition_valid ~= true then return false end
			owner.retry_started = true
			owner.retry_acquisition_valid = false
			owner.retry_awaiting_delivery = false
			owner.retry_timer = nil
			owner.retry_timer_observed = nil
			if not current_or_cancel() then
				maybe_release_pull_owner()
				return false
			end
			local accepted = obj.pull_model(target_model, repo,
				on_success, on_cancel, opts)
			maybe_release_pull_owner()
			return accepted == true
		end

		local function do_retry()
			if not current_or_cancel() then return false end
			if owner.task_settled ~= true then return false end
			if deps.active_tasks and deps.active_tasks["ollama_pull"] then return false end
			if owner.retry_timer ~= nil or owner.retry_started == true then return false end
			owner.retry_delivery_seen = false
			owner.retry_cancel_requested = false
			owner.retry_acquisition_valid = false
			owner.retry_acquiring = true
			owner.retry_awaiting_delivery = true
			local retry_handle
			local ok, candidate, committed = Logger.callback(LOG,
				"Ollama pull retry timer", TimerScheduler.after, 0.05, function()
					if owner.retry_started == true then return false end
					owner.retry_delivery_seen = true
					if type(retry_handle) == "table" and retry_handle.timer ~= nil then
						-- TimerScheduler fenced user delivery, but a refused native stop
						-- remains exact cleanup debt. Its settlement observer launches the
						-- successor only after the identical timer is truly gone.
						return false
					end
					return launch_retry()
				end)
			if type(candidate) == "table" and candidate.timer ~= nil then
				owner.retry_timer = candidate
				observe_retry_timer(candidate)
			end
			owner.retry_acquiring = false
			local acquisition_committed = ok == true
				and type(candidate) == "table" and candidate.timer ~= nil
				and committed == true and owner.retry_timer == candidate
				and owner.retry_cancel_requested ~= true
				and owner.cancel_requested ~= true and owner.authorized == true
				and still_current()
			if acquisition_committed ~= true then
				owner.retry_awaiting_delivery = false
				cancel_retry_timer()
				maybe_release_pull_owner()
				return false
			end
			retry_handle = candidate
			owner.retry_acquisition_valid = true
			owner.retry_requested = true
			if owner.retry_delivery_seen == true and candidate.timer == nil then
				return launch_retry()
			end
			return true
		end
		
		show_progress_ui(target_model, "ollama pull " .. repo, i18n.get("ollama.downloading"), cancel_current_pull, do_retry)
		
		if not current_or_cancel() then return false end
		local start_in_progress = true
		local pending_completion = nil
		local pending_chunks = {}
		local function finish_pull(code)
			if owner.completion_seen then return false end
			if deps.active_tasks["ollama_pull"] ~= task then return false end
			owner.completion_seen = true
			owner.completion_dispatching = true
			local authorized = owner.authorized == true
				and owner.start_committed == true
			settle_pull_task()
			local function finish_result(result)
				owner.completion_dispatching = false
				maybe_release_pull_owner()
				return result
			end
			if owner.cancel_requested then
				pcall(notifications.notify, i18n.get("ollama.cancelled_title"),
					i18n.get("ollama.download_cancelled"), "warning")
				complete_progress_ui(false, target_model)
				settle_cancel("user_cancelled")
				return finish_result(false)
			end
			if not authorized then return finish_result(true) end
			if not current_or_cancel() then return finish_result(false) end
			if code == 0 then
				pcall(notifications.notify, i18n.get("ollama.model_installed_title"), string.format(i18n.get("ollama.model_ready"), target_model), "success")
				complete_progress_ui(true, target_model)
				
				-- Pre-load the model in Ollama immediately after pulling without reloading the OS state
				check_model_loadable(target_model, function()
					settle_success()
				end, function()
					settle_success()
				end, opts)
			elseif code == 15 then
				pcall(notifications.notify, i18n.get("ollama.cancelled_title"), i18n.get("ollama.download_cancelled"), "warning")
				complete_progress_ui(false, target_model)
				settle_cancel("terminated")
				return finish_result(false)
			else
				local requires_upgrade = needs_ollama_upgrade(pull_output)
				local connection_error = pull_output:lower():find("could not connect") or pull_output:lower():find("connection refused")
				
				if requires_upgrade then
					pcall(notifications.notify, i18n.get("ollama.upgrade_required_title"),
						i18n.get("ollama.upgrade_required_body"), "warning")
				elseif connection_error then
					pcall(notifications.notify, i18n.get("ollama.fail_title"), i18n.get("ollama.service_disconnected"), "error")
					complete_progress_ui(false, target_model)
				else
					pcall(notifications.notify, i18n.get("ollama.fail_title"), string.format(i18n.get("ollama.download_error"), target_model), "error")
					complete_progress_ui(false, target_model)
				end
				if owner.retry_requested ~= true then
					settle_cancel("process_failed")
				end
				return finish_result(owner.retry_requested == true)
			end
			return finish_result(true)
		end

		local function process_pull_stream(_, stdout, stderr)
			if owner.start_committed ~= true or owner.authorized ~= true
				or owner.completion_seen == true or terminal_sent == true then
				return true
			end
			if not current_or_cancel() then return false end
			local out = sanitize_terminal_stream((stdout or "") .. (stderr or ""))
			pull_output = pull_output .. out
			if out ~= "" then
				-- Extract the last valid line to display
				local last_line = ""
				for line in out:gmatch("([^\n]+)") do
					if line:len() > 0 then last_line = line end
				end
				if last_line ~= "" then update_progress_ui(0, last_line) end
				print("[Ollama Pull] " .. out)
			end
			return true
		end

		task = TaskLifecycle.native("Ollama model pull", bin, function(code)
			-- A native-faithful double can invoke completion from inside :start()
			-- before :start() reports whether launch committed. Buffer that result so
			-- a refused launch cannot publish model state from an unowned callback.
			if start_in_progress then
				if pending_completion == nil then pending_completion = table.pack(code) end
				return true
			end
			return finish_pull(code)
		end, function(...)
			if start_in_progress == true then
				if pending_completion == nil then
					pending_chunks[#pending_chunks + 1] = table.pack(...)
				end
				return true
			end
			return process_pull_stream(...)
		end, {"pull", repo})
		
		if task then
			if not current_or_cancel() then return false end
			deps.active_tasks["ollama_pull"] = task
			owner.task = task
			owner.release_slot = function(exact_task)
				if deps.active_tasks["ollama_pull"] == exact_task then
					deps.active_tasks["ollama_pull"] = nil
				end
			end
			owner.pause_join = function()
				owner.authorized = false
				cancel_current_pull()
				cancel_retry_timer()
				maybe_release_pull_owner()
				return owner.settled == true
			end
			if type(requirement_lifecycle) == "table"
				and type(requirement_lifecycle.adopt) == "function" then
				if requirement_lifecycle.adopt(owner, owner.pause_join,
					"Ollama requirement pull") ~= true then
					owner.authorized = false
					owner.cancel_requested = true
					if requirement_task_proven_not_running(task,
						"Ollama pull adoption refusal") then
						settle_pull_task()
					else
						cancel_current_pull()
					end
					settle_cancel("requirement_owner_adoption_refused")
					return false
				end
				owner.requirement_registered = true
			end
			local started = TaskLifecycle.start(task, "Ollama model pull")
			start_in_progress = false
			if started ~= true then
				owner.authorized = false
				owner.cancel_requested = true
				pending_chunks = {}
				if pending_completion ~= nil then
					pending_completion = nil
					owner.completion_seen = true
					settle_pull_task()
				elseif requirement_task_proven_not_running(task,
					"Ollama pull start refusal") then
					settle_pull_task()
				else
					cancel_current_pull()
				end
				complete_progress_ui(false, target_model)
				settle_cancel("task_start_refused")
				return false
			end
			owner.start_committed = true
			local committed_chunks = pending_chunks
			pending_chunks = {}
			for _, chunk in ipairs(committed_chunks) do
				local keep_streaming = process_pull_stream(
					table.unpack(chunk, 1, chunk.n))
				if keep_streaming == false then
					cancel_current_pull()
					break
				end
			end
			if pending_completion ~= nil then
				return finish_pull(table.unpack(pending_completion, 1, pending_completion.n))
			end
			if not current_or_cancel() then
				cancel_current_pull()
				return false
			end
		else
			complete_progress_ui(false, target_model)
			settle_cancel("task_construction_failed")
			return false
		end
		return true
	end

	function obj.install_ollama_then_pull(target_model, repo, on_success, on_cancel, opts)
		local is_current = type(opts) == "table" and opts.is_current or function() return true end
		local ok_current, current = Logger.callback(LOG,
			"Ollama install freshness check", is_current)
		if not (ok_current == true and current == true) then
			if type(on_cancel) == "function" then
				Logger.callback(LOG, "Stale Ollama install cancellation", on_cancel, "stale")
			end
			return false
		end
		pcall(hs.urlevent.openURL, "https://ollama.com/download")
		pcall(notifications.notify, i18n.get("ollama.not_detected_title"), i18n.get("ollama.not_detected_body"), "warning")
		return false
	end

	--- Verifies if the target model is installed, triggering the download prompt otherwise.
	--- @param target_model string The model to check.
	--- @param on_success function Callback executed when ready.
	--- @param on_cancel function Callback executed when cancelled.
	--- @param opts table|nil Options: `silent_notifications` (boolean) suppresses repair toasts.
	function obj.create_requirement_owner(label)
		return requirement_registry.create_owner(label)
	end

	function obj.pause_requirements(capability)
		return requirement_registry.pause(capability)
	end

	function obj.check_requirements(target_model, on_success, on_cancel, opts)
		local capability = type(opts) == "table" and opts.requirement_owner or nil
		local operation, refusal_reason = requirement_registry.begin(capability)
		if operation == nil then
			if type(on_cancel) == "function" then
				Logger.callback(LOG, "Ollama requirement ownership refusal",
					on_cancel, refusal_reason)
			end
			return false
		end
		local caller_is_current = type(opts) == "table" and opts.is_current
			or function() return true end
		local operation_opts = {}
		if type(opts) == "table" then
			for key, value in pairs(opts) do operation_opts[key] = value end
		end
		operation_opts._requirement_lifecycle = operation.lifecycle
		operation_opts.is_current = function()
			if operation.is_authorized() ~= true then return false end
			local ok, current = Logger.callback(LOG,
				"Ollama caller requirement freshness check", caller_is_current)
			return ok == true and current == true
		end
		opts = operation_opts
		local is_current = operation_opts.is_current
		local function settle(callback, label, ...)
			return operation.finish(callback, label, ...)
		end
		local function settle_cancel(...)
			return settle(on_cancel, "Ollama requirement cancellation", ...)
		end
		local function still_current()
			local ok, current = Logger.callback(LOG,
				"Ollama requirement freshness check", is_current)
			return ok == true and current == true
		end
		local function current_or_cancel()
			if still_current() then return true end
			settle_cancel("stale")
			return false
		end
		local function settle_child_failure(reason, ...)
			if reason == "stale" then return settle_cancel(reason, ...) end
			if not current_or_cancel() then return false end
			return settle_cancel(reason, ...)
		end
		local function settle_success(...)
			if not current_or_cancel() then return false end
			return settle(on_success, "Ollama requirement success", ...)
		end
		if not current_or_cancel() then return false end
		if not target_model or target_model == "" then return settle_success() end
		local silent = type(opts) == "table" and opts.silent_notifications == true
		Logger.debug(LOG, string.format("Checking Ollama requirements for %s…", target_model))
		
		local readiness_accepted = ensure_ollama_running(function()
			if not current_or_cancel() then return false end
			local bin = require_ollama_path("check model requirements")
			if not bin then
				settle_cancel("binary_unavailable")
				return false
			end
			local task_owner = {
				task = nil,
				authorized = true,
				settled = false,
				start_committed = false,
				dispatching = true,
				pending_terminal = nil,
				termination_accepted = false,
				requirement_lifecycle = operation.lifecycle,
				requirement_registered = false,
			}
			local task
			local finish_list_task
			finish_list_task = function(code, stdout)
				if task_owner.settled == true then return false end
				if task_owner.dispatching == true then
					if task_owner.pending_terminal == nil then
						task_owner.pending_terminal = table.pack(code, stdout)
					end
					return true
				end
				local authorized = task_owner.authorized == true
					and task_owner.start_committed == true
					and operation.is_authorized() == true
				release_requirement_task(task_owner)
				if not authorized then return true end
				if not current_or_cancel() then return end
				local installed = {}
				if code == 0 and type(stdout) == "string" then
					for line in stdout:gmatch("[^\r\n]+") do
						local name = line:match("^(%S+)")
						if name and name ~= "NAME" then installed[name] = true end
					end
				end

				local repo = get_ollama_repo(target_model)
				-- Resolve the actual Ollama name (repo may differ from display name, e.g. "gemma-4-E2B-it" vs "gemma4:e2b")
				local actual_model = (repo and repo ~= target_model) and repo or target_model

				if installed[actual_model] or installed[actual_model .. ":latest"] or installed[repo] or installed[repo .. ":latest"] then
					check_model_loadable(actual_model, function()
						settle_success()
					end, function(_, is_load_error)
						if not current_or_cancel() then return end
						if is_load_error and get_ollama_path() then
							if not silent then
								pcall(notifications.notify, i18n.get("ollama.model_repair_title"), string.format(i18n.get("ollama.model_repair"), target_model), "info")
							end
							if not current_or_cancel() then return end
							local accepted = obj.pull_model(target_model, repo,
								settle_success, settle_child_failure, opts)
							if accepted == false then settle_cancel("repair_pull_refused") end
							return
						end
						settle_cancel("model_load_failed")
					end, opts)
				else
					if type(deps.shared_system_check) == "function" then
						local check_ok, accepted = Logger.callback(LOG, "Ollama shared system check",
							deps.shared_system_check, target_model, "Ollama", repo, function()
							if not current_or_cancel() then return false end
							if get_ollama_path() then
								return obj.pull_model(target_model, repo,
									settle_success, settle_child_failure, opts)
							end
							return obj.install_ollama_then_pull(target_model, repo,
								settle_success, settle_child_failure, opts)
						end, settle_cancel, opts)
						if not check_ok or accepted ~= true then
							settle_cancel("system_check_refused")
						end
					else
						if not current_or_cancel() then return end
						local accepted
						if get_ollama_path() then
							accepted = obj.pull_model(target_model, repo,
								settle_success, settle_child_failure, opts)
						else
							accepted = obj.install_ollama_then_pull(target_model, repo,
								settle_success, settle_child_failure, opts)
						end
						if accepted == false then settle_cancel("download_dispatch_refused") end
					end
				end
			end
			task = TaskLifecycle.native("Ollama model requirement check", bin,
				finish_list_task, {"list"})
			task_owner.task = task
			if task then
				if not current_or_cancel() then return false end
				_active_tasks[task] = true
				task_owner.pause_join = function()
					return cancel_requirement_task(task_owner,
						"Ollama model-list requirement")
				end
				if operation.lifecycle.adopt(task_owner, task_owner.pause_join,
					"Ollama model-list requirement") ~= true then
					if requirement_task_proven_not_running(task,
						"Ollama model-list adoption refusal") then
						release_requirement_task(task_owner)
					else
						cancel_requirement_task(task_owner,
							"Ollama model-list adoption refusal")
					end
					settle_cancel("requirement_owner_adoption_refused")
					return false
				end
				task_owner.requirement_registered = true
				local started = TaskLifecycle.start(task,
					"Ollama model requirement check")
				task_owner.dispatching = false
				if started ~= true then
					task_owner.authorized = false
					if task_owner.pending_terminal ~= nil then
						task_owner.pending_terminal = nil
						release_requirement_task(task_owner)
					elseif requirement_task_proven_not_running(task,
						"Ollama model-list start refusal") then
						release_requirement_task(task_owner)
					else
						cancel_requirement_task(task_owner,
							"Ollama model-list start refusal")
					end
					settle_cancel("task_start_refused")
					return false
				end
				task_owner.start_committed = true
				if task_owner.pending_terminal ~= nil then
					local terminal = task_owner.pending_terminal
					task_owner.pending_terminal = nil
					finish_list_task(table.unpack(terminal, 1, terminal.n))
				end
			else
				settle_cancel("task_construction_failed")
				return false
			end
			return true
		end, settle_cancel, opts)
		if readiness_accepted ~= true then
			settle_cancel("readiness_dispatch_refused")
			return false
		end
		return true
	end

	function obj.delete_model(model_name)
		if not model_name or model_name == "" then return false end
		local operation = begin_maintenance("Ollama model deletion")
		if operation == nil then return false end
		Logger.debug(LOG, string.format("Deleting Ollama model %s…", model_name))
		
		local readiness_accepted = ensure_ollama_running(function()
			if operation.is_authorized() ~= true then return false end
			local bin = require_ollama_path("delete a model")
			if not bin then
				pcall(notifications.notify, i18n.get("ollama.delete_fail_title"),
					string.format(i18n.get("ollama.delete_error"), model_name,
						"Ollama executable unavailable"), "error")
				operation.finish(nil, "Ollama deletion executable refusal")
				return false
			end
			local owner = {
				task = nil,
				authorized = true,
				start_committed = false,
				dispatching = true,
				pending_terminal = nil,
				settled = false,
				termination_accepted = false,
				requirement_lifecycle = operation.lifecycle,
				requirement_registered = false,
			}
			local task
			local function finish_delete(code, stdout)
				if owner.settled == true then return false end
				local authorized = owner.authorized == true
					and owner.start_committed == true
					and operation.is_authorized() == true
				release_requirement_task(owner)
				operation.finish(nil, "Ollama model deletion terminal")
				if authorized ~= true then return false end
				if code == 0 then
					pcall(notifications.notify, i18n.get("ollama.deleted_title"), string.format(i18n.get("ollama.model_deleted"), model_name), "success")
					if type(deps.update_menu) == "function" then
						Logger.callback(LOG, "Ollama deletion menu refresh", deps.update_menu)
					end
					Logger.info(LOG, string.format("Ollama model %s deleted successfully.", model_name))
					return true
				end
				pcall(notifications.notify, i18n.get("ollama.delete_fail_title"), string.format(i18n.get("ollama.delete_error"), model_name, tostring(stdout)), "error")
				return false
			end
			task = TaskLifecycle.native("Ollama model delete", bin, function(code, stdout)
				if owner.dispatching then
					if owner.pending_terminal == nil then
						owner.pending_terminal = table.pack(code, stdout)
					end
					return true
				end
				return finish_delete(code, stdout)
			end, {"rm", model_name})
			owner.task = task
			if task then
				_active_tasks[task] = true
				owner.pause_join = function()
					return cancel_requirement_task(owner,
						"Ollama model deletion pause")
				end
				if operation.lifecycle.adopt(owner, owner.pause_join,
					"Ollama model deletion") ~= true then
					owner.authorized = false
					if requirement_task_proven_not_running(task,
						"Ollama deletion adoption refusal") then
						release_requirement_task(owner)
					else
						cancel_requirement_task(owner,
							"Ollama deletion adoption refusal")
					end
					operation.finish(nil, "Ollama deletion adoption refusal")
					return false
				end
				owner.requirement_registered = true
				local start_ok, started = xpcall(function()
					return TaskLifecycle.start(task, "Ollama model delete")
				end, debug.traceback)
				owner.dispatching = false
				if start_ok ~= true or started ~= true then
					if start_ok ~= true then
						Logger.error(LOG,
							"Ollama model deletion start raised; exact task retained: %s.",
							tostring(started))
					end
					owner.authorized = false
					if owner.pending_terminal ~= nil then
						local terminal = owner.pending_terminal
						owner.pending_terminal = nil
						finish_delete(table.unpack(terminal, 1, terminal.n))
					elseif requirement_task_proven_not_running(task,
						"Ollama model deletion start refusal") then
						release_requirement_task(owner)
					else
						cancel_requirement_task(owner,
							"Ollama model deletion start refusal")
					end
					operation.finish(nil, "Ollama model deletion start refusal")
					pcall(notifications.notify, i18n.get("ollama.delete_fail_title"),
						string.format(i18n.get("ollama.delete_error"), model_name,
							"task start failed"), "error")
					return false
				end
				owner.start_committed = true
				if operation.is_authorized() ~= true then
					owner.authorized = false
					cancel_requirement_task(owner,
						"Ollama model deletion post-start fence")
					operation.finish(nil, "Ollama model deletion revoked")
					return false
				end
				if owner.pending_terminal ~= nil then
					local terminal = owner.pending_terminal
					owner.pending_terminal = nil
					return finish_delete(table.unpack(terminal, 1, terminal.n))
				end
				return true
			end
			owner.dispatching = false
			owner.settled = true
			operation.finish(nil, "Ollama model deletion construction refusal")
			pcall(notifications.notify, i18n.get("ollama.delete_fail_title"),
				string.format(i18n.get("ollama.delete_error"), model_name,
					"task creation failed"), "error")
			return false
		end, function(reason)
			local authorized = operation.is_authorized() == true
			operation.finish(nil, "Ollama model deletion readiness refusal")
			if authorized then
				pcall(notifications.notify, i18n.get("ollama.delete_fail_title"),
					string.format(i18n.get("ollama.delete_error"), model_name,
						tostring(reason or "readiness failed")), "error")
			end
			return true
		end, {
			is_current = operation.is_authorized,
			_requirement_lifecycle = operation.lifecycle,
		})
		if readiness_accepted ~= true then
			operation.finish(nil, "Ollama model deletion readiness dispatch refusal")
		end
		return readiness_accepted == true
	end

	return obj
end

return M
