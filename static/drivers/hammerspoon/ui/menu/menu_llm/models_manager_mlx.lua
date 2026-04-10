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
local notifications = require("lib.notifications")
local ui_builder = require("ui.ui_builder")

local ok_dw, download_window = pcall(require, "ui.download_window")
if not ok_dw then download_window = nil end

local config_file = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./"
config_file = config_file:match("^(.*)/ui/") or "./"
config_file = config_file .. "config.json"





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
		local fh = io.open(config_file, "r")
		if not fh then return nil end
		local raw = fh:read("*a")
		fh:close()
		local ok, cfg = pcall(hs.json.decode, raw)
		if ok and type(cfg) == "table" and type(cfg.hf_token) == "string" then
			return cfg.hf_token
		end
		return nil
	end

	local function write_hf_token(token)
		local fh = io.open(config_file, "r")
		local cfg = {}
		if fh then
			local raw = fh:read("*a")
			fh:close()
			local ok, decoded = pcall(hs.json.decode, raw)
			if ok and type(decoded) == "table" then cfg = decoded end
		end
		cfg.hf_token = token
		local ok, encoded = pcall(hs.json.encode, cfg, true)
		if ok and encoded then
			local fw = io.open(config_file, "w")
			if fw then
				fw:write(encoded)
				fw:close()
			end
		end
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

		local dry_run_cmd =
			"source ~/.venv/bin/activate 2>/dev/null || true; " ..
			"python3 -u -m pip install --disable-pip-version-check --dry-run --upgrade mlx-lm huggingface_hub hf_transfer truststore"

		local upgrade_cmd =
			"source ~/.venv/bin/activate 2>/dev/null || true; " ..
			"python3 -u -m pip install --disable-pip-version-check --upgrade mlx-lm huggingface_hub hf_transfer truststore"

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
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    
    http = urllib3.PoolManager(
        cert_reqs='CERT_NONE',
        ca_certs=None
    )
    
    headers = {
        'User-Agent': 'huggingface/hub',
        'Authorization': f'Bearer {token.strip()}'
    }
    
    response = http.request(
        'GET',
        'https://huggingface.co/api/whoami-v2',
        headers=headers,
        timeout=10
    )
    
    if response.status != 200:
        print(f"Token validation failed: HTTP {response.status}", file=sys.stderr)
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
				write_hf_token(token)
				pcall(notifications.notify, "🔓 HuggingFace connecté", "Token sauvegardé. Vous pouvez maintenant télécharger les modèles gated")
				if type(on_done) == "function" then pcall(on_done, true) end
			else
				pcall(notifications.notify, "❌ Connexion HuggingFace", "Échec de connexion. Vérifiez votre token")
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
		local installed = {}
		local home = os.getenv("HOME")
		local hub_dir = home .. "/.cache/huggingface/hub/"
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
												local fattr = hs.fs.attributes(commit_dir .. "/" .. file)
												if fattr and fattr.size and fattr.size > 10000 then
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
							end
						end
					end
				end
			end
		end
		return installed
	end

	function obj.start_server(target_model, on_success, opts)
		local repo = obj.get_mlx_repo(target_model)
		if not repo then return end
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

		if not obj._mlx_upgrade_done and not obj._mlx_upgrade_failed then
			if not silent_notifications then
				pcall(notifications.notify, "⚙️ Mise à jour MLX-LM", "Vérification et mise à jour de mlx-lm pour le modèle " .. target_model .. "…")
			end
			upgrade_mlx_stack(function(ok)
				if ok then
					if not silent_notifications then
						pcall(notifications.notify, "✅ MLX-LM mis à jour", "Relance du serveur MLX pour le modèle " .. target_model .. "…")
					end
					hs.timer.doAfter(0.5, function()
						obj.start_server(target_model, on_success, opts)
					end)
				else
					if not silent_notifications then
						pcall(notifications.notify, "⚠️ Mise à jour MLX-LM", "Échec de mise à jour automatique. Les tentatives automatiques sont suspendues pour cette session.")
					end
					obj.start_server(target_model, on_success, opts)
				end
			end)
			return
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
				if not silent_notifications then
					pcall(notifications.notify, "✅ Serveur MLX prêt", "Modèle actif: " .. target_model)
				end
				if on_success then pcall(on_success) end
				return
			end

			obj._server_target = target_model
			if not silent_notifications then
				pcall(notifications.notify, "🚀 Démarrage serveur MLX", "Chargement du modèle " .. target_model .. " en mémoire...")
			end

			local server_log_file = "/tmp/hs_mlx_server_" .. tostring(math.random(1000,9999)) .. ".log"
			local startup_confirmed = false
			local startup_closed = false

			local function mark_server_ready()
				if startup_confirmed or startup_closed then return end
				startup_confirmed = true
				if not silent_notifications then
					pcall(notifications.notify, "✅ Serveur MLX prêt", "Modèle actif: " .. target_model)
				end
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
				"if [ \"$PYTHON_BIN\" = \"python3\" ]; then MLX_VENV=\"$HOME/.mlx_py_env\"; python3 -m venv \"$MLX_VENV\" >/dev/null 2>&1 || true; [ -x \"$MLX_VENV/bin/python3\" ] && PYTHON_BIN=\"$MLX_VENV/bin/python3\"; fi; " ..
				"if ! $PYTHON_BIN -m pip --version >/dev/null 2>&1; then $PYTHON_BIN -m ensurepip --upgrade >/dev/null 2>&1 || true; fi; " ..
				"if ! $PYTHON_BIN -m pip --version >/dev/null 2>&1; then MLX_VENV=\"$HOME/.mlx_py_env\"; python3 -m venv \"$MLX_VENV\" >/dev/null 2>&1 || true; [ -x \"$MLX_VENV/bin/python3\" ] && PYTHON_BIN=\"$MLX_VENV/bin/python3\"; fi; " ..
				"if ! $PYTHON_BIN -m pip --version >/dev/null 2>&1; then $PYTHON_BIN -m ensurepip --upgrade >/dev/null 2>&1 || true; fi; " ..
				"if ! $PYTHON_BIN -c 'import mlx_lm, huggingface_hub, truststore' >/dev/null 2>&1; then " ..
				"echo \"[MLX] Dépendances manquantes: tentative d'installation...\"; " ..
				"$PYTHON_BIN -m pip install --disable-pip-version-check --upgrade mlx-lm huggingface_hub hf_transfer truststore || " ..
				"$PYTHON_BIN -m pip install --user --disable-pip-version-check --upgrade mlx-lm huggingface_hub hf_transfer truststore || exit 1; " ..
				"$PYTHON_BIN -c 'import mlx_lm, huggingface_hub, truststore' || exit 1; fi; " ..
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
					if not silent_notifications then
						pcall(notifications.notify, "❌ Échec serveur MLX", "Modèle " .. target_model .. " non démarré: le processus s’est terminé avant disponibilité")
					end
					print("MLX server exited before readiness (code 0)")
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

					local detail = (error_msg ~= "") and ("\nDetail: " .. error_msg) or ""

					local unsupported_model_backend =
						((error_msg:lower():match("model type") ~= nil) and (error_msg:lower():match("not supported") ~= nil))
						or (error_msg:match("No module named 'mlx_lm%.models%.") ~= nil)
						or (error_msg:match("No module named 'mlx_lm'") ~= nil)
						or (error_msg:match("No module named 'mlx_ml'") ~= nil)

					if unsupported_model_backend and not obj._mlx_upgrade_attempted[repo] then
						obj._mlx_upgrade_attempted[repo] = true
						if not silent_notifications then
							pcall(notifications.notify, "⚙️ Mise à jour MLX-LM", "Compatibilité détectée pour le modèle " .. target_model .. ". Mise à jour en cours…")
						end
						upgrade_mlx_stack(function(ok)
							if ok then
								if not silent_notifications then
									pcall(notifications.notify, "✅ MLX-LM mis à jour", "Redémarrage du serveur MLX pour le modèle " .. target_model .. "…")
								end
								hs.timer.doAfter(0.5, function()
									obj.start_server(target_model, on_success, opts)
								end)
							else
								if not silent_notifications then
									pcall(notifications.notify, "❌ Échec mise à jour MLX-LM", "La mise à jour automatique a échoué pour le modèle " .. target_model .. ". Lancez : python3 -m pip install --user --upgrade mlx-lm")
								end
							end
						end)

						print("MLX server exited with code " .. code)
						return
					end

					if not silent_notifications then
						pcall(notifications.notify, "❌ Échec serveur MLX", "Modèle " .. target_model .. " non démarré." .. detail)
					end
				end

				print("MLX server exited with code " .. code)
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
				if not silent_notifications then
					pcall(notifications.notify, "Erreur MLX", "Impossible de démarrer le serveur MLX pour le modèle " .. target_model)
				end
			end
		end)
	end





	-- =====================================
	-- =====================================
	-- ======= 2/ Dependency Parsing =======
	-- =====================================
	-- =====================================

	function obj.pull_model(target_model, repo, on_success)
		local function do_cancel()
			local t = deps.active_tasks and deps.active_tasks["download"]
			if t and type(t) == "userdata" and type(t.terminate) == "function" then pcall(function() t:terminate() end) end
		end

		local function do_retry()
			if deps.active_tasks and deps.active_tasks["download"] then return end
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
						elseif type(hw.disk_gb) == "number" then
							estimated_bytes_total = math.floor(hw.disk_gb * 1e9)
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
				disk   = hw.disk_gb and (hw.disk_gb .. " Go"),
				params = m_table.parameters and m_table.parameters.total
			}
		end

		local clean_repo = repo:gsub("[%c%s]", "")
		local script_path = "/tmp/hs_mlx_dl_" .. tostring(math.random(1000,9999)) .. ".sh"
		local script_project_venv_python_escaped = project_venv_python_escaped
		
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
		f:write("if ! $PYTHON_BIN -c 'import huggingface_hub' >/dev/null 2>&1; then\n")
		f:write("  echo '[MLX] Dépendances Hugging Face manquantes, installation... '\n")
		f:write("  if ! $PYTHON_BIN -m pip install --disable-pip-version-check --upgrade huggingface_hub hf_transfer truststore; then\n")
		f:write("    echo '[MLX] Installation globale impossible, tentative en --user'\n")
		f:write("    $PYTHON_BIN -m pip install --user --disable-pip-version-check --upgrade huggingface_hub hf_transfer truststore || { echo '[MLX] ❌ Installation huggingface_hub impossible'; exit 1; }\n")
		f:write("  fi\n")
		f:write("fi\n")
		f:write("$PYTHON_BIN -c 'import huggingface_hub, truststore' >/dev/null 2>&1 || { echo '[MLX] ❌ Python utilisé sans huggingface_hub/truststore'; exit 1; }\n")
		f:write("$PYTHON_BIN -c 'import hf_transfer' 2>/dev/null && export HF_HUB_ENABLE_HF_TRANSFER=1 || export HF_HUB_ENABLE_HF_TRANSFER=0\n")
		local safe_repo_bash = "models--" .. clean_repo:gsub("/", "--")
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
		
		f:write("$PYTHON_BIN -u - <<'EOF'\n")
		f:write("import sys, os, threading\n")
		f:write("try:\n")
		f:write("    import truststore\n")
		f:write("    truststore.inject_into_ssl()\n")
		f:write("except Exception:\n")
		f:write("    pass\n")
		f:write("try:\n")
		f:write("    from huggingface_hub import snapshot_download\n")
		f:write("except Exception:\n")
		f:write("    print('--- ERREUR DEPENDANCES ---', flush=True)\n")
		f:write("    import traceback\n")
		f:write("    traceback.print_exc()\n")
		f:write("    sys.exit(1)\n")
		f:write("_hub_dir = os.path.expanduser('~/.cache/huggingface/hub')\n")
		f:write("_model_cache = os.path.join(_hub_dir, '" .. safe_repo_bash .. "')\n")
		f:write("_stop_evt = threading.Event()\n")
		f:write("def _size_watcher():\n")
		f:write("    while True:\n")
		f:write("        try:\n")
		f:write("            _total = 0\n")
		f:write("            for _dp, _, _fns in os.walk(_model_cache, followlinks=False):\n")
		f:write("                for _fn in _fns:\n")
		f:write("                    _fp = os.path.join(_dp, _fn)\n")
		f:write("                    if not os.path.islink(_fp):\n")
		f:write("                        try: _total += os.path.getsize(_fp)\n")
		f:write("                        except: pass\n")
		f:write("            print('__BYTES__:' + str(_total), flush=True)\n")
		f:write("        except Exception as _e:\n")
		f:write("            print('__BYTES__:ERROR:' + str(_e), flush=True)\n")
		f:write("        if _stop_evt.wait(2): break\n")
		f:write("_watcher = threading.Thread(target=_size_watcher, daemon=True)\n")
		f:write("_watcher.start()\n")
		f:write("try:\n")
		f:write("    snapshot_download('" .. clean_repo .. "', max_workers=8)\n")
		f:write("except Exception as e:\n")
		f:write("    err_str = str(e).lower()\n")
		f:write("    if '401' in err_str or '403' in err_str or 'gated' in err_str or 'unauthorized' in err_str:\n")
		f:write("        print('\\n❌ ERREUR : Ce modèle est PRIVÉ (Gated) par son créateur.')\n")
		f:write("        print('Pour le télécharger, vous devez :')\n")
		f:write("        print('1. Créer un compte sur HuggingFace.co et accepter les conditions du modèle.')\n")
		f:write("        print('2. Dans le menu LLM, utilisez le bouton : 🔑 Connexion HuggingFace.')\n")
		f:write("        print('   Option manuelle: huggingface-cli login')\n")
		f:write("    else:\n")
		f:write("        print('\\n--- ERREUR HUGGINGFACE ---')\n")
		f:write("        import traceback\n")
		f:write("        traceback.print_exc()\n")
		f:write("    _stop_evt.set()\n")
		f:write("    sys.exit(1)\n")
		f:write("_stop_evt.set()\n")
		f:write("EOF\n")
		
		f:write("exit_code=$?\n")
		f:write("if [ $exit_code -eq 0 ]; then\n")
		f:write("  echo 'Terminé !'\n")
		f:write("fi\n")
		f:write("exit $exit_code\n")
		f:close()
		
		os.execute("chmod +x " .. script_path)

		if download_window then 
			pcall(download_window.show, target_model, do_cancel, script_path, ui_sizes, {
				on_resolve = do_resolve_gated,
				on_retry = do_retry,
			}) 
		end
		pcall(deps.update_icon, "📥 MLX")
		
		local _bytes_done, _bytes_total = 0, estimated_bytes_total
		local _current_pct = 0
		local _total_adjusted = false
		local _stream_tail = ""
		local _saw_gated_error = false

		local last_progress_time = os.time()
		local function reset_timeout()
			last_progress_time = os.time()
		end
		local function check_timeout()
			if deps.active_tasks and deps.active_tasks["download"] then
				local stall_seconds = os.difftime(os.time(), last_progress_time)
				local stall_limit = (_current_pct >= 99) and 120 or 300
				if stall_seconds >= stall_limit then
					local reason = (_current_pct >= 99)
						and "Aucun progrès détecté depuis 2 minutes à 99 %. Blocage probable."
						or "Aucun progrès détecté depuis 5 minutes. Abandon."
					pcall(notifications.notify, "⏳ Téléchargement MLX bloqué", reason)
					if download_window then pcall(download_window.complete, false, target_model) end
					pcall(function() deps.active_tasks["download"]:terminate() end)
					deps.active_tasks["download"] = nil
				else
					hs.timer.doAfter(30, check_timeout)
				end
			end
		end
		hs.timer.doAfter(30, check_timeout)

		local task = hs.task.new(script_path, function(code)
			if deps.active_tasks then deps.active_tasks["download"] = nil end
			pcall(deps.update_icon)

			if _stream_tail ~= "" and download_window then
				pcall(download_window.update, _current_pct, _bytes_done, _bytes_total, _stream_tail)
				_stream_tail = ""
			end
			
			if code == 15 then
				pcall(notifications.notify, "🛑 Annulé", "Téléchargement de " .. target_model .. " interrompu.")
				if download_window then pcall(download_window.complete, false, target_model) end
				return
			end

			if code == 0 then
				pcall(notifications.notify, "🟢 MODÈLE MLX INSTALLÉ", target_model .. " est prêt !")
				if download_window then pcall(download_window.complete, true, target_model) end
				deps.state.llm_model = target_model
				if deps.keymap and type(deps.keymap.set_llm_model) == "function" then pcall(deps.keymap.set_llm_model, target_model) end
				pcall(deps.save_prefs)
				obj.start_server(target_model, function() 
					if on_success then pcall(on_success) else pcall(hs.reload) end 
				end)
			else
				if download_window then pcall(download_window.complete, false, target_model, _saw_gated_error and "gated" or nil) end
				pcall(notifications.notify, "❌ Échec MLX", "Vérifiez les logs dans la fenêtre.")
			end
		end, function(_, stdout, stderr)
			local out = (stdout or "") .. (stderr or "")
			local found_progress = false
			local out_l = out:lower()
			if out_l:find("gated", 1, true) or out_l:find("privé", 1, true) or out_l:find("401", 1, true) or out_l:find("403", 1, true) then
				_saw_gated_error = true
			end

			local function parse_hf_size(s)
				if not s then return nil end
				local val, unit = s:match("([%d%.]+)([kMGT]?B)")
				val = tonumber(val)
				if not val then return nil end
				if unit == "GB" then return val * 1e9
				elseif unit == "MB" then return val * 1e6
				elseif unit == "kB" then return val * 1e3 end
				return val
			end

			local max_bytes = _bytes_done
			for b_str in out:gmatch("__BYTES__:(%d+)") do
				local b = tonumber(b_str)
				if b and b > max_bytes then
					max_bytes = b
				end
			end
			if max_bytes > _bytes_done then
				_bytes_done = max_bytes
				found_progress = true
			end

			if _bytes_total > 0 then
				if _bytes_done > _bytes_total and not _total_adjusted then
					_total_adjusted = true
					local headroom = math.max(_bytes_done * 0.15, 500 * 1024 * 1024)
					_bytes_total = _bytes_done + headroom
				end
				_current_pct = math.floor((_bytes_done / _bytes_total) * 100 + 0.5)
			end

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
						pcall(download_window.update, _current_pct, _bytes_done, _bytes_total, complete)
					end
				else
					_stream_tail = merged
				end
			end
			if _current_pct > 0 then pcall(deps.update_icon, "📥 " .. _current_pct .. "%") end
			return true
		end)
		
		if task then
			deps.active_tasks["download"] = task
			pcall(function() task:start() end)
		end
	end

	function obj.check_requirements(target_model, on_success, on_cancel, opts)
		if not target_model or target_model == "" then 
			if type(on_success) == "function" then on_success() end
			return 
		end

		local function do_check()
			local installed = obj.get_installed_models()
			if installed[target_model] then
				obj.start_server(target_model, on_success, opts)
			else
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
		
		pcall(function() check_task:start() end)
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
