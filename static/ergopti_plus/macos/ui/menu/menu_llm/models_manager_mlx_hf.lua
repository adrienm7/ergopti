--- ui/menu/menu_llm/models_manager_mlx_hf.lua

--- ==============================================================================
--- MODULE: MLX Models Manager — HuggingFace Auth & Model Source
--- DESCRIPTION:
--- Attaches the HuggingFace login flow and model-source/repo helpers onto the
--- shared MLX models-manager object. Resolves a model's MLX repo, opens its
--- HuggingFace page, drives the token-entry webview, and persists a validated
--- token through a Python subprocess.
---
--- FEATURES & RATIONALE:
--- 1. Shared-context mixin: install(ctx) attaches its methods onto ctx.obj, so the
---    factory's other methods (start_server, check_requirements) keep calling
---    obj.get_mlx_repo unchanged while this auth/catalogue logic lives on its own.
--- 2. Self-contained auth: the token webview and its validation subprocess are
---    isolated from the server-lifecycle and download logic.
--- 3. Shared token frontend: prompt_hf_login loads the token UI from the
---    cross-driver _shared/ui/token_prompt/ tree (resolved via Paths.shared), so
---    the same frontend can later back a Windows WebView2 host.
--- ==============================================================================

local M = {}

local hs            = hs
local notifications = require("lib.notifications")
local ui_builder    = require("ui.ui_builder")
local i18n          = require("lib.i18n")
local Paths         = require("lib.paths")

local HF_TOKEN_FILE = (os.getenv("HOME") or "") .. "/.huggingface/token"




-- =====================================================
--- =====================================================
-- ======= 1/ HuggingFace Auth & Model Source =========
--- =====================================================
-- =====================================================

--- Attaches the HuggingFace auth + model-source methods onto the manager object.
--- @param ctx table Shared context: { obj = manager object, deps = injected deps,
---   presets = model catalogue }.
function M.install(ctx)
	local obj, deps, presets = ctx.obj, ctx.deps, ctx.presets

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
						return (m.urls.mlx:gsub("^https?://huggingface%.co/", ""))
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
			pcall(notifications.notify, i18n.get("mlx.source_not_found"), i18n.get("mlx.source_not_found_body"), "error")
			return false
		end

		local url = "https://huggingface.co/" .. repo
		local ok_open = pcall(hs.urlevent.openURL, url)
		if not ok_open then
			pcall(notifications.notify, i18n.get("mlx.source_not_found"), i18n.get("mlx.open_source_failed"), "error")
			return false
		end

		pcall(notifications.notify, i18n.get("mlx.hf_login_title"), i18n.get("mlx.hf_page_opened"), "info")
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
			-- The token_prompt frontend now lives in the cross-driver _shared/ui/
			-- tree (shared with a future Windows host); resolve it via Paths.shared.
			local TOKEN_ASSETS_DIR = (Paths.shared("ui/token_prompt") or "") .. "/"

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
						pcall(notifications.notify, i18n.get("mlx.token_detected"), i18n.get("mlx.token_detected_body"), "success")
					elseif token ~= "" and token_seed ~= "" and #token_seed > #token and token_seed:sub(-#token) == token then
						token = token_seed
						pcall(notifications.notify, i18n.get("mlx.token_corrected"), i18n.get("mlx.token_corrected_body"), "success")
					end

					if token == "" then
						pcall(notifications.notify, i18n.get("mlx.token_missing"), i18n.get("mlx.token_missing_body"), "error")
						if type(on_done) == "function" then pcall(on_done, false) end
						return
					end

					obj._process_hf_token(token, on_done)
				end
			end)

			local screen = hs.screen.mainScreen()
			local f = screen and type(screen.frame) == "function" and screen:frame() or {x=0, y=0, w=1920, h=1080}

			local W, H = 1560, 400
			local frame = {
				x = math.floor(f.x + (f.w - W) / 2),
				y = math.floor(f.y + (f.h - H) / 2),
				w = W,
				h = H
			}

			_token_wv = ui_builder.show_webview({
				frame             = frame,
				title             = i18n.get("mlx.hf_login_title"),
				style_masks       = {"titled", "closable", "nonactivating"},
				level             = hs.drawing.windowLevels.floating,
				allow_text_entry  = true,
				allow_new_windows = false,
				usercontent       = _ucc,
				assets_dir        = TOKEN_ASSETS_DIR,
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
				pcall(notifications.notify, i18n.get("mlx.hf_connected"), i18n.get("mlx.hf_connected_body"), "success")
				if type(on_done) == "function" then pcall(on_done, true) end
			else
				pcall(notifications.notify, i18n.get("mlx.hf_login_title"), i18n.get("mlx.hf_connection_failed_body"), "error")
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
			pcall(notifications.notify, i18n.get("mlx.hf_connection_failed"), nil, "error")
			if type(on_done) == "function" then pcall(on_done, false) end
		end
	end
end

return M
