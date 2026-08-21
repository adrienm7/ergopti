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
		local waiter = {
			is_current = type(opts) == "table" and opts.is_current or function() return true end,
			on_ready = on_ready,
			on_fail = on_fail,
			terminal_sent = false,
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
		if existing ~= nil and existing.terminal_sent ~= true then
			existing.waiters[#existing.waiters + 1] = waiter
			return true
		end

		local operation = {
			command = nil,
			retry_timer = nil,
			retries = 0,
			restart_requested = false,
			terminal_sent = false,
			waiters = {waiter},
		}
		readiness_operation = operation

		local function owns_operation()
			return readiness_operation == operation and operation.terminal_sent ~= true
		end

		local function cancel_retry_timer()
			local handle = operation.retry_timer
			if not handle then return true end
			local ok, cancelled = Logger.callback(LOG,
				"Ollama readiness retry timer cancellation", TimerScheduler.cancel, handle)
			if ok == true and cancelled == true then
				if operation.retry_timer == handle then operation.retry_timer = nil end
				return true
			end
			Logger.error(LOG, "Ollama readiness retry timer refused cancellation; exact handle retained.")
			return false
		end

		local function release_operation()
			if operation.terminal_sent then return false end
			operation.terminal_sent = true
			if operation.retry_timer ~= nil then cancel_retry_timer() end
			if readiness_operation == operation then readiness_operation = nil end
			return true
		end

		local function settle_operation(ready, reason)
			if not release_operation() then return false end
			local delivered = false
			local all_accepted = true
			local waiters = operation.waiters
			operation.waiters = {}
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
			release_operation()
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
				if operation.command == command then operation.command = nil end
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

			local retry_handle
			local timer_ok, candidate, committed = Logger.callback(LOG,
				"Ollama readiness retry timer", TimerScheduler.after,
				OLLAMA_READINESS_RETRY_DELAY_SEC, function()
					if operation.retry_timer ~= retry_handle then return false end
					operation.retry_timer = nil
					if not retain_current_waiters() then return false end
					operation.retries = operation.retries + 1
					return start_probe(true)
				end)
			if not timer_ok or type(candidate) ~= "table" or committed ~= true then
				if type(candidate) == "table" then
					Logger.callback(LOG, "Ollama refused retry timer cleanup",
						TimerScheduler.cancel, candidate)
				end
				settle_operation(false, "retry_timer_refused")
				return false
			end
			retry_handle = candidate
			operation.retry_timer = retry_handle
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

	--- Refreshes the installed models cache asynchronously (fire-and-forget).
	local function refresh_installed_async()
		if _installed_loading then return end
		_installed_loading = true
		local bin = require_ollama_path("refresh installed models")
		if not bin then
			_installed_loading = false
			return
		end
		-- hs.task is non-blocking unlike hs.execute.
		-- Pinned to _active_tasks so the GC cannot SIGTERM it before the callback
		-- fires and resets _installed_loading — a GC kill would deadlock the lock.
		local task
		task = TaskLifecycle.native("Ollama installed-model refresh", bin, function(code, stdout)
			if task then _active_tasks[task] = nil end  -- task captured by closure; clears the GC-root pin
			_installed_loading = false
			local installed = {}
			if code == 0 and type(stdout) == "string" then
				for line in stdout:gmatch("[^\r\n]+") do
					local name = line:match("^(%S+)")
					if name and name ~= "NAME" then installed[name] = true end
				end
			end
			_installed_cache = installed
			_installed_cache_time = hs.timer.secondsSinceEpoch()
		end, {"list"})
		if task then
			_active_tasks[task] = true
			if not TaskLifecycle.start(task, "Ollama installed-model refresh") then
				_active_tasks[task] = nil
				_installed_loading = false
			end
		else
			_installed_loading = false
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

	--- Pre-warms the installed models cache in the background at startup.
	hs.timer.doAfter(0, function() pcall(refresh_installed_async) end)

	local function check_model_loadable(target_model, on_success, on_fail, opts)
		local is_current = type(opts) == "table" and opts.is_current or function() return true end
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
		hs.http.asyncPost("http://127.0.0.1:11434/api/chat", body, { ["Content-Type"] = "application/json" },
			function(status, resp_body, _)
				if not current_or_cancel() then return end
				if status == 200 then
					settle(on_success, "Ollama model-load success")
					return
				end

				local err_text = type(resp_body) == "string" and resp_body or ""
				local load_error = err_text:find("unable to load model", 1, true) ~= nil
				settle_failure(err_text, load_error)
			end
		)
		return true
	end

	function obj.pull_model(target_model, repo, on_success, on_cancel, opts)
		local is_current = type(opts) == "table" and opts.is_current or function() return true end
		local terminal_sent = false
		local owner = {
			cancel_requested = false,
			completion_seen = false,
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
		local function cancel_current_pull()
			if owner.completion_seen then return false end
			if not task or deps.active_tasks["ollama_pull"] ~= task then return false end
			owner.cancel_requested = true
			if type(task.terminate) ~= "function" then
				Logger.error(LOG, "Ollama pull cancellation refused: terminate() is unavailable.")
				settle_cancel("termination_refused")
				complete_progress_ui(false, target_model)
				return false
			end
			local ok, result = Logger.callback(LOG, "Ollama pull termination", function()
				return task:terminate()
			end)
			if not ok or result == false or result == nil then
				Logger.error(LOG, "Ollama pull cancellation was refused: %s.", tostring(result))
				settle_cancel("termination_refused")
				complete_progress_ui(false, target_model)
				return false
			end
			return true
		end
		
		local function do_retry()
			if not current_or_cancel() then return false end
			if deps.active_tasks and deps.active_tasks["ollama_pull"] then return false end
			hs.timer.doAfter(0.05, function()
				if not current_or_cancel() then return end
				obj.pull_model(target_model, repo, on_success, on_cancel, opts)
			end)
			return true
		end
		
		show_progress_ui(target_model, "ollama pull " .. repo, i18n.get("ollama.downloading"), cancel_current_pull, do_retry)
		
		if not current_or_cancel() then return false end
		local start_in_progress = true
		local pending_completion = nil
		local function finish_pull(code)
			if owner.completion_seen then return false end
			if deps.active_tasks["ollama_pull"] ~= task then return false end
			owner.completion_seen = true
			deps.active_tasks["ollama_pull"] = nil
			if owner.cancel_requested then
				pcall(notifications.notify, i18n.get("ollama.cancelled_title"),
					i18n.get("ollama.download_cancelled"), "warning")
				complete_progress_ui(false, target_model)
				settle_cancel("user_cancelled")
				return false
			end
			if not current_or_cancel() then return false end
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
				return false
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
				settle_cancel("process_failed")
				return false
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
		end, function(_, stdout, stderr)
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
		end, {"pull", repo})
		
		if task then
			if not current_or_cancel() then return false end
			deps.active_tasks["ollama_pull"] = task
			local started = TaskLifecycle.start(task, "Ollama model pull")
			start_in_progress = false
			if not started then
				if deps.active_tasks["ollama_pull"] == task then
					deps.active_tasks["ollama_pull"] = nil
				end
				owner.completion_seen = true
				complete_progress_ui(false, target_model)
				settle_cancel("task_start_refused")
				return false
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
	function obj.check_requirements(target_model, on_success, on_cancel, opts)
		local is_current = type(opts) == "table" and opts.is_current or function() return true end
		local terminal_sent = false
		local function settle(callback, label, ...)
			if terminal_sent then return false end
			terminal_sent = true
			if type(callback) ~= "function" then return true end
			local ok, result = Logger.callback(LOG, label, callback, ...)
			return ok and result ~= false
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
			local task
			task = TaskLifecycle.native("Ollama model requirement check", bin, function(code, stdout)
				if task then _active_tasks[task] = nil end
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
						if not check_ok or accepted == false then
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
			end, {"list"})
			if task then
				if not current_or_cancel() then return false end
				_active_tasks[task] = true
				if not TaskLifecycle.start(task, "Ollama model requirement check") then
					_active_tasks[task] = nil
					settle_cancel("task_start_refused")
					return false
				end
			else
				settle_cancel("task_construction_failed")
				return false
			end
			return true
		end, settle_cancel, opts)
		if readiness_accepted ~= true then
			if not terminal_sent then settle_cancel("readiness_dispatch_refused") end
			return false
		end
		return true
	end

	function obj.delete_model(model_name)
		if not model_name or model_name == "" then return false end
		Logger.debug(LOG, string.format("Deleting Ollama model %s…", model_name))
		
		local readiness_accepted = ensure_ollama_running(function()
			local bin = require_ollama_path("delete a model")
			if not bin then
				pcall(notifications.notify, i18n.get("ollama.delete_fail_title"),
					string.format(i18n.get("ollama.delete_error"), model_name,
						"Ollama executable unavailable"), "error")
				return false
			end
			local task
			local start_in_progress = true
			local pending_completion = nil
			local terminal_sent = false
			local function finish_delete(code, stdout)
				if terminal_sent then return false end
				terminal_sent = true
				if task then _active_tasks[task] = nil end
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
				if start_in_progress then
					if pending_completion == nil then
						pending_completion = table.pack(code, stdout)
					end
					return true
				end
				return finish_delete(code, stdout)
			end, {"rm", model_name})
			if task then
				_active_tasks[task] = true
				local started = TaskLifecycle.start(task, "Ollama model delete")
				start_in_progress = false
				if started ~= true then
					_active_tasks[task] = nil
					terminal_sent = true
					pcall(notifications.notify, i18n.get("ollama.delete_fail_title"),
						string.format(i18n.get("ollama.delete_error"), model_name,
							"task start failed"), "error")
					return false
				end
				if pending_completion ~= nil then
					return finish_delete(table.unpack(pending_completion, 1,
						pending_completion.n))
				end
				return true
			end
			start_in_progress = false
			terminal_sent = true
			pcall(notifications.notify, i18n.get("ollama.delete_fail_title"),
				string.format(i18n.get("ollama.delete_error"), model_name,
					"task creation failed"), "error")
			return false
		end, function(reason)
			pcall(notifications.notify, i18n.get("ollama.delete_fail_title"),
				string.format(i18n.get("ollama.delete_error"), model_name,
					tostring(reason or "readiness failed")), "error")
			return true
		end)
		return readiness_accepted == true
	end

	return obj
end

return M
