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
local TaskLifecycle = require("adapters.task_lifecycle")

-- GC-root table: hs.task objects pinned here survive until their callback fires.
local _active_tasks = {}

local LOG = "menu_llm.ollama"

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
		if t and type(t.terminate) == "function" then pcall(function() t:terminate() end) end
	end

	local function cancel_pull_and_upgrade()
		cancel_task("ollama_pull")
		cancel_task("ollama_upgrade")
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

	local function restart_ollama_daemon()
		local ollama_bin = require_ollama_path("restart the daemon")
		if not ollama_bin then return false end
		
		-- Launch daemon via bash nohup to ensure it survives subprocess termination.
		-- The shared foreground pipeline uses a `while read` loop because macOS'
		-- default BWK awk lacks gawk's strftime() / fflush(file) builtins.
		local launch_cmd, command_err = OllamaServerCommand.build(
			ollama_bin, Logger.UNIFIED_LOG_FILE)
		if not launch_cmd then
			Logger.error(LOG, "Could not build Ollama daemon command: %s", tostring(command_err))
			return false
		end
		local detached_cmd = "nohup /bin/bash -c " .. text_utils.shell_quote(launch_cmd)
			.. " </dev/null >/dev/null 2>&1 &"
		local call_ok, _, command_ok = pcall(hs.execute, detached_cmd)
		return call_ok == true and command_ok ~= false
	end

	--- Ensures the Ollama daemon is running, starts it otherwise.
	--- @param on_ready function Callback executed when ready.
	--- @param on_fail function Callback executed when failed.
	local function ensure_ollama_running(on_ready, on_fail)
		local ok, result = pcall(hs.execute, "curl -s --max-time 5 http://localhost:11434/api/version 2>/dev/null")
		if ok and result and result:find('"version"') then
			if type(on_ready) == "function" then on_ready() end
			return
		end

		pcall(notifications.notify, i18n.get("ollama.starting_title"), i18n.get("ollama.service_stopped"), "info")
		if restart_ollama_daemon() then
			local retries = 0
			local function check_ready()
				retries = retries + 1
				local ok2, result2 = pcall(hs.execute, "curl -s --max-time 5 http://localhost:11434/api/version 2>/dev/null")
				if ok2 and result2 and result2:find('"version"') then
					if type(on_ready) == "function" then on_ready() end
				elseif retries < 30 then
					hs.timer.doAfter(0.5, check_ready)
				else
					pcall(notifications.notify, i18n.get("ollama.fail_title"), i18n.get("ollama.start_fail"), "error")
					if type(on_fail) == "function" then on_fail() end
				end
			end
			hs.timer.doAfter(0.5, check_ready)
		else
			pcall(notifications.notify, i18n.get("ollama.fail_title"), i18n.get("ollama.daemon_fail"), "error")
			if type(on_fail) == "function" then on_fail() end
		end
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

	local function check_model_loadable(target_model, on_success, on_fail)
		if type(target_model) ~= "string" or target_model == "" then
			if type(on_fail) == "function" then on_fail("invalid_model", false) end
			return
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
			if type(on_fail) == "function" then on_fail("encode_error", false) end
			return
		end

		hs.http.asyncPost("http://127.0.0.1:11434/api/chat", body, { ["Content-Type"] = "application/json" },
			function(status, resp_body, _)
				if status == 200 then
					if type(on_success) == "function" then on_success() end
					return
				end

				local err_text = type(resp_body) == "string" and resp_body or ""
				local load_error = err_text:find("unable to load model", 1, true) ~= nil
				if type(on_fail) == "function" then on_fail(err_text, load_error) end
			end
		)
	end

	function obj.pull_model(target_model, repo, on_success)
		local bin = require_ollama_path("pull a model")
		if not bin then
			pcall(notifications.notify, i18n.get("ollama.fail_title"),
				string.format(i18n.get("ollama.download_error"), tostring(target_model)), "error")
			return
		end
		local pull_output = ""
		
		local function do_retry()
			if deps.active_tasks and deps.active_tasks["ollama_pull"] then return end
			hs.timer.doAfter(0.05, function()
				obj.pull_model(target_model, repo, on_success)
			end)
		end
		
		show_progress_ui(target_model, "ollama pull " .. repo, i18n.get("ollama.downloading"), cancel_pull_and_upgrade, do_retry)
		
		local task = TaskLifecycle.native("Ollama model pull", bin, function(code)
			if deps.active_tasks then deps.active_tasks["ollama_pull"] = nil end
			if code == 0 then
				pcall(notifications.notify, i18n.get("ollama.model_installed_title"), string.format(i18n.get("ollama.model_ready"), target_model), "success")
				complete_progress_ui(true, target_model)
				-- Resolve the display name from the actual model name (e.g. "gemma3:4b" → "Gemma 3 4B")
				local display_model = target_model
				if type(presets) == "table" then
					local found = false
					for _, provider in ipairs(presets) do
						if found then break end
						for _, family in ipairs(provider.families or {}) do
							if found then break end
							for _, m in ipairs(family.models or {}) do
								local ollama_url = m.urls and m.urls.ollama
								if ollama_url then
									local actual = ollama_url:match("/library/([^/]+)$") or ollama_url:match("([^/]+)$")
									if actual == target_model and m.name then
										display_model = m.name
										found = true
										break
									end
								end
							end
						end
					end
				end
				deps.state.llm_model = display_model
				if deps.keymap then
					if type(deps.keymap.set_llm_model) == "function" then pcall(deps.keymap.set_llm_model, target_model) end
					if type(deps.keymap.set_llm_display_model_name) == "function" then pcall(deps.keymap.set_llm_display_model_name, display_model) end
				end
				if deps.save_prefs() ~= true then return false end
				
				-- Pre-load the model in Ollama immediately after pulling without reloading the OS state
				check_model_loadable(target_model, function()
					if on_success then pcall(on_success) end
				end, function()
					if on_success then pcall(on_success) end
				end)
			elseif code == 15 then
				pcall(notifications.notify, i18n.get("ollama.cancelled_title"), i18n.get("ollama.download_cancelled"), "warning")
				complete_progress_ui(false, target_model)
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
			end
		end, function(_, stdout, stderr)
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
			deps.active_tasks = deps.active_tasks or {}
			deps.active_tasks["ollama_pull"] = task
			if not TaskLifecycle.start(task, "Ollama model pull") then
				deps.active_tasks["ollama_pull"] = nil
				complete_progress_ui(false, target_model)
			end
		else
			complete_progress_ui(false, target_model)
		end
	end

	function obj.install_ollama_then_pull(target_model, repo, on_success)
		pcall(hs.urlevent.openURL, "https://ollama.com/download")
		pcall(notifications.notify, i18n.get("ollama.not_detected_title"), i18n.get("ollama.not_detected_body"), "warning")
	end

	--- Verifies if the target model is installed, triggering the download prompt otherwise.
	--- @param target_model string The model to check.
	--- @param on_success function Callback executed when ready.
	--- @param on_cancel function Callback executed when cancelled.
	--- @param opts table|nil Options: `silent_notifications` (boolean) suppresses repair toasts.
	function obj.check_requirements(target_model, on_success, on_cancel, opts)
		if not target_model or target_model == "" then return end
		local silent = type(opts) == "table" and opts.silent_notifications == true
		Logger.debug(LOG, string.format("Checking Ollama requirements for %s…", target_model))
		
		ensure_ollama_running(function()
			local bin = require_ollama_path("check model requirements")
			if not bin then
				if type(on_cancel) == "function" then on_cancel() end
				return
			end
			local task
				task = TaskLifecycle.native("Ollama model requirement check", bin, function(code, stdout)
				if task then _active_tasks[task] = nil end
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
						if type(on_success) == "function" then on_success() end
					end, function(_, is_load_error)
						if is_load_error and get_ollama_path() then
							if not silent then
								pcall(notifications.notify, i18n.get("ollama.model_repair_title"), string.format(i18n.get("ollama.model_repair"), target_model), "info")
							end
							obj.pull_model(target_model, repo, on_success)
							return
						end
						if type(on_cancel) == "function" then on_cancel() end
					end)
				else
					if type(deps.shared_system_check) == "function" then
						deps.shared_system_check(target_model, "Ollama", repo, function()
							if get_ollama_path() then obj.pull_model(target_model, repo, on_success)
							else obj.install_ollama_then_pull(target_model, repo, on_success) end
						end, on_cancel)
					else
						if get_ollama_path() then obj.pull_model(target_model, repo, on_success)
						else obj.install_ollama_then_pull(target_model, repo, on_success) end
					end
				end
				end, {"list"})
				if task then
					_active_tasks[task] = true
					if not TaskLifecycle.start(task, "Ollama model requirement check") then
						_active_tasks[task] = nil
						if type(on_cancel) == "function" then on_cancel() end
					end
				elseif type(on_cancel) == "function" then
					on_cancel()
				end
		end, on_cancel)
	end

	function obj.delete_model(model_name)
		if not model_name or model_name == "" then return end
		Logger.debug(LOG, string.format("Deleting Ollama model %s…", model_name))
		
		ensure_ollama_running(function()
			local bin = require_ollama_path("delete a model")
			if not bin then
				pcall(notifications.notify, i18n.get("ollama.delete_fail_title"),
					string.format(i18n.get("ollama.delete_error"), model_name,
						"Ollama executable unavailable"), "error")
				return
			end
			local task
				task = TaskLifecycle.native("Ollama model delete", bin, function(code, stdout)
				if task then _active_tasks[task] = nil end
				if code == 0 then
					pcall(notifications.notify, i18n.get("ollama.deleted_title"), string.format(i18n.get("ollama.model_deleted"), model_name), "success")
					if deps.update_menu then pcall(deps.update_menu) end
					Logger.info(LOG, string.format("Ollama model %s deleted successfully.", model_name))
				else
					pcall(notifications.notify, i18n.get("ollama.delete_fail_title"), string.format(i18n.get("ollama.delete_error"), model_name, tostring(stdout)), "error")
				end
				end, {"rm", model_name})
				if task then
					_active_tasks[task] = true
					if not TaskLifecycle.start(task, "Ollama model delete") then
						_active_tasks[task] = nil
						pcall(notifications.notify, i18n.get("ollama.delete_fail_title"),
							string.format(i18n.get("ollama.delete_error"), model_name,
								"task start failed"), "error")
					end
				else
					pcall(notifications.notify, i18n.get("ollama.delete_fail_title"),
						string.format(i18n.get("ollama.delete_error"), model_name,
							"task creation failed"), "error")
				end
		end)
	end

	return obj
end

return M
