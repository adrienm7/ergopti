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
local notifications = require("lib.notifications")
local Logger        = require("lib.logger")

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
	-- Prefer explicit Homebrew paths to avoid stale app binaries in PATH
	local candidates = {"/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"}
	for _, c in ipairs(candidates) do
		local attr_ok, attr = pcall(hs.fs.attributes, c)
		if attr_ok and attr then return c end
	end

	local ok, p = pcall(hs.execute, "command -v ollama 2>/dev/null")
	if ok and type(p) == "string" and p ~= "" then return p:gsub("%s+", "") end
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
		pcall(download_window.show, title, cancel_cb or cancel_pull_and_upgrade, terminal_cmd, nil, {
			on_retry = retry_cb
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
		local ollama_bin = get_ollama_path()
		if not ollama_bin or ollama_bin == "" then return false end
		
		-- Launch daemon via bash nohup to ensure it survives subprocess termination,
		-- and funnel its output into the unified Ergopti log with an
		-- [OLLAMA-SERVER] prefix (single tail target for the whole stack).
		-- Uses a `while read` loop instead of awk: macOS' default BWK awk
		-- lacks gawk's strftime() / fflush(file) builtins, so the previous
		-- awk pipeline crashed on the first line and killed ollama on SIGPIPE.
		local ok = pcall(hs.execute,
			"nohup bash -c \"" .. ollama_bin .. " serve 2>&1 | " ..
			"while IFS= read -r LINE; do " ..
			"printf '%s [OLLAMA-SERVER] %s\\n' \\\"\\$(date +%H:%M:%S)\\\" \\\"\\$LINE\\\" " ..
			">> /tmp/ergopti.log; " ..
			"done\" &")
		return ok == true
	end

	--- Ensures the Ollama daemon is running, starts it otherwise.
	--- @param on_ready function Callback executed when ready.
	--- @param on_fail function Callback executed when failed.
	local function ensure_ollama_running(on_ready, on_fail)
		local ok, result = pcall(hs.execute, "curl -s http://localhost:11434/api/version 2>/dev/null")
		if ok and result and result:find('"version"') then
			if type(on_ready) == "function" then on_ready() end
			return
		end

		pcall(notifications.notify, "Démarrage Ollama", "Le service Ollama est arrêté. Démarrage en cours…")
		if restart_ollama_daemon() then
			local retries = 0
			local function check_ready()
				retries = retries + 1
				local ok2, result2 = pcall(hs.execute, "curl -s http://localhost:11434/api/version 2>/dev/null")
				if ok2 and result2 and result2:find('"version"') then
					if type(on_ready) == "function" then on_ready() end
				elseif retries < 30 then
					hs.timer.doAfter(0.5, check_ready)
				else
					pcall(notifications.notify, "❌ Échec Ollama", "Impossible de démarrer le service.")
					if type(on_fail) == "function" then on_fail() end
				end
			end
			hs.timer.doAfter(0.5, check_ready)
		else
			pcall(notifications.notify, "❌ Échec Ollama", "Impossible de lancer le démon Ollama.")
			if type(on_fail) == "function" then on_fail() end
		end
	end

	local function wait_for_ollama_api(retries)
		retries = tonumber(retries) or 20
		local done = false
		local success = false

		for i = 1, retries do
			local pct = math.floor((i / retries) * 100)
			update_progress_ui(pct, "Démarrage du service Ollama (" .. i .. "/" .. retries .. ")…")
			
			local ok, result = pcall(hs.execute, "curl -s http://localhost:11434/api/version 2>/dev/null")
			if ok and result and result:find('"version"') then
				success = true
				done = true
				break
			end
			
			if i < retries then
				hs.timer.usleep(200 * 1000)  -- 200ms between attempts
			end
		end

		if success then
			update_progress_ui(100, "Service Ollama prêt ✅")
		end

		return success
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
		local bin = get_ollama_path() or "/usr/local/bin/ollama"
		-- hs.task is non-blocking unlike hs.execute
		local task = hs.task.new(bin, function(code, stdout)
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
		if task then pcall(function() task:start() end) end
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
		local bin = get_ollama_path() or "/usr/local/bin/ollama"
		local pull_output = ""
		
		local function do_retry()
			if deps.active_tasks and deps.active_tasks["ollama_pull"] then return end
			hs.timer.doAfter(0.05, function()
				obj.pull_model(target_model, repo, on_success)
			end)
		end
		
		show_progress_ui(target_model, "ollama pull " .. repo, "Téléchargement Ollama en cours...", cancel_pull_and_upgrade, do_retry)
		
		local task = hs.task.new(bin, function(code)
			if deps.active_tasks then deps.active_tasks["ollama_pull"] = nil end
			if code == 0 then
				pcall(notifications.notify, "🟢 MODÈLE OLLAMA INSTALLÉ", target_model .. " est prêt !")
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
				pcall(deps.save_prefs)
				
				-- Pre-load the model in Ollama immediately after pulling without reloading the OS state
				check_model_loadable(target_model, function()
					if on_success then pcall(on_success) end
				end, function()
					if on_success then pcall(on_success) end
				end)
			elseif code == 15 then
				pcall(notifications.notify, "🛑 Annulé", "Téléchargement Ollama interrompu")
				complete_progress_ui(false, target_model)
			else
				local requires_upgrade = needs_ollama_upgrade(pull_output)
				local connection_error = pull_output:lower():find("could not connect") or pull_output:lower():find("connection refused")
				
				if requires_upgrade then
					pcall(notifications.notify, "⚠️ Mise à jour Ollama requise",
						"La version d’Ollama installée est trop ancienne pour ce modèle. Mettez à jour Ollama manuellement.")
					complete_progress_ui(false, target_model)
				elseif connection_error then
					pcall(notifications.notify, "❌ Échec Ollama", "Le service Ollama a cessé de répondre.")
					complete_progress_ui(false, target_model)
				else
					pcall(notifications.notify, "❌ Échec Ollama", "Erreur lors du téléchargement de " .. target_model)
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
			pcall(function() task:start() end)
		end
	end

	function obj.install_ollama_then_pull(target_model, repo, on_success)
		pcall(hs.urlevent.openURL, "https://ollama.com/download")
		pcall(notifications.notify, "Ollama non détecté", "Veuillez installer Ollama puis réessayer.")
	end

	--- Verifies if the target model is installed, triggering the download prompt otherwise.
	--- @param target_model string The model to check.
	--- @param on_success function Callback executed when ready.
	--- @param on_cancel function Callback executed when cancelled.
	function obj.check_requirements(target_model, on_success, on_cancel)
		if not target_model or target_model == "" then return end
		Logger.debug(LOG, string.format("Checking Ollama requirements for %s…", target_model))
		
		ensure_ollama_running(function()
			-- Force a fresh synchronous check since daemon is confirmed up
			local bin = get_ollama_path() or "/usr/local/bin/ollama"
			local ok, stdout = pcall(hs.execute, bin .. " list 2>/dev/null")
			local installed = {}
			if ok and type(stdout) == "string" then
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
						pcall(notifications.notify, "Réparation du modèle Ollama", "Le modèle semble corrompu. Tentative de re-téléchargement: " .. target_model)
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
		end, on_cancel)
	end

	function obj.delete_model(model_name)
		if not model_name or model_name == "" then return end
		Logger.debug(LOG, string.format("Deleting Ollama model %s…", model_name))
		
		ensure_ollama_running(function()
			local bin = get_ollama_path() or "/usr/local/bin/ollama"
			local ok, output = pcall(hs.execute, bin .. " rm " .. model_name .. " 2>&1")
			
			if ok then
				pcall(notifications.notify, "🗑️ Supprimé (Ollama)", "Modèle supprimé: " .. model_name)
				if deps.update_menu then pcall(deps.update_menu) end
				Logger.info(LOG, string.format("Ollama model %s deleted successfully.", model_name))
			else
				pcall(notifications.notify, "❌ Échec de la suppression Ollama", "Modèle: " .. model_name .. "\n" .. tostring(output))
			end
		end)
	end

	return obj
end

return M
