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

-- Optional dependency: the auto-bootstrap status lives in this module so we
-- can differentiate "still installing" from "definitively failed" when the
-- MLX import probe below fails. If the module is absent (unusual layout),
-- we fall back to the previous generic behaviour.
local ok_mlx_deps, mlx_deps_checker = pcall(require, "lib.mlx_deps_checker")
if not ok_mlx_deps then mlx_deps_checker = nil end

local LOG = "menu_llm.mlx"

local ok_dw, download_window = pcall(require, "ui.download_window")
if not ok_dw then download_window = nil end

-- Required to inform the discovery poller of the active server PID so it can
-- exclude it from zombie kills; safe to require here because api_mlx holds no
-- circular dependency on this file.
local ok_api_mlx, ApiMlx = pcall(require, "modules.llm.api_mlx")
if not ok_api_mlx then ApiMlx = nil end

local HF_TOKEN_FILE = (os.getenv("HOME") or "") .. "/.huggingface/token"





-- =========================================
-- =========================================
-- ======= 1/ MLX Engine Core System =======
-- =========================================
-- =========================================

function M.new(deps, presets)
	local obj = {}
	deps.active_tasks = deps.active_tasks or {}
	obj._installed_cache = nil
	obj._installed_cache_ts = 0

	-- Register a restart hook so api_mlx can request a fresh launch when its
	-- discovery loop detects a model-ID mismatch it cannot resolve on its own
	-- (typically a cross-session leftover whose PGID was wrongly adopted as the
	-- active guard). The hook is invoked with the expected short model name.
	if type(ApiMlx) == "table" and type(ApiMlx.set_restart_hook) == "function" then
		ApiMlx.set_restart_hook(function(target)
			-- api_mlx passes _expected_model_id, which is the resolved backend ID
			-- (e.g. "Meta-Llama-3.1-8B-Instruct-4bit"). get_mlx_repo expects the
			-- menu label (e.g. "Llama-3.1-8B-Instruct"). When the resolved ID does
			-- not match any preset, fall back to obj._server_target — the label
			-- of the most recent successful start_server, which is exactly the
			-- server we are trying to restart.
			local resolved_repo = (type(target) == "string" and target ~= "") and obj.get_mlx_repo(target) or nil
			local effective_target = target
			if not resolved_repo and obj._server_target and obj._server_target ~= "" then
				Logger.warn(LOG, "Restart hook target '%s' has no repo — falling back to last server target '%s'.",
					tostring(target), tostring(obj._server_target))
				effective_target = obj._server_target
			end
			if type(effective_target) ~= "string" or effective_target == "" then
				Logger.warn(LOG, "Restart hook invoked without a usable target — ignoring.")
				return
			end
			Logger.warn(LOG, "Restart hook invoked for target='%s' — calling start_server.", effective_target)
			-- Force a fresh launch: clear server_target and the active task entry so
			-- start_server's reuse branch cannot short-circuit. The currently-tracked
			-- task is the one we just hard-killed (or about to); reusing it would
			-- mean returning success against a dead/wrong-model process.
			if deps.active_tasks and deps.active_tasks["mlx_server"] then
				local existing = deps.active_tasks["mlx_server"]
				pcall(function() if type(existing.terminate) == "function" then existing:terminate() end end)
				deps.active_tasks["mlx_server"] = nil
			end
			obj._server_target = nil
			-- on_success / on_cancel are nil here: the prediction layer is already
			-- waiting on its own warmup retry loop and will pick up the new server
			-- automatically once the bash launcher emits the PGID line.
			pcall(obj.start_server, effective_target, nil, nil, { silent_notifications = true })
		end)
	end

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
	-- Single, canonical Python interpreter for every Hammerspoon-driven MLX
	-- invocation. This venv is provisioned by modules/llm/ensure-mlx-deps.sh
	-- on first launch from the pinned pyproject.toml, so its absolute path is
	-- the only one we ever shell out to. Any consumer that hits a missing
	-- interpreter must fail fast — silent fallback to a system python would
	-- bypass the pinned mlx-lm version and reintroduce the very drift we are
	-- trying to eliminate.
	local hs_root = project_root and (project_root .. "/static/drivers/hammerspoon") or ""
	local project_venv_python = hs_root ~= "" and (hs_root .. "/.venv/bin/python") or ""
	if project_venv_python == "" or not hs.fs.attributes(project_venv_python, "mode") then
		-- The auto-bootstrap (lib/mlx_deps_checker) provisions this interpreter
		-- on every reload; if it is still missing here the bootstrap failed and
		-- the user has already been notified.
		Logger.warn(LOG, "Project venv python introuvable à %s — bootstrap auto en échec.",
			tostring(project_venv_python))
	end
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
		-- Custom user-added models are passed straight through: a HuggingFace
		-- repo path ("org/model-name") is the canonical MLX identifier and
		-- mlx_lm.server / huggingface_hub resolve it natively. Without this
		-- fallback, check_requirements would refuse any model the user adds
		-- via the "Ajouter un modèle personnalisé" menu entry.
		if type(model_name) == "string" and model_name:match("^[%w%._%-]+/[%w%._%-]+$") then
			return model_name
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

	function obj.start_server(target_model, on_success, on_cancel, opts)
		local repo = obj.get_mlx_repo(target_model)
		if not repo then
			Logger.warn(LOG, "Cannot start MLX server: no repository found for model %s.", tostring(target_model))
			-- Fire on_cancel so the caller's prediction lock is released; otherwise
			-- predictions stay silently disabled for the rest of the session
			if type(on_cancel) == "function" then pcall(on_cancel) end
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
			Logger.debug(LOG, "Existing MLX task found — running=%s, server_target='%s', target_model='%s'.",
				tostring(running), tostring(obj._server_target), tostring(target_model))
			if running and obj._server_target == target_model then
				Logger.info(LOG, "MLX server already running for model '%s' — reusing, calling on_success.", tostring(target_model))
				if on_success then pcall(on_success) end
				return
			end
			if running then
				Logger.info(LOG, "MLX server running for different model — terminating.")
				pcall(function() existing:terminate() end)
			end
			deps.active_tasks["mlx_server"] = nil
		end

		-- Defensive cross-session port sweep: at this point we are committed to launching
		-- a fresh server. Any python+mlx_lm process still alive — typically a leftover from
		-- a previous Hammerspoon session whose hs.task handle is gone, or an orphan whose
		-- bash wrapper exited but Python child survived — must die before the new server
		-- binds 8080. The bash launcher does its own kill+lsof loop, but it trusts
		-- /tmp/mlx_server.pgid which can be stale; firing this sweep here closes that gap.
		-- Fire-and-forget — the bash launcher's own sleep+lsof retry loop will catch any
		-- survivor that this async kill doesn't reach in time.
		do
			local sweep_cmd =
				"PIDS=$(ps -axo pid=,comm=,args= | awk '$2 ~ /^[Pp]ython/ && /mlx_lm/ {print $1}'); " ..
				"PORT_PIDS=$(lsof -ti TCP:8080 2>/dev/null); " ..
				"ALL=\"$PIDS $PORT_PIDS\"; " ..
				"[ -n \"$(echo $ALL | tr -d ' ')\" ] && echo \"$ALL\" | tr ' ' '\\n' | sort -u | xargs kill -9 2>/dev/null; " ..
				"rm -f /tmp/mlx_server.pid /tmp/mlx_server.pgid; " ..
				"echo done"
			local sweep = hs.task.new("/bin/bash", function(_c, stdout, _e)
				Logger.debug(LOG, "Pre-launch port-8080 sweep done: %s", tostring(stdout):gsub("\n", " "))
			end, {"-c", sweep_cmd})
			pcall(function() sweep:start() end)
		end

		-- Skip the async pre-probe: if a server is already listening, probe_server_ready
		-- will detect it on the first 0.5 s tick. The asyncGet pre-probe was introduced
		-- to short-circuit task creation for an already-running server, but it blocked
		-- all subsequent server-start logic when the HTTP callback was delayed (e.g.
		-- connection refused on macOS can take several seconds to resolve asynchronously),
		-- causing the task to never be created and predictions to stay locked indefinitely.
		do
			obj._server_target = target_model
			-- The new server process may run a different mlx-lm version or be
			-- configured for different routes than the previous one; clear the
			-- cached discovery result so the first warmup re-probes rather than
			-- reusing stale endpoint paths that return 404 for this new server
			if type(ApiMlx) == "table" and type(ApiMlx.reset_endpoints) == "function" then
				ApiMlx.reset_endpoints()
			end
			-- Store the authoritative HF path used to launch the server so the
			-- discovery bypass can fall back to it when /v1/models returns a stale
			-- model ID. Without this, warmup sends the wrong model name and every
			-- request returns 404, creating an infinite discovery-reset loop.
			if type(ApiMlx) == "table" and type(ApiMlx.set_model_hf_path) == "function" then
				ApiMlx.set_model_hf_path(repo)
			end
			-- All MLX server output is funneled into the unified Ergopti log so
			-- the user has a single tail target. Each line is prefixed
			-- [MLX-SERVER] downstream so it stands out from Hammerspoon's own
			-- log entries.
			local unified_log_file = "/tmp/ergopti.log"
			Logger.info(LOG, "Starting MLX server process for model %s — output prefixed [MLX-SERVER] in %s",
				tostring(target_model), unified_log_file)
			local startup_confirmed = false
			local startup_closed = false

			local function mark_server_ready()
				if startup_confirmed or startup_closed then return end
				startup_confirmed = true
				if on_success then pcall(on_success) on_success = nil end
			end

			local function probe_server_ready(retries)
				if startup_closed or startup_confirmed then return end
				if retries <= 0 then
					-- 60 s elapsed without the server answering — release the prediction
					-- lock so the user is not silently stuck; log for diagnosis
					Logger.error(LOG, "MLX server for model '%s' did not become ready within 60s — releasing prediction lock.",
						tostring(target_model))
					if type(on_cancel) == "function" then pcall(on_cancel); on_cancel = nil end
					return
				end
				-- Use curl --no-keepalive so each probe opens a fresh TCP connection.
				-- hs.http pools connections and reuses a keep-alive socket to a zombie
				-- server, making this probe see the zombie's stale model ID indefinitely.
				local probe_task = hs.task.new("/usr/bin/curl", function(exit_code, stdout, _)
					if startup_closed or startup_confirmed then return end
					if exit_code == 0 and probe_matches_target(stdout or "") then
						mark_server_ready()
					else
						hs.timer.doAfter(0.5, function()
							probe_server_ready(retries - 1)
						end)
					end
				end, {
					"--silent", "--max-time", "5", "--no-keepalive",
					"-H", "Connection: close",
					"http://127.0.0.1:8080/v1/models",
				})
				pcall(function() probe_task:start() end)
			end

			-- Every line of MLX stdout/stderr gets:
			--   1. timestamped + prefixed [MLX-SERVER] by a small bash
			--      `while read` loop. The previous awk-based version used
			--      `strftime()` and `fflush(file)` which are gawk extensions
			--      not supported by macOS' default BWK awk — the awk crashed
			--      on the first line, the pipe closed, and the whole MLX
			--      server died on SIGPIPE before producing any output.
			--   2. appended to the unified Ergopti log via `tee -a`
			--   3. ALSO emitted on the bash task's stdout (tee writes both)
			--      so the existing stream callback (server_log_buffer /
			--      crash detector / ready probe) keeps working unchanged.
			local bash_cmd =
				"export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; " ..
				"export SSL_CERT_FILE=/etc/ssl/cert.pem; " ..
				"export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem; " ..
				"export HF_HUB_DISABLE_XET=1; " ..
				-- HF_HUB_OFFLINE=1 forces huggingface_hub to use ONLY the local cache
				-- and skip every HTTPS call to huggingface.co. Required behind a
				-- corporate proxy with a self-signed root CA, because the httpx
				-- client used by huggingface_hub>=1.x ignores SSL_CERT_FILE /
				-- REQUESTS_CA_BUNDLE and uses its own SSL context — a single
				-- snapshot-validation call on first inference would fail with
				-- CERTIFICATE_VERIFY_FAILED and crash mlx_lm's _generate thread.
				-- TRANSFORMERS_OFFLINE=1 mirrors the policy for transformers.
				"export HF_HUB_OFFLINE=1; " ..
				"export TRANSFORMERS_OFFLINE=1; " ..
				"export PYTHONUNBUFFERED=1; " ..
				-- Fail fast if the pinned project venv is missing — any other Python
				-- would bypass the pinned mlx-lm version
				"PYTHON_BIN=\"" .. project_venv_python_escaped .. "\"; " ..
				"if [ ! -x \"$PYTHON_BIN\" ]; then echo \"[MLX] ❌ venv introuvable : $PYTHON_BIN\"; exit 1; fi; " ..
				"echo \"[MLX] Python utilisé: $PYTHON_BIN\"; " ..
				-- Kill strategy: setsid launches Python in its own process group so we
				-- can kill the entire tree (Python + any fork()+exec() children whose
				-- argv no longer contains 'mlx_lm') with a single `kill -PGID`. This
				-- is the only reliable approach: pgrep misses exec-replaced argv,
				-- lsof misses processes between accept() calls, and PID-only kill
				-- leaves orphaned children alive. Three steps, each increasingly broad:
				--   1. PGID file: kill the whole process group of the previous server.
				--   2. pgrep fallback: catch any surviving mlx_lm process by argv.
				--   3. lsof fallback: last resort for anything still holding port 8080.
				"MLX_PID_FILE=/tmp/mlx_server.pid; " ..
				"MLX_PGID_FILE=/tmp/mlx_server.pgid; " ..
				-- IMPORTANT: we used to also kill by saved PGID (kill -9 -<PGID>) here.
				-- That turned out to be unsafe on macOS: PIDs/PGIDs are aggressively
				-- recycled, and after a Hammerspoon reload the recorded PGID could
				-- legitimately belong to the new Hammerspoon process (or any other
				-- innocent app), making `kill -9 -<PGID>` a roulette that tore down
				-- the menubar mid-switch. We now rely exclusively on the PID-based
				-- kill below — targeted, safe, and sufficient for cleaning up the
				-- previous mlx_lm.server. The PGID file is still written by the
				-- launcher (kept for future debugging) but ignored on shutdown.
				"if [ -f \"$MLX_PGID_FILE\" ]; then " ..
				"OLD_PGID=$(cat \"$MLX_PGID_FILE\" 2>/dev/null | tr -d '[:space:]'); " ..
				"echo \"[MLX] Skipping PGID-kill of $OLD_PGID — PID-based kill is safer on macOS.\"; " ..
				"rm -f \"$MLX_PGID_FILE\"; " ..
				"fi; " ..
				-- Step 1: kill by PID (the recorded mlx_lm.server pid). Targeted
				-- and safe — no risk of hitting an unrelated process via PGID
				-- recycling.
				"if [ -f \"$MLX_PID_FILE\" ]; then " ..
				"OLD_PID=$(cat \"$MLX_PID_FILE\" 2>/dev/null | tr -d '[:space:]'); " ..
				"if [ -n \"$OLD_PID\" ] && kill -0 \"$OLD_PID\" 2>/dev/null; then " ..
				-- macOS aggressively recycles PIDs after a Hammerspoon reload, so the
				-- PID we wrote at launch may now belong to ANY process — including
				-- Hammerspoon itself. Verify the process is still a python interpreter
				-- running mlx_lm before issuing kill -9; otherwise we risk taking
				-- down the menubar app on every model switch.
				"OLD_COMM=$(ps -o comm= -p \"$OLD_PID\" 2>/dev/null | tr -d '[:space:]'); " ..
				"OLD_ARGS=$(ps -o args= -p \"$OLD_PID\" 2>/dev/null); " ..
				"if echo \"$OLD_COMM\" | grep -qi python && echo \"$OLD_ARGS\" | grep -q mlx_lm; then " ..
				"echo \"[MLX] Killing previous server PID $OLD_PID (verified python+mlx_lm)…\"; " ..
				"kill -9 \"$OLD_PID\" 2>/dev/null || true; " ..
				"else " ..
				"echo \"[MLX] ⚠️  PID $OLD_PID is alive but not a python+mlx_lm process (comm='$OLD_COMM') — refusing to kill (PID was recycled, likely Hammerspoon).\"; " ..
				"fi; " ..
				"else " ..
				"echo \"[MLX] PID file stale (PID $OLD_PID not running).\"; " ..
				"fi; " ..
				"rm -f \"$MLX_PID_FILE\"; " ..
				"fi; " ..
				-- Step 2: argv fallback — filter on COMM (executable basename), not on the
				-- full argv. A bare pgrep -f 'python.*mlx_lm' also matches THIS bash wrapper:
				-- its argv is "/bin/bash -c <SCRIPT>", and the script text literally contains
				-- the substring 'python… -m mlx_lm', so the regex hits it. Killing that PID
				-- is suicide on the Hammerspoon-watched task. Using $2 (comm) instead skips
				-- bash cleanly: only processes whose executable starts with python qualify.
				"PGREP_PIDS=$(ps -axo pid=,comm=,args= | awk '$2 ~ /^[Pp]ython/ && /mlx_lm/ {print $1}' || true); " ..
				"if [ -n \"$PGREP_PIDS\" ]; then " ..
				"echo \"[MLX] mlx_lm process(es) still alive (PIDs: $PGREP_PIDS) — killing…\"; " ..
				"echo \"$PGREP_PIDS\" | xargs kill -9 2>/dev/null || true; " ..
				"sleep 1; " ..
				"fi; " ..
				-- Step 3: lsof retry loop — port 8080 must be free before we start.
				-- The initial sleep gives the kernel time to finish releasing the socket
				-- after kill -9 AND lets any SO_REUSEPORT zombie re-bind so that lsof
				-- can see it. Without this pause, lsof catches the port "free" during
				-- the brief window between kill -9 and the zombie re-binding, allowing
				-- both processes to co-exist. 3 s is long enough for the zombie to
				-- re-bind while short enough to not frustrate the user.
				"sleep 3; " ..
				"LSOF_ATTEMPTS=0; " ..
				"while true; do " ..
				"STALE_PIDS=$(lsof -ti TCP:8080 2>/dev/null || true); " ..
				"if [ -z \"$STALE_PIDS\" ]; then " ..
				"echo \"[MLX] Port 8080 free — starting server.\"; " ..
				"break; " ..
				"fi; " ..
				"LSOF_ATTEMPTS=$((LSOF_ATTEMPTS + 1)); " ..
				"echo \"[MLX] Port 8080 still occupied attempt $LSOF_ATTEMPTS (PIDs: $STALE_PIDS) — killing…\"; " ..
				"echo \"$STALE_PIDS\" | xargs kill -9 2>/dev/null || true; " ..
				"if [ \"$LSOF_ATTEMPTS\" -ge 10 ]; then " ..
				"echo \"[MLX] ❌ Port 8080 still occupied after 10 attempts — giving up.\"; " ..
				"exit 1; " ..
				"fi; " ..
				"sleep 0.5; " ..
				"done; " ..
				-- Launch Python in background, capture PID, write PID file, then attach
				-- the output loop to the background process via wait + fd redirect.
				-- Using a named FIFO lets us attach the streaming pipeline to a backgrounded
				-- process without /proc (Linux-only). The FIFO is created once per start,
				-- the Python server writes into it (via exec redirect), and the while-read
				-- loop drains it for as long as the server lives.
				"MLX_FIFO=$(mktemp -u /tmp/mlx_out.XXXXXX); " ..
				"mkfifo \"$MLX_FIFO\"; " ..
				-- set -m (job control) makes bash assign a fresh PGID to every
				-- backgrounded job — the macOS-compatible replacement for Linux setsid.
				-- set +m immediately after so the rest of the script is unaffected.
				"set -m; " ..
				-- Resolve the local snapshot path BEFORE invoking mlx_lm. Passing
				-- the HF repo id (e.g. mlx-community/Qwen3.5-2B-4bit) makes mlx_lm
				-- call huggingface_hub.snapshot_download which, even in offline
				-- mode (HF_HUB_OFFLINE=1), insists on resolving a refs/main entry
				-- and a specific revision and crashes with "Cannot find an
				-- appropriate cached snapshot folder for the specified revision"
				-- when those metadata files are missing — common in caches built
				-- by alternative downloaders. By passing the snapshot directory
				-- directly as --model, mlx_lm treats it as a local path and
				-- bypasses huggingface_hub entirely.
				"REPO_ID=\"" .. repo .. "\"; " ..
				"CACHE_NAME=\"models--$(echo \"$REPO_ID\" | sed 's|/|--|g')\"; " ..
				"CACHE_ROOT=\"$HOME/.cache/huggingface/hub/$CACHE_NAME\"; " ..
				"SNAPSHOT_DIR=$(ls -dt \"$CACHE_ROOT/snapshots/\"*/ 2>/dev/null | head -1); " ..
				"if [ -n \"$SNAPSHOT_DIR\" ] && [ -d \"$SNAPSHOT_DIR\" ]; then " ..
				"MODEL_ARG=\"${SNAPSHOT_DIR%/}\"; " ..
				"echo \"[MLX] Using local snapshot path: $MODEL_ARG\"; " ..
				-- Persist the resolved snapshot path so api_mlx can use the SAME
				-- value in the "model" field of every POST payload. mlx_lm.server
				-- routes each request through model_provider.load() keyed by the
				-- payload's "model" string; if we send the repo id instead of the
				-- local path, the server tries snapshot_download on the repo and
				-- fails with the offline error. Identical strings → cache hit on
				-- the model loaded at boot, no HF call.
				"echo \"$MODEL_ARG\" > /tmp/mlx_active_model.txt; " ..
				-- mlx-lm 0.31.x's _download() always calls huggingface_hub
				-- snapshot_download even when the --model argument is an
				-- absolute local path. With HF_HUB_OFFLINE=1, snapshot_download
				-- still needs refs/<revision> on disk to resolve the snapshot
				-- hash; if that file is missing (caches built by uv, partial
				-- downloads, or pre-1.x hf-xet leave it out), the call fails
				-- with "Cannot find an appropriate cached snapshot folder for
				-- the specified revision" and every inference returns 404 with
				-- that error body. Synthesize refs/main from the snapshot dir
				-- name (which IS the commit hash) so the resolver succeeds.
				"REVISION=$(basename \"$MODEL_ARG\"); " ..
				"mkdir -p \"$CACHE_ROOT/refs\"; " ..
				"if [ ! -f \"$CACHE_ROOT/refs/main\" ]; then " ..
				"echo \"$REVISION\" > \"$CACHE_ROOT/refs/main\"; " ..
				"echo \"[MLX] Wrote refs/main = $REVISION (was missing — required by HF offline mode).\"; " ..
				"fi; " ..
				"else " ..
				"MODEL_ARG=\"$REPO_ID\"; " ..
				"echo \"[MLX] No local snapshot found for $REPO_ID — falling back to repo id.\"; " ..
				"echo \"$REPO_ID\" > /tmp/mlx_active_model.txt; " ..
				"fi; " ..
				-- --decode-concurrency 1 --prompt-concurrency 1 disables mlx-lm's
				-- BatchGenerator which is broken in 0.31.x: filtering across worker
				-- threads triggers `RuntimeError: There is no Stream(gpu, 0) in
				-- current thread` and the generate thread dies before sending the
				-- response body, leaving the client hanging on a 200 with empty body.
				-- Forcing serial execution sidesteps the bug entirely; for our
				-- single-user prediction use case batching brought no benefit anyway.
				"\"$PYTHON_BIN\" -m mlx_lm server --model \"$MODEL_ARG\" --decode-concurrency 1 --prompt-concurrency 1 > \"$MLX_FIFO\" 2>&1 & " ..
				"MLX_PID=$!; " ..
				"set +m; " ..
				"MLX_PGID=$(ps -o pgid= -p $MLX_PID 2>/dev/null | tr -d ' ' || echo ''); " ..
				"echo \"[MLX] Server started with PID $MLX_PID PGID $MLX_PGID.\"; " ..
				"echo \"$MLX_PID\" > \"$MLX_PID_FILE\"; " ..
				-- Persist the PGID only if `set -m` actually isolated python into its
				-- own process group. If MLX_PGID equals our own bash PGID or our
				-- parent's (Hammerspoon's), saving it would arm a fratricidal
				-- `kill -9 -<PGID>` on the next switch that wipes the menubar app.
				"OWN_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]'); " ..
				"PARENT_PGID=$(ps -o pgid= -p $PPID 2>/dev/null | tr -d '[:space:]'); " ..
				"if [ -n \"$MLX_PGID\" ] && [ \"$MLX_PGID\" != \"$OWN_PGID\" ] && [ \"$MLX_PGID\" != \"$PARENT_PGID\" ]; then " ..
				"echo \"$MLX_PGID\" > \"$MLX_PGID_FILE\"; " ..
				"echo \"[MLX] Persisted PGID $MLX_PGID (isolated from Hammerspoon group $PARENT_PGID).\"; " ..
				"else " ..
				"echo \"[MLX] ⚠️  set -m did not isolate python (MLX_PGID=$MLX_PGID, own=$OWN_PGID, parent=$PARENT_PGID) — NOT persisting PGID. Will rely on PID-only kill on next switch.\"; " ..
				"rm -f \"$MLX_PGID_FILE\"; " ..
				"fi; " ..
				"while IFS= read -r LINE; do " ..
				"OUT=\"$(date +%H:%M:%S) [MLX-SERVER] $LINE\"; " ..
				"printf '%s\\n' \"$OUT\"; " ..
				"printf '%s\\n' \"$OUT\" >> " .. unified_log_file .. "; " ..
				"done < \"$MLX_FIFO\"; " ..
				"rm -f \"$MLX_FIFO\""

			local server_last_line = ""
			local server_log_buffer = {}
			local crash_recovery_triggered = false

			-- Auto-recovery: when mlx_lm.server crashes loading the model (most often
			-- because HuggingFace shipped a new architecture / quantization format
			-- the local mlx-lm wheel does not yet understand), we get a Python
			-- traceback in the server stdout but the HTTP listener stays up and
			-- every request hangs forever. Detect those signature errors, kill the
			-- server, force-upgrade the MLX stack, and restart — once per model
			-- per Hammerspoon session to avoid loops.
			local function looks_like_arch_mismatch(text)
				if type(text) ~= "string" or text == "" then return false end
				-- Only match patterns that PROVE a model-loading failure. Earlier we
				-- also matched the bare 'Exception in thread Thread-1 (_generate)'
				-- header, which turned out to be a false positive: mlx-lm prints
				-- that line whenever its background generation thread sees an
				-- unexpected request (e.g. a 404 due to an endpoint route mismatch),
				-- and our recovery would then needlessly tear down a perfectly
				-- healthy server that just had a routing problem we should fix
				-- elsewhere.
				return text:find("Received %d+ parameters not in model")  ~= nil
				    or text:find("Missing %d+ parameters")                 ~= nil
				    or text:find("Unsupported model type",      1, true)   ~= nil
				    or text:find("ModuleNotFoundError",         1, true)   ~= nil
				    or text:find("ImportError",                 1, true)   ~= nil
			end

			--- Dumps the in-memory ring buffer (last ~15 lines captured live from
			--- the MLX server stdout) into the Hammerspoon log so the Python
			--- traceback header that triggered the crash detection lands in the
			--- same log file as everything else. The full server output is
			--- separately mirrored line-by-line into /tmp/ergopti.log via the
			--- awk prefixer, so the user can grep for [MLX-SERVER] there to see
			--- the complete trace if they need more than the last 15 lines.
			local function dump_mlx_server_log(prefix)
				if #server_log_buffer == 0 then
					Logger.warn(LOG, "%s — no buffered server lines to dump (tail %s).",
						prefix, unified_log_file)
					return
				end
				-- Only the summary line fires a notification (via Logger.error);
			-- individual trace lines use Logger.warn to avoid spamming the user
			-- with 15 separate macOS notifications for one crash event
			Logger.error(LOG, "%s — last %d line(s) from MLX server stdout (full trace in %s):",
					prefix, #server_log_buffer, unified_log_file)
				for _, line in ipairs(server_log_buffer) do
					if line:match("%S") then Logger.warn(LOG, "  | %s", line) end
				end
			end

			local function trigger_auto_recovery(reason_line)
				if crash_recovery_triggered then return end
				crash_recovery_triggered = true

				Logger.error(LOG, "MLX server for ‘%s’ crashed — giving up. Reason: %s",
					tostring(target_model), tostring(reason_line))
				dump_mlx_server_log("MLX crash for ‘" .. tostring(target_model) .. "’")
				if not silent_notifications then
					pcall(notifications.notify, "❌ MLX incompatible",
						"Le modèle " .. tostring(target_model) ..
						" n’est pas compatible avec mlx-lm. Choisissez un autre modèle.")
				end
				-- Release the caller’s prediction lock so the user can switch to a working
				-- model without having to reload Hammerspoon
				if on_cancel then pcall(on_cancel) end
			end

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
					-- Release prediction lock so future predictions are not silently disabled
					if type(on_cancel) == "function" then pcall(on_cancel); on_cancel = nil end
					return
				end

				if code ~= 0 then
					-- Look for the most informative line in the in-memory ring buffer
					-- (last ~15 lines captured live). The full server output is in
					-- /tmp/ergopti.log behind the [MLX-SERVER] prefix if needed.
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

					if error_msg ~= "" then
						Logger.error(LOG, "MLX server for model ‘%s’ crashed (code %d): %s", tostring(target_model), code, error_msg)
					else
						Logger.error(LOG, "MLX server for model ‘%s’ crashed (code %d).", tostring(target_model), code)
					end
					-- Release prediction lock so the session is not silently broken
					-- after an architecture-mismatch crash or any other startup failure
					if type(on_cancel) == "function" then pcall(on_cancel); on_cancel = nil end
				end

				Logger.info(LOG, "MLX server process exited with code %d.", code)
			end, function(_, stdout, stderr)
				local out = (stdout or "") .. (stderr or "")
				if out ~= "" then
					Logger.debug(LOG, "MLX server stream chunk (%d bytes).", #out)
				end
				for line in out:gmatch("([^\n\r]+)") do
					server_last_line = line
					table.insert(server_log_buffer, line)
					while #server_log_buffer > 15 do table.remove(server_log_buffer, 1) end
					Logger.debug(LOG, "MLX server: %s", line)
					-- Inform api_mlx of the active server PGID as soon as bash reports it.
					-- The zombie-kill logic excludes the entire process group (bash wrapper
					-- + Python mlx_lm child) so it never terminates the server we just
					-- launched. PGID is used instead of PID because SO_REUSEPORT makes
					-- lsof only see the bash wrapper, not the Python child on the socket.
					local pgid_str = line:match("%[MLX%] Server started with PID %d+ PGID (%d+)")
					if pgid_str and type(ApiMlx) == "table" and type(ApiMlx.set_active_server_pgid) == "function" then
						ApiMlx.set_active_server_pgid(tonumber(pgid_str))
					end
				end
				if out:find("Starting httpd at") or out:find("Uvicorn running on") or out:find("Application startup complete") then
					mark_server_ready()
				end
				-- Lazy-loaded model crashes happen *after* the HTTP listener is up,
				-- so this detection must run on every stream chunk — not only on
				-- process exit (the process never exits when this happens)
				if not crash_recovery_triggered and looks_like_arch_mismatch(out) then
					trigger_auto_recovery(server_last_line)
				end
				return true
			end, { "-c", bash_cmd })

			Logger.debug(LOG, "MLX server bash_cmd: %s", bash_cmd)
			if task then
				deps.active_tasks["mlx_server"] = task
				local ok, start_err = pcall(function() task:start() end)
				if ok then
					Logger.info(LOG, "MLX server task started for model ‘%s’.", tostring(target_model))
				else
					Logger.error(LOG, "MLX server task:start() failed for model ‘%s’: %s", tostring(target_model), tostring(start_err))
					if type(on_cancel) == "function" then pcall(on_cancel); on_cancel = nil end
					return
				end
				-- 120 retries × 0.5 s = 60 s total; large models can take >30 s to load weights
				probe_server_ready(120)
			else
				Logger.error(LOG, "Failed to create hs.task for MLX server — model ‘%s’ cannot start.", tostring(target_model))
				if type(on_cancel) == "function" then pcall(on_cancel); on_cancel = nil end
			end
		end
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
			-- Pin to the project venv: any other interpreter would bypass the
			-- versions pinned in pyproject.toml. Fail fast if it is missing.
			f:write("PYTHON_BIN=\"" .. script_project_venv_python_escaped .. "\"\n")
			f:write("if [ ! -x \"$PYTHON_BIN\" ]; then\n")
			f:write("  echo \"[MLX] ❌ venv introuvable : $PYTHON_BIN — rechargez Hammerspoon (bootstrap auto)\"\n")
			f:write("  exit 1\n")
			f:write("fi\n")
			f:write("echo \"Python utilisé: $PYTHON_BIN\"\n")
			f:write("export HF_HUB_DISABLE_SYMLINKS_WARNING=1\n")
			f:write("export PYTHONUNBUFFERED=1\n")
			f:write("export SSL_CERT_FILE=/etc/ssl/cert.pem\n")
			f:write("export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem\n")
			f:write("export HF_HUB_DISABLE_XET=1\n")
			-- Dependencies are pinned in pyproject.toml and installed by uv pip
			-- sync — no runtime install/upgrade. Just verify the imports succeed.
			f:write("\"$PYTHON_BIN\" -c 'import huggingface_hub, truststore' >/dev/null 2>&1 || { echo '[MLX] ❌ huggingface_hub/truststore manquants — relancez ensure-mlx-deps.sh'; exit 1; }\n")
			f:write("\"$PYTHON_BIN\" -c 'import hf_transfer' 2>/dev/null && export HF_HUB_ENABLE_HF_TRANSFER=1 || export HF_HUB_ENABLE_HF_TRANSFER=0\n")
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

		-- Dependencies are pinned in pyproject.toml and provisioned by
		-- ensure-mlx-deps.sh on Hammerspoon startup; no runtime upgrade path.
		_internal_pull()
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
				obj.start_server(target_model, on_success, on_cancel, opts)
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

		-- Verify the pinned project venv has every required MLX dependency
		-- importable. If it does not, the venv is broken / out of sync and the
		-- user must run modules/llm/ensure-mlx-deps.sh manually — silently
		-- pip-installing a fallback would bypass pyproject.toml.
		local check_cmd = "\"" .. project_venv_python_escaped .. "\" -c 'import mlx_lm; import huggingface_hub; import jinja2; import safetensors'"
		local check_task = hs.task.new("/bin/bash", function(code)
			if code == 0 then
				do_check()
			else
				-- Differentiate three cases so the user sees the truth:
				--   1. bootstrap still running → "patientez", do not flip to error
				--   2. bootstrap failed        → show the actual stderr cause
				--   3. unknown                 → previous generic message
				if mlx_deps_checker and mlx_deps_checker.is_pending and mlx_deps_checker.is_pending() then
					Logger.info(LOG, "MLX import probe failed but bootstrap still pending — launching install.")
					-- Show the progress window and kick off the actual install.
					-- The checker is idempotent: if it is already running, the second
					-- call exits silently; if it was never started (e.g., LLM was
					-- disabled at startup), this is the first real launch.
					local llm_progress = require("ui.download_window")
					if not llm_progress.is_active() then
						pcall(llm_progress.show, {
							kind     = "mlx_install",
							title    = "Initialisation du moteur IA (MLX)",
							subtitle = "Initialisation IA en cours, veuillez patienter…",
						})
					end
					pcall(mlx_deps_checker.check_and_install_deps)
				elseif mlx_deps_checker and mlx_deps_checker.has_failed and mlx_deps_checker.has_failed() then
					local cause = (mlx_deps_checker.get_failure_message and mlx_deps_checker.get_failure_message())
						or "Cause inconnue. Consultez la console Hammerspoon."
					Logger.error(LOG, "MLX dependencies missing — bootstrap definitively failed: %s",
						tostring(cause):gsub("\n", " | "))
					pcall(notifications.notify, "❌ Dépendances MLX manquantes", cause)
				else
					Logger.error(LOG, "MLX dependencies missing in %s — auto-bootstrap may have failed.", project_venv_python_escaped)
					pcall(notifications.notify, "❌ Dépendances MLX manquantes",
						"Le bootstrap automatique du venv a échoué. Rechargez Hammerspoon et consultez la console.")
				end
				if on_cancel then pcall(on_cancel) end
			end
		end, {"-c", check_cmd})
		
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
