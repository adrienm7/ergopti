--- ui/menu/menu_llm/models_manager_mlx.lua

--- ==============================================================================
--- MODULE: MLX Models Manager
--- DESCRIPTION:
--- Handles all MLX specifics, server execution, requirements parsing, and downloads.
---
--- FEATURES & RATIONALE:
--- 1. Subprocess Handling: Spawns the huggingface cli cleanly.
--- 2. File Verification: Safely verifies tensors to guarantee cache integrity.
--- ==============================================================================

local M = {}
local hs            = hs
local notifications = require("lib.notifications")
local ui_builder = require("ui.ui_builder")
local Logger = require("lib.logger")

local LOG = "menu_llm.mlx"

local ok_dw, download_window = pcall(require, "ui.download_window")
if not ok_dw then download_window = nil end

local HF_TOKEN_FILE = (os.getenv("HOME") or "") .. "/.huggingface/token"





-- =========================================
-- =========================================
-- ======= 1/ MLX Engine Core System =======
-- =========================================
-- =========================================

function M.new(deps, presets)
	local obj = {}
	deps.active_tasks = deps.active_tasks or {}
	obj._mlx_upgrade_attempted = {}
	obj._mlx_upgrade_done = false
	obj._mlx_upgrade_failed = false
	obj._mlx_upgrade_in_progress = false
	obj._mlx_upgrade_waiters = {}
	obj._installed_cache = nil
	obj._installed_cache_ts = 0

	local module_source = debug.getinfo(1, "S").source:sub(2)
	local project_root = module_source:match("^(.*)/static/drivers/hammerspoon/ui/menu/menu_llm/models_manager_mlx%.lua$")
	local function first_existing_path(candidates)
		for _, candidate in ipairs(candidates) do
			if type(candidate) == "string" and candidate ~= "" and hs.fs.attributes(candidate, "mode") then
				return candidate
			end
		end
		return ""
	end
	local project_venv_python = first_existing_path({
		(project_root and (project_root .. "/.venv/bin/python3")) or "",
		(os.getenv("HOME") or "") .. "/Documents/perso/ergopti/.venv/bin/python3",
	})
	local project_venv_python_escaped = project_venv_python:gsub("\\", "\\\\"):gsub("\"", "\\\"")

	local function shell_escape_single(value)
		value = type(value) == "string" and value or ""
		return "'" .. value:gsub("'", "'\\''") .. "'"
	end

	local function find_model_entry(model_name)
		if type(model_name) ~= "string" or model_name == "" then return nil end
		for _, provider in ipairs(presets) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					if type(m) == "table" and m.name == model_name then
						return m
					end
				end
			end
		end
		return nil
	end

	local function read_hf_token()
		local fh = io.open(HF_TOKEN_FILE, "r")
		if not fh then return nil end
		local raw = fh:read("*a")
		fh:close()
		local token = raw and raw:match("^%s*(.-)%s*$") or ""
		return token ~= "" and token or nil
	end

	local function upgrade_mlx_stack(on_done)
		if type(on_done) == "function" then
			table.insert(obj._mlx_upgrade_waiters, on_done)
		end

		if obj._mlx_upgrade_done then
			local waiters = obj._mlx_upgrade_waiters
			obj._mlx_upgrade_waiters = {}
			for _, cb in ipairs(waiters) do pcall(cb, true) end
			return
		end

		if obj._mlx_upgrade_in_progress then return end
		obj._mlx_upgrade_in_progress = true

		local py_detect =
			"PYTHON_BIN=\"python3\"; " ..
			"if [ -n \"$VIRTUAL_ENV\" ] && [ -x \"$VIRTUAL_ENV/bin/python3\" ]; then PYTHON_BIN=\"$VIRTUAL_ENV/bin/python3\"; " ..
			"elif [ -x \"" .. project_venv_python_escaped .. "\" ]; then PYTHON_BIN=\"" .. project_venv_python_escaped .. "\"; fi; " ..
			"if [ \"$PYTHON_BIN\" = \"python3\" ]; then MLX_VENV=\"$HOME/.mlx_py_env\"; python3 -m venv \"$MLX_VENV\" >/dev/null 2>&1 || true; [ -x \"$MLX_VENV/bin/python3\" ] && PYTHON_BIN=\"$MLX_VENV/bin/python3\"; fi; "

		local dry_run_cmd = py_detect .. "$PYTHON_BIN -u -m pip install --disable-pip-version-check --dry-run --upgrade mlx-lm huggingface_hub hf_transfer truststore"
		local upgrade_cmd = py_detect .. "$PYTHON_BIN -u -m pip install --disable-pip-version-check --upgrade mlx-lm huggingface_hub hf_transfer truststore"

		local function finish_upgrade(ok)
			if ok then
				obj._mlx_upgrade_done = true
				obj._mlx_upgrade_failed = false
			else
				obj._mlx_upgrade_failed = true
			end
			obj._mlx_upgrade_in_progress = false
			if deps.active_tasks then deps.active_tasks["mlx_upgrade"] = nil end
			local waiters = obj._mlx_upgrade_waiters
			obj._mlx_upgrade_waiters = {}
			for _, cb in ipairs(waiters) do pcall(cb, ok) end
		end

		local function cancel_upgrade()
			local t = deps.active_tasks and deps.active_tasks["mlx_upgrade"]
			if t and type(t.terminate) == "function" then pcall(function() t:terminate() end) end
		end

		local function start_real_upgrade()
			local upgrade_task = hs.task.new("/bin/bash", function(ucode)
				if ucode == 0 then
					finish_upgrade(true)
				elseif ucode == 15 then
					finish_upgrade(false)
				else
					finish_upgrade(false)
				end
			end, function(_, stdout, stderr)
				local out = (stdout or "") .. (stderr or "")
				if out ~= "" then print("[MLX Upgrade] " .. out) end
				return true
			end, { "-c", upgrade_cmd })

			if upgrade_task then
				deps.active_tasks["mlx_upgrade"] = upgrade_task
				pcall(function() upgrade_task:start() end)
			else
				finish_upgrade(false)
			end
		end

		local dry_run_out = ""
		local dry_run_task = hs.task.new("/bin/bash", function(code)
			local has_updates = dry_run_out:find("Would install", 1, true) ~= nil
			local dry_run_unsupported = dry_run_out:lower():find("no such option: --dry%-run") ~= nil

			if has_updates then
				start_real_upgrade()
				return
			end

			if code == 0 then
				finish_upgrade(true)
				return
			end

			if dry_run_unsupported then
				start_real_upgrade()
				return
			end

			finish_upgrade(false)
		end, function(_, stdout, stderr)
			dry_run_out = dry_run_out .. (stdout or "") .. (stderr or "")
			return true
		end, { "-c", dry_run_cmd })

		if dry_run_task then
			deps.active_tasks["mlx_upgrade"] = dry_run_task
			pcall(function() dry_run_task:start() end)
		else
			finish_upgrade(false)
		end
	end

	function obj.get_mlx_repo(model_name)
		for _, provider in ipairs(presets) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					if m.name == model_name and m.urls and m.urls.mlx then
						return m.urls.mlx:gsub("^https?://huggingface%.co/", "")
					end
				end
			end
		end
		return nil
	end

	function obj.open_model_source_page(model_name)
		local repo = obj.get_mlx_repo(model_name)
		if type(repo) ~= "string" or repo == "" then
			pcall(notifications.notify, "Source introuvable", "Aucun dépôt MLX trouvé pour ce modèle")
			return false
		end

		local url = "https://huggingface.co/" .. repo
		local ok_open = pcall(hs.urlevent.openURL, url)
		if not ok_open then
			pcall(notifications.notify, "Ouverture impossible", "Impossible d’ouvrir la page HuggingFace")
			return false
		end

		pcall(notifications.notify, "🌐 HuggingFace", "Page du modèle ouverte dans votre navigateur")
		return true
	end

	function obj.prompt_hf_login(on_done)
		hs.timer.doAfter(0.05, function()
			local hs_app = hs.application and hs.application.get and hs.application.get("Hammerspoon") or nil
			if not hs_app and hs.application and hs.application.find then
				hs_app = hs.application.find("Hammerspoon")
			end
			if hs_app and type(hs_app.activate) == "function" then
				pcall(function() hs_app:activate(true) end)
			end

			local hf_token_url = "https://huggingface.co/settings/tokens"
			
			local clipboard_token_raw = hs.pasteboard and hs.pasteboard.getContents and hs.pasteboard.getContents() or ""
			local clipboard_token = type(clipboard_token_raw) == "string" and clipboard_token_raw:match("^%s*(.-)%s*$") or ""
			local token_seed = clipboard_token:match("^hf_[%w_%-]+$") and clipboard_token or ""
			
			if token_seed == "" then
				token_seed = read_hf_token() or ""
			end

			local _token_wv = nil
			local _src = debug.getinfo(1, "S").source:sub(2)
			local ASSETS_DIR = _src:match("^(.*[/\\])") or "./"
			
			local _ucc = hs.webview.usercontent.new("token_bridge")
			_ucc:setCallback(function(msg)
				if type(msg) ~= "table" then return end
				
				if msg.body == "open_link" then
					pcall(hs.urlevent.openURL, hf_token_url)
					
				elseif msg.body == "cancel" then
					if _token_wv then pcall(function() _token_wv:delete() end) end
					_token_wv = nil
					if type(on_done) == "function" then pcall(on_done, false) end
					
				elseif type(msg.body) == "table" and msg.body.type == "validate" then
					local token = type(msg.body.token) == "string" and msg.body.token:match("^%s*(.-)%s*$") or ""
					if _token_wv then pcall(function() _token_wv:delete() end) end
					_token_wv = nil
					
					if token == "" and token_seed ~= "" then
						token = token_seed
						pcall(notifications.notify, "✅ Token détecté", "Token récupéré depuis le presse-papiers")
					elseif token ~= "" and token_seed ~= "" and #token_seed > #token and token_seed:sub(-#token) == token then
						token = token_seed
						pcall(notifications.notify, "✅ Token corrigé", "Le token du presse-papiers complet a été utilisé")
					end
					
					if token == "" then
						pcall(notifications.notify, "Token manquant", "Aucun token fourni")
						if type(on_done) == "function" then pcall(on_done, false) end
						return
					end
					
					obj._process_hf_token(token, on_done)
				end
			end)

			local screen = hs.screen.mainScreen()
			local f = screen and type(screen.frame) == "function" and screen:frame() or {x=0, y=0, w=1920, h=1080}
			
			local W, H = 520, 400
			local frame = {
				x = math.floor(f.x + (f.w - W) / 2),
				y = math.floor(f.y + (f.h - H) / 2),
				w = W,
				h = H
			}

			_token_wv = ui_builder.show_webview({
				frame             = frame,
				title             = "Connexion HuggingFace",
				style_masks       = {"titled", "closable", "nonactivating"},
				level             = hs.drawing.windowLevels.floating,
				allow_text_entry  = true,
				allow_gestures    = false,
				allow_new_windows = false,
				usercontent       = _ucc,
				assets_dir        = ASSETS_DIR .. "../../token_prompt/",
				on_close          = function()
					_token_wv = nil
					if type(on_done) == "function" then pcall(on_done, false) end
				end
			})
		end)
	end

	function obj._process_hf_token(token, on_done)
		local escaped_token = token:gsub('\\', '\\\\'):gsub('"', '\\"')
		
		local login_script = [[
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
python3 -u - <<'PY'
import sys
import os
import warnings
import pathlib

warnings.filterwarnings('ignore')
os.environ['PYTHONWARNINGS'] = 'ignore'

token = "]] .. escaped_token .. [["

if not token or len(token.strip()) == 0:
    print("Erreur: Token vide", file=sys.stderr)
    sys.exit(1)

try:
    import urllib.request
    import ssl

    ctx = ssl.create_default_context()
    req = urllib.request.Request(
        'https://huggingface.co/api/whoami-v2',
        headers={
            'User-Agent': 'huggingface/hub',
            'Authorization': f'Bearer {token.strip()}'
        }
    )
    try:
        resp = urllib.request.urlopen(req, timeout=10, context=ctx)
        status = resp.status
    except urllib.error.HTTPError as http_err:
        status = http_err.code

    if status != 200:
        print(f"Token validation failed: HTTP {status}", file=sys.stderr)
        sys.exit(1)
    
    home = os.path.expanduser("~")
    hf_dir = pathlib.Path(home) / ".huggingface"
    hf_dir.mkdir(parents=True, exist_ok=True)
    
    token_file = hf_dir / "token"
    token_file.write_text(token.strip(), encoding='utf-8')
    
    os.chmod(str(token_file), 0o600)
    
    print(f"Token saved to {token_file}", file=sys.stderr)
    
    try:
        import subprocess
        process = subprocess.Popen(
            ['git', 'credential-osxkeychain', 'store'],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        
        credential_input = f"protocol=https\nhost=huggingface.co\nusername=oauth2config\npassword={token.strip()}\n"
        process.communicate(input=credential_input, timeout=5)
    except Exception as e:
        print(f"Note: Git credential save skipped: {e}", file=sys.stderr)
    
    print("Connexion HuggingFace réussie")
    sys.exit(0)

except Exception as e:
    print(f"Erreur HuggingFace: {str(e)}", file=sys.stderr)
    sys.exit(1)
PY
		]]

		local task = hs.task.new("/bin/bash", function(code)
			if deps.active_tasks then deps.active_tasks["hf_login"] = nil end

			if code == 0 then
				pcall(notifications.notify, "🔓 HuggingFace connecté", "Token sauvegardé. Vous pouvez maintenant télécharger les modèles beaucoup plus rapidement !")
				if type(on_done) == "function" then pcall(on_done, true) end
			else
				pcall(notifications.notify, "❌ Connexion HuggingFace", "Échec de connexion. Vérifiez votre token.")
				if type(on_done) == "function" then pcall(on_done, false) end
			end
		end, function(_, stdout, stderr)
			local out = (stdout or "") .. (stderr or "")
			if out ~= "" then
				print("[HF Login] " .. out)
			end
			return true
		end, { "-c", login_script })

		if task then
			deps.active_tasks["hf_login"] = task
			pcall(function() task:start() end)
		else
			pcall(notifications.notify, "Erreur", "Impossible de lancer la connexion HuggingFace")
			if type(on_done) == "function" then pcall(on_done, false) end
		end
	end

	function obj.get_installed_models()
		local now = hs.timer.secondsSinceEpoch()
		if type(obj._installed_cache) == "table" and (now - (obj._installed_cache_ts or 0)) < 1.0 then
			return obj._installed_cache
		end

		local installed = {}
		local home = os.getenv("HOME")
		local hub_dir = home .. "/.cache/huggingface/hub/"
		Logger.debug(LOG, "Scanning MLX installed models cache…")
		for _, provider in ipairs(presets) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					if m.urls and m.urls.mlx then
						local raw_repo = m.urls.mlx:gsub("^https?://huggingface%.co/", "")
						local safe_repo = "models--" .. raw_repo:gsub("/", "--")
						local snapshots_dir = hub_dir .. safe_repo .. "/snapshots"
						local attr = hs.fs.attributes(snapshots_dir)
						if attr and attr.mode == "directory" then
							local is_valid = false
							for commit in hs.fs.dir(snapshots_dir) do
								if commit ~= "." and commit ~= ".." then
									local commit_dir = snapshots_dir .. "/" .. commit
									local attr_c = hs.fs.attributes(commit_dir)
									if attr_c and attr_c.mode == "directory" then
										for file in hs.fs.dir(commit_dir) do
											if file:match("%.safetensors$") or file:match("%.bin$") then
												local file_path = commit_dir .. "/" .. file
												local fattr = hs.fs.attributes(file_path)

												-- Hugging Face snapshots often expose large tensor weights as symlinks.
												-- Accept symlinked weights as valid to avoid false negatives at startup.
												if fattr and (fattr.mode == "link" or (fattr.size and fattr.size > 10000)) then
													is_valid = true
													break
												end
											end
										end
									end
								end
								if is_valid then break end
							end
							if is_valid then
								installed[m.name] = true
								Logger.debug(LOG, "MLX model detected in cache: %s", tostring(m.name))
							end
						end
					end
				end
			end
		end
		local count = 0
		for _ in pairs(installed) do count = count + 1 end
		obj._installed_cache = installed
		obj._installed_cache_ts = now
		Logger.debug(LOG, "MLX installed models scan complete: %d model(s).", count)
		return installed
	end

	function obj.start_server(target_model, on_success, opts)
		local repo = obj.get_mlx_repo(target_model)
		if not repo then
			Logger.warn(LOG, "Cannot start MLX server: no repository found for model %s.", tostring(target_model))
			return
		end
		Logger.info(LOG, "Ensuring MLX server for model %s…", tostring(target_model))
		local silent_notifications = type(opts) == "table" and opts.silent_notifications == true

		local function probe_matches_target(body)
			if type(body) ~= "string" or body == "" then return false end
			local ok, parsed = pcall(hs.json.decode, body)
			if not ok or type(parsed) ~= "table" then return false end

			local target_l = (target_model or ""):lower()
			local repo_l = (repo or ""):lower()

			local models = parsed.data
			if type(models) ~= "table" then return false end
			for _, item in ipairs(models) do
				if type(item) == "table" and type(item.id) == "string" then
					local id_l = item.id:lower()
					if id_l:find(target_l, 1, true) or id_l:find(repo_l, 1, true) then
						return true
					end
				end
			end
			return false
		end

		if deps.active_tasks and deps.active_tasks["mlx_server"] then
			local existing = deps.active_tasks["mlx_server"]
			local running = type(existing.isRunning) == "function" and existing:isRunning()
			if running and obj._server_target == target_model then
				if on_success then pcall(on_success) end
				return
			end
			if running then pcall(function() existing:terminate() end) end
			deps.active_tasks["mlx_server"] = nil
		end

		hs.http.asyncGet("http://127.0.0.1:8080/v1/models", {}, function(probe_status, body)
			if probe_status == 200 and probe_matches_target(body) then
				obj._server_target = target_model
				Logger.info(LOG, "MLX server already ready for model %s.", tostring(target_model))
				if on_success then pcall(on_success) end
				return
			end

			obj._server_target = target_model
			Logger.info(LOG, "Starting MLX server process for model %s…", tostring(target_model))

			local server_log_file = "/tmp/hs_mlx_server_" .. tostring(math.random(1000,9999)) .. ".log"
			local startup_confirmed = false
			local startup_closed = false

			local function mark_server_ready()
				if startup_confirmed or startup_closed then return end
				startup_confirmed = true
				if on_success then pcall(on_success) on_success = nil end
			end

			local function probe_server_ready(retries)
				if startup_closed or startup_confirmed then return end
				if retries <= 0 then return end
				hs.http.asyncGet("http://127.0.0.1:8080/v1/models", {}, function(status, body_retry)
					if startup_closed or startup_confirmed then return end
					if status == 200 and probe_matches_target(body_retry) then
						mark_server_ready()
					else
						hs.timer.doAfter(0.5, function()
							probe_server_ready(retries - 1)
						end)
					end
				end)
			end

			local bash_cmd =
				"set -o pipefail; " ..
				"export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; " ..
				"export SSL_CERT_FILE=/etc/ssl/cert.pem; " ..
				"export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem; " ..
				"export HF_HUB_DISABLE_XET=1; " ..
				"export PYTHONUNBUFFERED=1; " ..
				"PYTHON_BIN=\"python3\"; " ..
				"if [ -n \"$VIRTUAL_ENV\" ] && [ -x \"$VIRTUAL_ENV/bin/python3\" ]; then PYTHON_BIN=\"$VIRTUAL_ENV/bin/python3\"; " ..
				"elif [ -x \"" .. project_venv_python_escaped .. "\" ]; then PYTHON_BIN=\"" .. project_venv_python_escaped .. "\"; fi; " ..
				"if [ \"$PYTHON_BIN\" = \"python3\" ]; then MLX_VENV=\"$HOME/.mlx_py_env\"; [ -x \"$MLX_VENV/bin/python3\" ] && PYTHON_BIN=\"$MLX_VENV/bin/python3\"; fi; " ..
				"echo \"[MLX] Python utilisé: $PYTHON_BIN\"; " ..
				"pids=$(lsof -tiTCP:8080 -sTCP:LISTEN 2>/dev/null); [ -n \"$pids\" ] && kill -9 $pids 2>/dev/null; sleep 0.3; " ..
				"$PYTHON_BIN -m mlx_lm server --model " .. repo .. " 2>&1 | tee \"" .. server_log_file .. "\""

			local server_last_line = ""
			local server_log_buffer = {}
			local task = hs.task.new("/bin/bash", function(code)
				startup_closed = true
				if deps.active_tasks and deps.active_tasks["mlx_server"] == task then
					deps.active_tasks["mlx_server"] = nil
				end
				if obj._server_target == target_model then obj._server_target = nil end

				if code == 15 then
					print("MLX server exited with code " .. code)
					return
				end

				if code == 0 and not startup_confirmed then
					-- Process exited cleanly before signalling readiness — this is unexpected
					Logger.error(LOG, "MLX server for model ‘%s’ exited before readiness (code 0).", tostring(target_model))
					return
				end

				if code ~= 0 then
					local error_msg = ""
					for _, line in ipairs(server_log_buffer) do
						if line:lower():match("error") or line:match("Traceback") or line:match("Exception") or
						   line:match("CUDA") or line:match("RuntimeError") or line:match("ModuleNotFoundError") then
							error_msg = line
							break
						end
					end
					if error_msg == "" and #server_log_buffer > 0 then
						error_msg = server_log_buffer[#server_log_buffer]
					end

					if error_msg == "" then
						local ok_fh, fh = pcall(io.open, server_log_file, "r")
						if ok_fh and fh then
							local raw = fh:read("*a") or ""
							pcall(function() fh:close() end)
							for line in raw:gmatch("([^\n\r]+)") do
								if line:match("%S") then
									if line:lower():match("error") or line:match("Traceback") or line:match("Exception") or
									   line:match("CUDA") or line:match("RuntimeError") or line:match("ModuleNotFoundError") then
										error_msg = line
										break
									end
									error_msg = line
								end
							end
						end
					end

					if error_msg ~= "" then
						Logger.error(LOG, "MLX server for model ‘%s’ crashed (code %d): %s", tostring(target_model), code, error_msg)
					else
						Logger.error(LOG, "MLX server for model ‘%s’ crashed (code %d).", tostring(target_model), code)
					end
				end

				Logger.info(LOG, "MLX server process exited with code %d.", code)
			end, function(_, stdout, stderr)
				local out = (stdout or "") .. (stderr or "")
				for line in out:gmatch("([^\n\r]+)") do
					server_last_line = line
					table.insert(server_log_buffer, line)
					while #server_log_buffer > 15 do table.remove(server_log_buffer, 1) end
				end
				if out:find("Starting httpd at") or out:find("Uvicorn running on") or out:find("Application startup complete") then
					mark_server_ready()
				end
				return true
			end, { "-c", bash_cmd })

			if task then
				deps.active_tasks["mlx_server"] = task
				pcall(function() task:start() end)
				probe_server_ready(40)
			else
				Logger.error(LOG, "Failed to create hs.task for MLX server — model ‘%s’ cannot start.", tostring(target_model))
			end
		end)
	end





	-- =====================================
	-- =====================================
	-- ======= 2/ Dependency Parsing =======
	-- =====================================
	-- =====================================

	function obj.pull_model(target_model, repo, on_success)
		local function _internal_pull()
			-- Upvalues shared between closures so do_cancel/tail can coordinate
			local _dl_pid    = nil
			local _tail_task = nil
			local _rand_id   = tostring(math.random(1000, 9999))
			local _log_path  = "/tmp/hs_mlx_dl_" .. _rand_id .. ".log"
			local _exit_path = _log_path .. ".exit"

			-- silent=true suppresses the "Annulé" notification and complete() so callers that
			-- already handle their own UI (do_retry, check_timeout) don't double-notify
			local function do_cancel(silent)
				if _tail_task then
					pcall(function() _tail_task:terminate() end)
					_tail_task = nil
				end
				if _dl_pid then
					-- Kill the detached Python process directly — hs.task:terminate() would not reach
					-- it because Python called os.setpgrp() to escape Hammerspoon's process group
					os.execute("kill -TERM " .. tostring(_dl_pid) .. " 2>/dev/null")
					_dl_pid = nil
				end
				if deps.active_tasks then
					deps.active_tasks["download"]      = nil
					deps.active_tasks["download_tail"] = nil
				end
				-- Always reset the menubar % — the poll/handle_done path won't run after a cancel
				pcall(deps.update_icon)
				os.execute("rm -f /tmp/hs_mlx_active_download.json 2>/dev/null")
				if not silent then
					pcall(notifications.notify, "🛑 Annulé", "Téléchargement de " .. target_model .. " interrompu.")
					if download_window then pcall(download_window.complete, false, target_model) end
				end
			end

			local function do_retry()
				-- Pass silent=true: do_retry manages its own lifecycle, no cancel notification needed
				do_cancel(true)
				hs.timer.doAfter(0.05, function()
					obj.pull_model(target_model, repo, on_success)
				end)
			end

			local function do_resolve_gated()
				if type(obj.prompt_hf_login) == "function" then
					hs.timer.doAfter(0.08, function()
						obj.prompt_hf_login(function(ok)
							if ok and type(do_retry) == "function" then
								hs.timer.doAfter(0.3, do_retry)
							end
						end)
					end)
				end
			end

			local estimated_bytes_total = 0
			local m_table = nil
			
			for _, provider in ipairs(presets) do
				for _, family in ipairs(provider.families or {}) do
					for _, m in ipairs(family.models or {}) do
						if m.name == target_model then
							m_table = m
							local hw = m.hardware_requirements and m.hardware_requirements.mlx or {}
							if type(hw.download_gb) == "number" then
								estimated_bytes_total = math.floor(hw.download_gb * 1e9)
							elseif type(hw.ram_gb) == "number" then
								estimated_bytes_total = math.floor(hw.ram_gb * 0.14 * 1e9)
							end
							break
						end
					end
				end
			end

			local ui_sizes = nil
			if m_table then
				local hw = m_table.hardware_requirements and m_table.hardware_requirements.mlx or {}
				ui_sizes = {
					dl     = hw.download_gb and (hw.download_gb .. " Go"),
					params = m_table.parameters and m_table.parameters.total
				}
			end

			local clean_repo = repo:gsub("[%c%s]", "")
			local script_path = "/tmp/hs_mlx_dl_" .. _rand_id .. ".sh"
			local py_path     = "/tmp/hs_mlx_dl_" .. _rand_id .. ".py"
			local script_project_venv_python_escaped = project_venv_python_escaped
			local safe_repo_bash = "models--" .. clean_repo:gsub("/", "--")

			-- Write the Python downloader to a real file so it is fully independent of any pipe or
			-- heredoc — a detached process cannot read from stdin after the shell exits anyway
			local py = io.open(py_path, "w")
			if not py then
				pcall(notifications.notify, "Erreur", "Écriture du script Python impossible dans /tmp")
				return
			end
			py:write("import sys, os, threading, atexit\n")
			-- Escape Hammerspoon's NSTask process group so hs.task:terminate() / HS reload
			-- cannot deliver SIGTERM to this process
			py:write("os.setpgrp()\n")
			py:write("_exit_path = " .. string.format("%q", _exit_path) .. "\n")
			py:write("def _write_exit(code):\n")
			py:write("    try:\n")
			py:write("        open(_exit_path, 'w').write(str(code))\n")
			py:write("    except Exception: pass\n")
			py:write("atexit.register(_write_exit, 1)\n")
			py:write("try:\n")
			py:write("    import truststore; truststore.inject_into_ssl()\n")
			py:write("except Exception: pass\n")
			py:write("try:\n")
			py:write("    from huggingface_hub import snapshot_download\n")
			py:write("except Exception:\n")
			py:write("    print('--- ERREUR DEPENDANCES ---', flush=True)\n")
			py:write("    import traceback; traceback.print_exc()\n")
			py:write("    _write_exit(1); sys.exit(1)\n")
			py:write("_hub_dir = os.path.expanduser('~/.cache/huggingface/hub')\n")
			py:write("_model_cache = os.path.join(_hub_dir, " .. string.format("%q", safe_repo_bash) .. ")\n")
			-- Snapshot existing blobs before the download starts so the watcher only counts NEW ones.
			-- This prevents pre-cached or previously-downloaded blobs from inflating the counter.
			py:write("_WEIGHT_EXTS = ('.safetensors', '.bin', '.gguf')\n")
			py:write("_blobs_dir = os.path.join(_model_cache, 'blobs')\n")
			py:write("_initial_blobs = set()\n")
			py:write("if os.path.isdir(_blobs_dir):\n")
			py:write("    for _fn in os.listdir(_blobs_dir):\n")
			py:write("        if not _fn.endswith('.lock'):\n")
			py:write("            _fp = os.path.join(_blobs_dir, _fn)\n")
			py:write("            if not os.path.islink(_fp):\n")
			py:write("                try:\n")
			py:write("                    if os.path.getsize(_fp) > 0: _initial_blobs.add(_fn)\n")
			py:write("                except: pass\n")
			py:write("_stop_evt = threading.Event()\n")
			py:write("def _size_watcher():\n")
			py:write("    while True:\n")
			py:write("        try:\n")
			py:write("            _total = 0\n")
			py:write("            for _dp, _, _fns in os.walk(_model_cache, followlinks=False):\n")
			py:write("                for _fn in _fns:\n")
			py:write("                    _fp = os.path.join(_dp, _fn)\n")
			py:write("                    if not os.path.islink(_fp):\n")
			py:write("                        try: _total += os.path.getsize(_fp)\n")
			py:write("                        except: pass\n")
			py:write("            print('__BYTES__:' + str(_total), flush=True)\n")
			-- Count only NEW blobs (not in _initial_blobs): completed files + in-progress temp files
			-- (size > 0). +1 gives the 1-based index of the file currently being downloaded.
			py:write("            _done_blobs = 0\n")
			py:write("            if os.path.isdir(_blobs_dir):\n")
			py:write("                for _fn in os.listdir(_blobs_dir):\n")
			py:write("                    if not _fn.endswith('.lock') and _fn not in _initial_blobs:\n")
			py:write("                        _fp = os.path.join(_blobs_dir, _fn)\n")
			py:write("                        if not os.path.islink(_fp):\n")
			py:write("                            try:\n")
			py:write("                                if os.path.getsize(_fp) > 0: _done_blobs += 1\n")
			py:write("                            except: pass\n")
			py:write("            print('__FILECOUNT__:' + str(_done_blobs + 1), flush=True)\n")
			py:write("        except Exception as _e:\n")
			py:write("            print('__BYTES__:ERROR:' + str(_e), flush=True)\n")
			py:write("        if _stop_evt.wait(2): break\n")
			py:write("_watcher = threading.Thread(target=_size_watcher, daemon=True)\n")
			py:write("_watcher.start()\n")
			py:write("try:\n")
			py:write("    snapshot_download(" .. string.format("%q", clean_repo) .. ", max_workers=8)\n")
			py:write("except Exception as e:\n")
			py:write("    err_str = str(e).lower()\n")
			py:write("    if '401' in err_str or '403' in err_str or 'gated' in err_str or 'unauthorized' in err_str:\n")
			py:write("        print('\\n\\u274c ERREUR : Ce mod\\u00e8le est PRIV\\u00c9 (Gated) par son cr\\u00e9ateur.', flush=True)\n")
			py:write("        print('Pour le t\\u00e9l\\u00e9charger, vous devez :', flush=True)\n")
			py:write("        print('1. Cr\\u00e9er un compte sur HuggingFace.co et accepter les conditions du mod\\u00e8le.', flush=True)\n")
			py:write("        print('2. Dans le menu LLM, utilisez le bouton : \\U0001f511 Connexion HuggingFace.', flush=True)\n")
			py:write("        print('   Option manuelle: huggingface-cli login', flush=True)\n")
			py:write("    else:\n")
			py:write("        print('\\n--- ERREUR HUGGINGFACE ---', flush=True)\n")
			py:write("        import traceback; traceback.print_exc()\n")
			py:write("    _stop_evt.set()\n")
			py:write("    _write_exit(1); sys.exit(1)\n")
			py:write("_stop_evt.set()\n")
			py:write("print('Termin\\u00e9 !', flush=True)\n")
			py:write("_write_exit(0)\n")
			py:write("atexit.unregister(_write_exit)\n")
			py:close()

			-- Write the launcher: resolves Python binary, installs deps, cleans stale cache,
			-- then starts Python detached via nohup (shields SIGHUP) and reports its PID
			local f = io.open(script_path, "w")
			if not f then
				pcall(notifications.notify, "Erreur", "Écriture du script Bash impossible dans /tmp")
				return
			end
			f:write("#!/bin/bash\n")
			f:write("export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\n")
			f:write("PYTHON_BIN=\"python3\"\n")
			f:write("if [ -n \"$VIRTUAL_ENV\" ] && [ -x \"$VIRTUAL_ENV/bin/python3\" ]; then\n")
			f:write("  PYTHON_BIN=\"$VIRTUAL_ENV/bin/python3\"\n")
			f:write("elif [ -x \"" .. script_project_venv_python_escaped .. "\" ]; then\n")
			f:write("  PYTHON_BIN=\"" .. script_project_venv_python_escaped .. "\"\n")
			f:write("fi\n")
			f:write("if [ \"$PYTHON_BIN\" = \"python3\" ]; then\n")
			f:write("  MLX_VENV=\"$HOME/.mlx_py_env\"\n")
			f:write("  python3 -m venv \"$MLX_VENV\" >/dev/null 2>&1 || true\n")
			f:write("  if [ -x \"$MLX_VENV/bin/python3\" ]; then\n")
			f:write("    PYTHON_BIN=\"$MLX_VENV/bin/python3\"\n")
			f:write("  fi\n")
			f:write("fi\n")
			f:write("echo \"Python utilisé: $PYTHON_BIN\"\n")
			f:write("export HF_HUB_DISABLE_SYMLINKS_WARNING=1\n")
			f:write("export PYTHONUNBUFFERED=1\n")
			f:write("export SSL_CERT_FILE=/etc/ssl/cert.pem\n")
			f:write("export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem\n")
			f:write("export HF_HUB_DISABLE_XET=1\n")
			f:write("if ! $PYTHON_BIN -c 'import huggingface_hub, truststore, hf_transfer' >/dev/null 2>&1; then\n")
			f:write("  echo '[MLX] Dépendances Hugging Face manquantes, installation... '\n")
			f:write("  if ! $PYTHON_BIN -m pip install --disable-pip-version-check --upgrade huggingface_hub hf_transfer truststore; then\n")
			f:write("    echo '[MLX] Installation globale impossible, tentative en --user'\n")
			f:write("    $PYTHON_BIN -m pip install --user --disable-pip-version-check --upgrade huggingface_hub hf_transfer truststore || { echo '[MLX] Installation huggingface_hub impossible'; exit 1; }\n")
			f:write("  fi\n")
			f:write("fi\n")
			f:write("$PYTHON_BIN -c 'import huggingface_hub, truststore' >/dev/null 2>&1 || { echo '[MLX] Python utilisé sans huggingface_hub/truststore'; exit 1; }\n")
			f:write("$PYTHON_BIN -c 'import hf_transfer' 2>/dev/null && export HF_HUB_ENABLE_HF_TRANSFER=1 || export HF_HUB_ENABLE_HF_TRANSFER=0\n")
			f:write("HUB_DIR=\"$HOME/.cache/huggingface/hub\"\n")
			f:write("SNAP_DIR=\"$HUB_DIR/" .. safe_repo_bash .. "/snapshots\"\n")
			f:write("HAS_WEIGHTS=0\n")
			f:write("if [ -d \"$SNAP_DIR\" ]; then\n")
			f:write("  for commit_dir in \"$SNAP_DIR\"/*/; do\n")
			f:write("    for wf in \"$commit_dir\"*.safetensors \"$commit_dir\"*.bin; do\n")
			f:write("      [ -s \"$wf\" ] && HAS_WEIGHTS=1 && break 2\n")
			f:write("    done\n")
			f:write("  done\n")
			f:write("fi\n")
			f:write("if [ \"$HAS_WEIGHTS\" = '0' ] && [ -d \"$HUB_DIR/" .. safe_repo_bash .. "\" ]; then\n")
			f:write("  echo 'Cache incomplet détecté, nettoyage...'\n")
			f:write("  rm -rf \"$HUB_DIR/" .. safe_repo_bash .. "\"\n")
			f:write("fi\n")
			f:write("echo 'Démarrage du téléchargement de " .. clean_repo .. "...'\n")
			-- nohup shields SIGHUP; Python's os.setpgrp() escapes NSTask process-group kill
			f:write("nohup \"$PYTHON_BIN\" -u " .. py_path .. " >> " .. _log_path .. " 2>&1 &\n")
			f:write("echo \"__DLPID__:$!\"\n")
			-- Redirect stdout/stderr to /dev/null before exit so Python does not inherit the
			-- NSTask pipe fd — prevents the "readDataOfLength: Resource temporarily unavailable" warning
			f:write("exec 1>/dev/null 2>/dev/null\n")
			f:write("exit 0\n")
			f:close()

			os.execute("chmod +x " .. script_path)

			-- Persist session so a future HS reload can reattach tail -f without restarting the download
			local _session_json = string.format(
				"{\"model\":\"%s\",\"log_path\":\"%s\",\"exit_path\":\"%s\",\"repo\":\"%s\"}",
				target_model, _log_path, _exit_path, clean_repo
			)
			local _sf = io.open("/tmp/hs_mlx_active_download.json", "w")
			if _sf then _sf:write(_session_json); _sf:close() end

			if download_window then
				-- terminal_cmd points to the live log so the "Terminal" button shows real Python output
				pcall(download_window.show, target_model, do_cancel, "tail -f " .. _log_path, ui_sizes, {
					on_resolve = do_resolve_gated,
					on_retry = do_retry,
				})
			end
			pcall(deps.update_icon, "📥 0%")
			
			local _bytes_done, _bytes_total = 0, estimated_bytes_total
			local _current_pct = 0
			local _stream_tail = ""
			local _saw_gated_error = false
			-- Authoritative file count emitted by the Python size-watcher (__FILECOUNT__:N)
			local _python_file_count = nil

			local last_progress_time = os.time()
			local function reset_timeout()
				last_progress_time = os.time()
			end
			local function check_timeout()
				-- Guard on _dl_pid rather than active_tasks: the task slot is transient for the
				-- short-lived launcher, but _dl_pid persists for the entire Python process lifetime
				if _dl_pid then
					local stall_seconds = os.difftime(os.time(), last_progress_time)
					local stall_limit = (_current_pct >= 99) and 120 or 300
					if stall_seconds >= stall_limit then
						local reason = (_current_pct >= 99)
							and "Aucun progrès détecté depuis 2 minutes à 99 %. Blocage probable."
							or "Aucun progrès détecté depuis 5 minutes. Abandon."
						pcall(notifications.notify, "⏳ Téléchargement MLX bloqué", reason)
						if download_window then pcall(download_window.complete, false, target_model) end
						-- Pass silent=true: notifications and window state already handled above
						do_cancel(true)
					else
						hs.timer.doAfter(30, check_timeout)
					end
				end
			end

			-- Shared stream processor used by both the launcher stdout and the tail task
			local function process_stream(out)
				if not out or out == "" then return end
				local found_progress = false
				local out_l = out:lower()
				if out_l:find("gated", 1, true) or out_l:find("privé", 1, true) or out_l:find("401", 1, true) or out_l:find("403", 1, true) then
					_saw_gated_error = true
				end

				local max_bytes = _bytes_done
				for b_str in out:gmatch("__BYTES__:(%d+)") do
					local b = tonumber(b_str)
					if b and b > max_bytes then max_bytes = b end
				end
				if max_bytes > _bytes_done then
					_bytes_done = max_bytes
					found_progress = true
				end

				-- __FILECOUNT__ is emitted directly by the Python size-watcher and is far more
				-- reliable than tqdm log parsing which breaks after the first large file completes
				for fc_str in out:gmatch("__FILECOUNT__:(%d+)") do
					local fc = tonumber(fc_str)
					if fc and fc > 0 then
						_python_file_count = fc
						found_progress = true
					end
				end

				if _bytes_total > 0 then
					-- Continuously expand the total estimate to prevent exceeding 100 % — HuggingFace
					-- downloads metadata, shards, and blobs that often exceed the stated download_gb
					if _bytes_done > _bytes_total then
						local headroom = math.max(_bytes_done * 0.20, 500 * 1024 * 1024)
						_bytes_total = _bytes_done + headroom
					end
					_current_pct = math.floor((_bytes_done / _bytes_total) * 100 + 0.5)
				end
				-- 100 % is reserved exclusively for the completion event
				_current_pct = math.min(math.max(0, _current_pct), 99)

				if out:find("Terminé !", 1, true) then
					_current_pct = 100
					found_progress = true
				end

				if found_progress then reset_timeout() end

				if download_window and out ~= "" then
					local merged = (_stream_tail or "") .. out
					merged = merged:gsub("\r\n", "\n"):gsub("\r", "\n")
					local cut = merged:match(".*()\n")
					if cut then
						local complete = merged:sub(1, cut)
						_stream_tail = merged:sub(cut + 1)
						if complete ~= "" then
							pcall(download_window.update, _current_pct, _bytes_done, _bytes_total, complete, _python_file_count)
						end
					else
						_stream_tail = merged
					end
				end
				local _icon_pct = math.min(_current_pct, 99)
				if _icon_pct > 0 then pcall(deps.update_icon, "📥 " .. _icon_pct .. "%") end
			end

			-- Called once the Python exit file appears — reads exit code and finalises UI
			local function handle_download_done()
				if _tail_task then
					pcall(function() _tail_task:terminate() end)
					_tail_task = nil
				end
				_dl_pid = nil
				if deps.active_tasks then
					deps.active_tasks["download"]      = nil
					deps.active_tasks["download_tail"] = nil
				end
				pcall(deps.update_icon)
				os.execute("rm -f /tmp/hs_mlx_active_download.json 2>/dev/null")

				-- Flush any remaining buffered output before showing final status
				if _stream_tail ~= "" and download_window then
					pcall(download_window.update, _current_pct, _bytes_done, _bytes_total, _stream_tail, _python_file_count)
					_stream_tail = ""
				end

				-- Read exit code written by Python atexit handler
				local exit_code = 1
				local ef = io.open(_exit_path, "r")
				if ef then
					local raw = ef:read("*l")
					ef:close()
					exit_code = tonumber(raw) or 1
					os.execute("rm -f " .. _exit_path .. " 2>/dev/null")
				end

				if exit_code == 0 then
					pcall(notifications.notify, "🟢 MODÈLE MLX INSTALLÉ", target_model .. " est prêt !")
					if download_window then pcall(download_window.complete, true, target_model) end
					deps.state.llm_model = target_model
					if deps.keymap and type(deps.keymap.set_llm_model) == "function" then pcall(deps.keymap.set_llm_model, target_model) end
					pcall(deps.save_prefs)
					obj.start_server(target_model, function()
						if on_success then pcall(on_success) end
					end)
				else
					if download_window then pcall(download_window.complete, false, target_model, _saw_gated_error and "gated" or nil) end
					pcall(notifications.notify, "❌ Échec MLX", "Vérifiez les logs dans la fenêtre.")
				end
			end

			-- Starts a tail -f task that streams the Python log file back to Lua in real time;
			-- also polls the exit file every 3 s to catch completion reliably
			local function start_tail_monitor()
				_tail_task = hs.task.new("/usr/bin/tail", function()
					-- Tail exited (killed by do_cancel or process gone) — check exit file
					hs.timer.doAfter(0.5, function()
						local ef = io.open(_exit_path, "r")
						if ef then ef:close(); handle_download_done() end
					end)
				end, function(_, stdout, stderr)
					process_stream((stdout or "") .. (stderr or ""))
					return true
				end, {"-F", "-n", "+1", _log_path})

				if _tail_task then
					if deps.active_tasks then deps.active_tasks["download_tail"] = _tail_task end
					pcall(function() _tail_task:start() end)
				end

				-- Periodic poll: tail can miss the very last flush before Python exits
				local function poll_exit()
					if not _dl_pid then return end
					local ef = io.open(_exit_path, "r")
					if ef then ef:close(); handle_download_done()
					else hs.timer.doAfter(3, poll_exit) end
				end
				hs.timer.doAfter(3, poll_exit)
				hs.timer.doAfter(30, check_timeout)
			end

			-- Short-lived launcher: resolves Python, installs deps, cleans stale cache, then
			-- exits after spawning the detached Python process and printing its PID
			local launcher_task = hs.task.new(script_path, function(code, stdout, stderr)
				if deps.active_tasks then deps.active_tasks["download"] = nil end
				-- stdout/stderr are empty when a streaming callback is active — _dl_pid was already
				-- set by the streaming callback which received the __DLPID__ sentinel
				if not _dl_pid or code ~= 0 then
					-- Reset icon here: handle_download_done will not run after a launcher failure
					pcall(deps.update_icon)
					if download_window then pcall(download_window.complete, false, target_model) end
					pcall(notifications.notify, "❌ Échec lancement MLX", "Le lanceur a échoué (code " .. tostring(code) .. ").")
					return
				end
				start_tail_monitor()
			end, function(_, stdout, stderr)
				local out = (stdout or "") .. (stderr or "")
				-- Parse __DLPID__ here — completion callback gets empty strings when streaming is active
				if not _dl_pid then
					local pid_str = out:match("__DLPID__:(%d+)")
					if pid_str then
						_dl_pid = tonumber(pid_str)
						-- Persist PID so a post-reload reattach can check liveness and cancel cleanly
						local sf = io.open("/tmp/hs_mlx_active_download.json", "r")
						if sf then
							local raw = sf:read("*a"); sf:close()
							local ok_j, sess = pcall(hs.json.decode, raw)
							if ok_j and type(sess) == "table" then
								sess.pid = _dl_pid
								local ok_e, enc = pcall(hs.json.encode, sess)
								if ok_e and enc then
									local wf = io.open("/tmp/hs_mlx_active_download.json", "w")
									if wf then wf:write(enc); wf:close() end
								end
							end
						end
					end
				end
				-- Strip the sentinel line before forwarding to the download window log
				local clean = out:gsub("__DLPID__:%d+\n?", "")
				process_stream(clean)
				return true
			end)

			if launcher_task then
				if deps.active_tasks then deps.active_tasks["download"] = launcher_task end
				pcall(function() launcher_task:start() end)
			end
		end

		-- Step 0: Ensure MLX stack is upgraded before starting the download
		pcall(notifications.notify, "⚙️ Préparation MLX", "Vérification des mises à jour des dépendances…")
		upgrade_mlx_stack(function()
			_internal_pull()
		end)
	end

	--- Reattaches the download UI and log tail to an already-running detached Python download.
	--- Called after a Hammerspoon reload when /tmp/hs_mlx_active_download.json exists.
	--- @param session table Decoded JSON session: { model, log_path, exit_path, pid, repo }.
	function obj.reattach_download(session)
		local model     = session.model     or "?"
		local log_path  = session.log_path  or ""
		local exit_path = session.exit_path or ""
		local pid       = session.pid

		Logger.start(LOG, "Reattaching download UI for '%s' (PID %s)…", model, tostring(pid))

		-- Check whether the download finished during the reload window
		local ef = io.open(exit_path, "r")
		if ef then
			local raw = ef:read("*l"); ef:close()
			local code = tonumber(raw) or 1
			os.execute("rm -f " .. exit_path .. " 2>/dev/null")
			os.execute("rm -f /tmp/hs_mlx_active_download.json 2>/dev/null")
			if code == 0 then
				pcall(notifications.notify, "🟢 MODÈLE MLX INSTALLÉ", model .. " est prêt !")
			else
				pcall(notifications.notify, "❌ Échec MLX", "Le téléchargement de " .. model .. " a échoué pendant le rechargement.")
			end
			Logger.info(LOG, "Reattach: download already finished (exit=%d) — no tail needed.", code)
			return
		end

		-- Check liveness via kill -0 (no signal sent, just checks if PID exists)
		if pid then
			local alive = os.execute("kill -0 " .. tostring(pid) .. " 2>/dev/null")
			if not alive then
				os.execute("rm -f /tmp/hs_mlx_active_download.json 2>/dev/null")
				pcall(notifications.notify, "❌ Téléchargement interrompu", "Le processus de téléchargement de " .. model .. " s'est arrêté pendant le rechargement.")
				Logger.warn(LOG, "Reattach: PID %d no longer alive — aborting reattach.", pid)
				return
			end
		end

		-- Re-register in active_tasks so the menu item and icon stay active
		if deps.active_tasks then deps.active_tasks["download_tail"] = true end
		pcall(deps.update_icon, "📥 …")

		local _tail_task = nil

		local function do_cancel_reattached(silent)
			if _tail_task then pcall(function() _tail_task:terminate() end); _tail_task = nil end
			if pid then os.execute("kill -TERM " .. tostring(pid) .. " 2>/dev/null") end
			if deps.active_tasks then
				deps.active_tasks["download"]      = nil
				deps.active_tasks["download_tail"] = nil
			end
			pcall(deps.update_icon)
			os.execute("rm -f /tmp/hs_mlx_active_download.json 2>/dev/null")
			if not silent then
				pcall(notifications.notify, "🛑 Annulé", "Téléchargement de " .. model .. " interrompu.")
				if download_window then pcall(download_window.complete, false, model) end
			end
		end

		local function handle_done_reattached()
			if deps.active_tasks then
				deps.active_tasks["download"]      = nil
				deps.active_tasks["download_tail"] = nil
			end
			pcall(deps.update_icon)
			os.execute("rm -f /tmp/hs_mlx_active_download.json 2>/dev/null")
			local ef2 = io.open(exit_path, "r")
			local exit_code = 1
			if ef2 then
				local raw = ef2:read("*l"); ef2:close()
				exit_code = tonumber(raw) or 1
				os.execute("rm -f " .. exit_path .. " 2>/dev/null")
			end
			if exit_code == 0 then
				pcall(notifications.notify, "🟢 MODÈLE MLX INSTALLÉ", model .. " est prêt !")
				if download_window then pcall(download_window.complete, true, model) end
				pcall(deps.save_prefs)
			else
				if download_window then pcall(download_window.complete, false, model) end
				pcall(notifications.notify, "❌ Échec MLX", "Vérifiez les logs dans la fenêtre.")
			end
		end

		local function process_stream_reattached(out)
			if not out or out == "" then return end
			local _bytes_done, _bytes_total, _current_pct = 0, 0, 0
			local max_bytes = 0
			for b_str in out:gmatch("__BYTES__:(%d+)") do
				local b = tonumber(b_str)
				if b and b > max_bytes then max_bytes = b end
			end
			if max_bytes > 0 then _bytes_done = max_bytes end
			local _python_file_count = nil
			for fc_str in out:gmatch("__FILECOUNT__:(%d+)") do
				local fc = tonumber(fc_str)
				if fc and fc > 0 then _python_file_count = fc end
			end
			local icon_pct = math.min(tonumber(out:match("(%d+)%%") or 0) or 0, 99)
			if icon_pct > 0 then pcall(deps.update_icon, "📥 " .. icon_pct .. "%") end
			if download_window then
				pcall(download_window.update, icon_pct, _bytes_done, _bytes_total, out, _python_file_count)
			end
		end

		-- Open (or re-focus) the download window
		if download_window then
			pcall(download_window.show, model, do_cancel_reattached, "tail -f " .. log_path, nil, {
				on_retry = function()
					do_cancel_reattached(true)
					hs.timer.doAfter(0.05, function()
						local repo = session.repo or ""
						if repo ~= "" then obj.pull_model(model, repo, nil) end
					end)
				end,
			})
		end

		-- Start a new tail -f on the existing log file
		_tail_task = hs.task.new("/usr/bin/tail", function()
			hs.timer.doAfter(0.5, function()
				local ef3 = io.open(exit_path, "r")
				if ef3 then ef3:close(); handle_done_reattached() end
			end)
		end, function(_, stdout, stderr)
			process_stream_reattached((stdout or "") .. (stderr or ""))
			return true
		end, {"-F", "-n", "+1", log_path})

		if _tail_task then
			deps.active_tasks["download_tail"] = _tail_task
			pcall(function() _tail_task:start() end)
		end

		-- Poll for exit file in case tail misses the final flush
		local function poll_exit_reattached()
			if not (deps.active_tasks and deps.active_tasks["download_tail"]) then return end
			local ef4 = io.open(exit_path, "r")
			if ef4 then ef4:close(); handle_done_reattached()
			else hs.timer.doAfter(3, poll_exit_reattached) end
		end
		hs.timer.doAfter(3, poll_exit_reattached)

		Logger.success(LOG, "Reattached download tail for '%s'.", model)
	end


	function obj.check_requirements(target_model, on_success, on_cancel, opts)
		if not target_model or target_model == "" then 
			if type(on_success) == "function" then on_success() end
			return 
		end
		Logger.debug(LOG, "Checking MLX requirements for model %s…", tostring(target_model))

		local function do_check()
			local installed = obj.get_installed_models()
			if installed[target_model] then
				Logger.info(LOG, "MLX model %s is installed. Starting server…", tostring(target_model))
				obj.start_server(target_model, on_success, opts)
			else
				Logger.warn(LOG, "MLX model %s not detected as installed. Starting download flow…", tostring(target_model))
				local repo = obj.get_mlx_repo(target_model)
				if not repo then 
					pcall(notifications.notify, "❌ Modèle MLX non disponible", "Le modèle " .. target_model .. " n’est pas compatible MLX ou n’a pas de dépôt MLX configuré")
					if on_cancel then on_cancel() end 
					return 
				end
				
				if type(deps.shared_system_check) == "function" then
					deps.shared_system_check(target_model, "Apple MLX", repo, function()
						obj.pull_model(target_model, repo, on_success)
					end, on_cancel)
				else
					obj.pull_model(target_model, repo, on_success)
				end
			end
		end

		local check_task = hs.task.new("/bin/bash", function(code)
			if code == 0 then
				do_check()
			else
				local function cancel_install()
					local t = deps.active_tasks and deps.active_tasks["install"]
					if t and type(t) == "userdata" and type(t.terminate) == "function" then pcall(function() t:terminate() end) end
				end

				local script_path = "/tmp/hs_mlx_deps.sh"
				local f = io.open(script_path, "w")
				if not f then return end
				f:write("#!/bin/bash\n")
				f:write("export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\n")
				f:write("PYTHON_BIN=\"python3\"\n")
				f:write("if [ -n \"$VIRTUAL_ENV\" ] && [ -x \"$VIRTUAL_ENV/bin/python3\" ]; then\n")
				f:write("  PYTHON_BIN=\"$VIRTUAL_ENV/bin/python3\"\n")
				f:write("elif [ -x \"" .. project_venv_python_escaped .. "\" ]; then\n")
				f:write("  PYTHON_BIN=\"" .. project_venv_python_escaped .. "\"\n")
				f:write("fi\n")
				f:write("if [ \"$PYTHON_BIN\" = \"python3\" ]; then\n")
				f:write("  MLX_VENV=\"$HOME/.mlx_py_env\"\n")
				f:write("  python3 -m venv \"$MLX_VENV\" >/dev/null 2>&1 || true\n")
				f:write("  if [ -x \"$MLX_VENV/bin/python3\" ]; then\n")
				f:write("    PYTHON_BIN=\"$MLX_VENV/bin/python3\"\n")
				f:write("  fi\n")
				f:write("fi\n")
				f:write("if ! \"$PYTHON_BIN\" -m pip --version >/dev/null 2>&1; then\n")
				f:write("  \"$PYTHON_BIN\" -m ensurepip --upgrade >/dev/null 2>&1 || true\n")
				f:write("fi\n")
				f:write("if ! \"$PYTHON_BIN\" -m pip --version >/dev/null 2>&1; then\n")
				f:write("  MLX_VENV=\"$HOME/.mlx_py_env\"\n")
				f:write("  python3 -m venv \"$MLX_VENV\" >/dev/null 2>&1 || true\n")
				f:write("  if [ -x \"$MLX_VENV/bin/python3\" ]; then\n")
				f:write("    PYTHON_BIN=\"$MLX_VENV/bin/python3\"\n")
				f:write("  fi\n")
				f:write("fi\n")
				f:write("if ! \"$PYTHON_BIN\" -m pip --version >/dev/null 2>&1; then\n")
				f:write("  \"$PYTHON_BIN\" -m ensurepip --upgrade >/dev/null 2>&1 || true\n")
				f:write("fi\n")
				f:write("export SSL_CERT_FILE=/etc/ssl/cert.pem\n")
				f:write("export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem\n")
				f:write("export PIP_CERT=/etc/ssl/cert.pem\n")
				f:write("export HF_HUB_DISABLE_XET=1\n")
				f:write("echo \"Python utilisé: $PYTHON_BIN\"\n")
				f:write("echo 'Installation des dépendances MLX...'\n")
				f:write("$PYTHON_BIN -u -m pip install --upgrade mlx-lm huggingface_hub hf_transfer truststore\n")
				f:close()
				os.execute("chmod +x " .. script_path)

				if download_window then 
					pcall(download_window.show, "Dépendances MLX", cancel_install, script_path) 
				end

				local install_task = hs.task.new(script_path, function(icode)
					if deps.active_tasks then deps.active_tasks["install"] = nil end
					os.remove(script_path)
					
					if icode == 15 then
						pcall(notifications.notify, "🛑 Annulé", "Installation interrompue.")
						if download_window then pcall(download_window.complete, false, "Dépendances") end
						if on_cancel then on_cancel() end
						return
					end

					if icode == 0 then
						if download_window then pcall(download_window.complete, true, "Dépendances") end
						hs.timer.doAfter(1.5, do_check)
					else
						pcall(notifications.notify, "Erreur", "Échec de l’installation des dépendances.")
						if download_window then pcall(download_window.complete, false, "Dépendances") end
						if on_cancel then on_cancel() end
					end
				end, function(_, stdout, stderr)
					local out = (stdout or "") .. (stderr or "")
					if download_window and out ~= "" then
						pcall(download_window.update, 0, nil, nil, out:gsub("[\r\n]", ""))
					end
					return true
				end)
				
				if install_task then
					deps.active_tasks["install"] = install_task
					pcall(function() install_task:start() end)
				end
			end
		end, {"-c", "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; PYTHON_BIN=\"python3\"; if [ -n \"$VIRTUAL_ENV\" ] && [ -x \"$VIRTUAL_ENV/bin/python3\" ]; then PYTHON_BIN=\"$VIRTUAL_ENV/bin/python3\"; elif [ -x \"" .. project_venv_python_escaped .. "\" ]; then PYTHON_BIN=\"" .. project_venv_python_escaped .. "\"; fi; if [ \"$PYTHON_BIN\" = \"python3\" ]; then MLX_VENV=\"$HOME/.mlx_py_env\"; python3 -m venv \"$MLX_VENV\" >/dev/null 2>&1 || true; [ -x \"$MLX_VENV/bin/python3\" ] && PYTHON_BIN=\"$MLX_VENV/bin/python3\"; fi; $PYTHON_BIN -c 'import mlx_lm; import huggingface_hub; import jinja2; import safetensors'"})
		
		if check_task then
			pcall(function() check_task:start() end)
		else
			Logger.error(LOG, "Failed to create MLX requirement check task.")
			if on_cancel then pcall(on_cancel) end
		end
	end

	function obj.delete_model(model_name)
		if not model_name or model_name == "" then return end
		local repo = obj.get_mlx_repo(model_name)
		if not repo then return end
		local home = os.getenv("HOME")
		local safe_repo = "models--" .. repo:gsub("/", "--")
		local path = home .. "/.cache/huggingface/hub/" .. safe_repo
		os.execute("rm -rf " .. path)
		pcall(notifications.notify, "🗑️ Supprimé (MLX)", model_name)
		pcall(deps.update_menu)
	end

	return obj
end

return M
