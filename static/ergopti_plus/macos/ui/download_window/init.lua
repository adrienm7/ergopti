--- ui/download_window/init.lua

--- ==============================================================================
--- MODULE: Unified Download / Install Progress Window UI
--- DESCRIPTION:
--- Single floating webview UI used for every long-running LLM operation:
---  • Model downloads (Ollama / MLX) — bytes, ETA, log tail, retry/cancel
---    buttons. This is the historical use case and remains the default.
---  • Engine bootstraps (MLX install, Ollama install) — title, step label,
---    verbose detail line, accent stripe per kind. Replaces the legacy
---    canvas-based ui.llm_progress module so the user always sees the same
---    visual language regardless of which backend or operation is running.
---
--- FEATURES & RATIONALE:
--- 1. Decoupled Processing: Uses ui_builder to inject CSS and JS content securely.
--- 2. Space Teleportation: Window natively follows the user via the builder.
--- 3. GB formatting support: Understands GB number payloads directly from
---    hardware_requirements.
--- 4. Kind-driven personalisation: callers pass an opts.kind identifier
---    (mlx_install / ollama_install / mlx_model / ollama_model). The webview
---    derives the title, accent color and default subtitle from a single
---    PRESETS table — no caller ever needs to know the styling rules.
--- 5. Two modes, one window: bootstrap mode hides the bytes/ETA/log machinery
---    and surfaces a step + detail + indeterminate progress bar; download
---    mode keeps the rich download UX. Mode is derived from the kind.
--- ==============================================================================

local M = {}

local Logger     = require("infra.logger")
local DeferredWork = require("infra.deferred_work")
local Paths      = require("infra.paths")
local ShellRunner = require("adapters.shell_runner")
local ui_builder = require("ui.ui_builder")
local i18n       = require("infra.i18n")
local text_utils = require("infra.text_utils")

local LOG = "download_window"

local _wv        = nil
local _on_abort  = nil
local _on_cancel = nil
local _on_resolve = nil
local _on_retry_start = nil
local _on_retry  = nil
local _start_ts  = nil
local _ready     = false
local _queued    = {}
local _log_shown = false
local _is_hiding = false
-- Monotonic id of the current occupant of this shared window, bumped by M.show().
-- Callers that arm a deferred hide capture it and re-check before hiding, so a
-- late timer belonging to a finished operation cannot close a newer one.
local _session   = 0
local _kind      = nil      -- Active kind, if any (mlx_install, ollama_install, mlx_model, ollama_model)
local _mode      = "download" -- "download" (model download) or "bootstrap" (engine install)

-- HTML/CSS/JS assets live in the cross-platform _shared/ folder so all drivers
-- benefit from the same UI without duplication. Resolved through the single
-- shared-tree resolver (Paths.shared); the trailing slash is preserved because
-- ui_builder concatenates asset filenames directly onto this directory.
local ASSETS_DIR = (Paths.shared("ui/download_window") or "") .. "/"


-- Per-kind presets (titles / subtitles / accent colors). Kept in Lua so
-- non-webview callers can also introspect them; rendered values are pushed
-- to the webview at show time via setKind().
local PRESETS = {
	mlx_install = {
		mode             = "bootstrap",
		default_title    = i18n.get("mlx.install_title"),
		default_subtitle = i18n.get("mlx.install_subtitle"),
		accent           = "#4da6ff",
	},
	ollama_install = {
		mode             = "bootstrap",
		default_title    = i18n.get("ollama.install_title"),
		default_subtitle = i18n.get("ollama.install_subtitle"),
		accent           = "#73d98c",
	},
	mlx_model = {
		mode             = "download",
		default_title    = i18n.get("mlx.download_title"),
		default_subtitle = i18n.get("mlx.download_subtitle"),
		accent           = "#9973f2",
	},
	ollama_model = {
		mode             = "download",
		default_title    = i18n.get("ollama.download_title"),
		default_subtitle = i18n.get("ollama.download_subtitle"),
		accent           = "#f2bf4d",
	},
}

-- Auto-dismiss delay applied after set_error before the window fades. Keeps
-- the failure message readable without forcing the user to dismiss it.
local ERROR_AUTO_DISMISS_SEC = 8.0

--- Invokes one external window controller through the central visible boundary.
--- @param label string Context included in the ERROR log on failure.
--- @param callback function|nil External controller callback.
--- @param ... any Callback arguments.
local function invoke_controller(label, callback, ...)
	if type(callback) ~= "function" then return end
	Logger.callback(LOG, label, callback, ...)
end





-- ====================================
-- ====================================
-- ======= 1/ Javascript Bridge =======
-- ====================================
-- ====================================

local _ucc = hs.webview.usercontent.new("dl_bridge")
_ucc:setCallback(function(msg)
		if type(msg) ~= "table" then return end

		if msg.body == "cancel" then
				invoke_controller("Download abort callback", _on_abort)
				invoke_controller("Download cancel callback", _on_cancel)

		elseif msg.body == "resolve" then
				invoke_controller("Download resolve callback", _on_resolve)

		elseif msg.body == "retry" then
				invoke_controller("Download retry-start callback", _on_retry_start)
				invoke_controller("Download retry callback", _on_retry)

		elseif msg.body == "terminal" then
				-- In bootstrap mode, show the live Hammerspoon log; in download mode, use the model-specific cmd
				local cmd = _mode == "bootstrap" and ("tail -f " .. Logger.UNIFIED_LOG_FILE) or (M._terminal_cmd or ("ollama pull " .. (M._current_model or "")))
				-- ShellRunner passes this source directly to osascript as argv, so only
				-- the AppleScript string literal needs escaping and the WebView callback
				-- returns immediately while Terminal launches (HS-196).
				local apple_script = text_utils.applescript_format(
						'tell application "Terminal"\ndo script "%s"\nactivate\nend tell', cmd)
				local started = ShellRunner.applescript(apple_script, function(success)
						if success ~= true then
								Logger.error(LOG, "Terminal AppleScript failed after launch.")
						end
				end)
				if started ~= true then
						Logger.error(LOG, "Terminal AppleScript could not start.")
				end

		elseif msg.body == "expand" then
				if _wv and type(_wv.frame) == "function" then
						local current = _wv:frame()
						local screen = hs.screen.mainScreen()
						local sf = screen and type(screen.frame) == "function" and screen:frame() or { x = 0, y = 0, w = 1920, h = 1080 }
						local target_h = math.floor((sf.h or 1080) * 0.5)

						if target_h > current.h then
								local bottom = current.y + current.h
								local new_frame = {
										x = current.x,
										y = bottom - target_h,
										w = current.w,
										h = target_h,
								}
								pcall(function() _wv:frame(new_frame) end)
						end
				end
		end
end)





-- ===================================
-- ===================================
-- ======= 2/ Formatting Tools =======
-- ===================================
-- ===================================

--- Formats bytes into a human-readable string.
--- @param b number The amount in bytes.
--- @return string|nil The formatted string.
local function fmt_bytes(b)
		if type(b) ~= "number" or b <= 0 then return nil end
		if b > 1e9 then return string.format("%.1f Go", b / 1e9) end
		if b > 1e6 then return string.format("%.0f Mo", b / 1e6) end
		return string.format("%.0f Ko", b / 1e3)
end

--- Formats a raw size value properly whether it's bytes or GB.
--- @param val any The value to format.
--- @return string|nil The cleanly formatted size string.
local function format_size(val)
		if type(val) == "string" then return val end
		if type(val) == "number" then
				-- High magnitude means bytes. Low magnitude means GB
				if val > 1e6 then return fmt_bytes(val) end
				return string.format("%.1f Go", val)
		end
		return nil
end

--- Formats seconds into a human-readable time string.
--- @param s number Seconds.
--- @return string|nil The formatted string.
local function fmt_time(s)
		if type(s) ~= "number" or s <= 0 or s ~= s or s == math.huge then return nil end
		if s > 3600 then return string.format("%dh %02dm", math.floor(s / 3600), math.floor((s % 3600) / 60)) end
		if s > 60   then return string.format("%dm %02ds", math.floor(s / 60), math.floor(s % 60)) end
		return string.format("%ds", math.floor(s))
end

--- Safely escapes a string for injection into JavaScript.
--- @param s string|nil The input string.
--- @return string The escaped string wrapped in quotes.
local function js_str(s)
		if not s then return "null" end
		return "\"" .. tostring(s):gsub("\\", "\\\\"):gsub("\"", "\\\"") .. "\""
end

--- Safely evaluates a JavaScript string in the active webview, queueing it
--- if the page has not finished loading yet.
--- @param code string The JS code to execute.
local function eval(code)
		if not _wv then return end
		if _ready and type(_wv.evaluateJavaScript) == "function" then
				pcall(function() _wv:evaluateJavaScript(code) end)
		else
				table.insert(_queued, code)
				if #_queued > 200 then table.remove(_queued, 1) end
		end
end





-- =================================================
-- =================================================
-- ======= 3/ Window Geometry & Lifecycle ==========
-- =================================================
-- =================================================

--- Computes the bottom-right anchored frame for the webview.
--- @param mode string Either "download" or "bootstrap"; bootstrap mode is shorter.
--- @return table frame {x, y, w, h}
local function compute_frame(mode)
		local screen = hs.screen.mainScreen()
		local f = screen and type(screen.frame) == "function" and screen:frame() or {x=0, y=0, w=1920, h=1080}

		-- Both modes use the same footprint: bootstrap now shows the live terminal
		-- log so the user can see uv output without needing to expand. The size
		-- itself comes from _shared/ui/apps.manifest.json (SSoT) — it used to be a
		-- 460x380 literal here, a second copy of the manifest value free to drift
		-- from it and from the other drivers. Only the corner placement below is
		-- this window's own.
		local geo = ui_builder.get_app_geometry("download_window")
		if not geo then
			Logger.error(LOG, "No geometry for 'download_window' in apps.manifest.json — cannot place the window.")
			return nil
		end
		local W = geo.width
		local H = geo.height
		return {
				x = f.x + f.w - W - 10,
				y = f.y + f.h - H - 10,
				w = W,
				h = H,
		}
end

--- Internally creates the webview if missing. Idempotent.
--- @return boolean opened
local function ensure_webview(title)
		if _wv then return true end
		_ready  = false
		_queued = {}

		-- compute_frame() returns nil when the manifest has no geometry for this
		-- app; opening a webview with a nil frame is not a recoverable state.
		local frame = compute_frame(_mode)
		if not frame then
				Logger.error(LOG, "Download window not opened — geometry unavailable.")
				return false
		end

		local show_ok, candidate = xpcall(function()
			return ui_builder.show_webview({
				frame             = frame,
				title             = title or i18n.get("download_window.title"),
				style_masks       = {"titled", "closable", "miniaturizable", "resizable", "nonactivating"},
				level             = hs.drawing.windowLevels.floating,
				allow_text_entry  = false,
				allow_new_windows = false,
				usercontent       = _ucc,
				assets_dir        = ASSETS_DIR,
				on_navigation     = function(action)
						if action == "didFinishNavigation" then
								_ready = true
								local q = _queued
								_queued = {}
								for _, code in ipairs(q) do
										pcall(function() _wv:evaluateJavaScript(code) end)
								end
						end
						return true
				end,
				on_close          = function()
						-- Skip if we are programmatically closing the window via M.hide()
						if _is_hiding then return end
						_wv = nil
						M._total_files = nil
						M._last_file_count = nil

						-- Auto-abort download and reset menubar if the window is closed natively.
						invoke_controller("Download abort callback", _on_abort)
						invoke_controller("Download cancel callback", _on_cancel)
				end
			})
		end, debug.traceback)
		if show_ok ~= true or candidate == nil or candidate == false then
			Logger.error(LOG, "Download window webview creation failed: %s.",
				tostring(candidate))
			return false
		end
		_wv = candidate

		-- Safety: even if didFinishNavigation never fires, flush queued JS after 1s
		DeferredWork.after(1.0, function()
				if _wv and not _ready then
						_ready = true
						local q = _queued
						_queued = {}
						for _, code in ipairs(q) do
								pcall(function() _wv:evaluateJavaScript(code) end)
						end
				end
		end, "download_window.ready_fallback")
		return true
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Returns true when the progress window is currently open.
--- @return boolean True if the webview is alive.
function M.is_active()
	return _wv ~= nil
end

--- Identifies the current occupant of this shared, single-instance window.
--- Bumped by every M.show(), so a caller that armed a deferred hide can check
--- whether the window it meant to close is still the one on screen. Without this
--- a deferred hide belonging to a finished operation closes whatever unrelated
--- operation happens to own the window when the timer fires.
--- @return number Monotonic session identifier.
function M.session_id()
	return _session
end

--- Brings the window to the front and focuses it.
function M.focus()
	if not _wv then return end
	if type(_wv.bringToFront) == "function" then
		pcall(function() _wv:bringToFront(true) end)
	end
	if type(_wv.hswindow) == "function" then
		local win = _wv:hswindow()
		if win and type(win.focus) == "function" then
			pcall(function() win:focus() end)
		end
	end
end

--- Hides and destroys the progress window.
--- @return boolean committed
function M.hide()
		_is_hiding = true
		local owned = _wv
		if owned then
				if type(owned.delete) ~= "function" then
						_is_hiding = false
						Logger.error(LOG, "Download window close refused; owned WebView has no delete method.")
						return false
				end
				local ok, err = xpcall(function() owned:delete() end, debug.traceback)
				_is_hiding = false
				if not ok then
						Logger.error(LOG, "Download window close did not commit; exact WebView retained: %s.",
							tostring(err))
						return false
				end
		end
		if _wv == owned then _wv = nil end
		_on_abort = nil
		_on_cancel = nil
		_on_resolve = nil
		_on_retry_start = nil
		_on_retry  = nil
		_start_ts  = nil
		_ready     = false
		_queued    = {}
		_log_shown = false
		_is_hiding = false
		_kind      = nil
		_mode      = "download"
		M._current_model = nil
		M._terminal_cmd = nil
		M._total_files = nil
		M._last_file_count = nil
		return true
end


--- ==============================================
--- ====== 4.1) Download mode (model pulls) ======
--- ==============================================

--- Shows the progress window for a download or bootstrap operation.
--- @param opts table Configuration: {kind, title?, subtitle?, on_abort?, on_cancel?, on_resolve?, on_retry_start?, on_retry?, terminal_cmd?, model?}
---   • kind: required bootstrap kind (e.g. "mlx_install", "mlx_model", "ollama_model")
---   • title, subtitle: window titles (preset defaults if omitted)
---   • on_abort, on_cancel, on_resolve, on_retry_start, on_retry: event callbacks
---   • terminal_cmd: command for terminal output (download mode only)
---   • model: model name or table with .name/.repo (download mode only)
--- @return boolean opened True only when the shared progress window is active.
function M.show(opts)
		if type(opts) ~= "table" or type(opts.kind) ~= "string" or not PRESETS[opts.kind] then
				Logger.error(LOG, "M.show() requires opts.kind as valid preset.")
				return false
		end

		local preset = PRESETS[opts.kind]
		local title    = (type(opts.title)    == "string" and opts.title    ~= "") and opts.title    or preset.default_title
		local subtitle = (type(opts.subtitle) == "string" and opts.subtitle ~= "") and opts.subtitle or preset.default_subtitle

		Logger.start(LOG, "Showing progress UI (kind=%s, mode=%s).", opts.kind, preset.mode)

		-- New occupant: invalidate any deferred hide armed by the previous one.
		_session = _session + 1
		_kind = opts.kind
		_mode = preset.mode
		_on_abort   = type(opts.on_abort)   == "function" and opts.on_abort   or nil
		_on_cancel  = type(opts.on_cancel)  == "function" and opts.on_cancel  or nil
		_on_resolve = type(opts.on_resolve) == "function" and opts.on_resolve or nil
		_on_retry_start = type(opts.on_retry_start) == "function" and opts.on_retry_start or nil
		_on_retry   = type(opts.on_retry)   == "function" and opts.on_retry   or nil

		-- Download mode: extract model and terminal command
		if opts.kind == "mlx_model" or opts.kind == "ollama_model" then
				local model = opts.model
				local model_name = type(model) == "table" and (model.name or model.repo) or model
				M._current_model = type(model_name) == "string" and model_name or "inconnu"
				M._terminal_cmd  = type(opts.terminal_cmd) == "string" and opts.terminal_cmd or ("ollama pull " .. M._current_model)
		end

		-- ONE decision, taken before anything can invalidate it. This used to be two
		-- separate `if _wv then` tests with ensure_webview() in between, so a window
		-- created two lines earlier looked "already open": the reuse branch then
		-- cleared _queued (discarding the setKind that carries the title, subtitle and
		-- kind) and forced _ready = true, which made every following eval() fire
		-- against a page whose document had not finished loading. Nothing arrived, and
		-- the block written to be the fresh-window path was unreachable.
		local reusing = (_wv ~= nil)

		_start_ts          = hs.timer.secondsSinceEpoch()
		_log_shown         = false
		M._total_files     = nil
		M._last_file_count = nil

		if not reusing then
				if ensure_webview(title) ~= true then
					M.hide()
					return false
				end
		elseif not _ready then
				-- Reusing a window whose page never finished loading: the previous
				-- occupant's undelivered payload must not flush on top of this one's.
				_queued = {}
		end

		if reusing then
				-- Same window, new occupant: clear the previous download's percentage, log
				-- lines and "done" banner, or they linger as zombie placeholders.
				--
				-- Deliberately NOT done on a fresh page. resetUI() hides AND disables
				-- #btn-cancel when download_window.btn_cancel is missing from
				-- window._i18n_strings — and ui_builder injects that table only AFTER the
				-- navigation callback that flushes this queue. The i18n pass rewrites
				-- textContent and never restores `display`, so Cancel would be gone for the
				-- entire life of every freshly opened window.
				eval("resetUI()")
		end

		-- Exactly one setKind, carrying the RESOLVED pair. The old code followed the
		-- real call with setKind(kind, null, null); script.js falls back to the kind's
		-- default title and blanks the subtitle when they are null, so the second call
		-- undid the first — and the subtitle is the deps checkers' current step label.
		eval(string.format("setKind(%s,%s,%s)", js_str(_kind), js_str(title), js_str(subtitle)))

		-- _current_model is nil for bootstrap kinds (mlx_install, ollama_install)
		if M._current_model then
				eval("setModel(" .. js_str(M._current_model) .. ")")
		end

		Logger.success(LOG, "Progress UI shown (title=%q, reusing=%s).", title, tostring(reusing))
		return true
end

--- Updates the UI with current download metrics. Download mode only.
--- @param pct_str string|number Percentage complete.
--- @param bytes_done number Bytes downloaded so far.
--- @param bytes_total number Total bytes expected.
--- @param raw_line string The raw log line from the download process to display.
--- @param python_file_count number|nil Authoritative completed-file count from the Python watcher.
function M.update(pct_str, bytes_done, bytes_total, raw_line, python_file_count)
		if not _wv then return end

		local pct = tonumber(pct_str) or 0
		local elapsed = hs.timer.secondsSinceEpoch() - (_start_ts or hs.timer.secondsSinceEpoch())

		local dl_str, speed_str, eta_str, file_count_str

		if type(bytes_total) == "number" and bytes_total > 0 then
				local ds = fmt_bytes(bytes_done)
				local ts = fmt_bytes(bytes_total)
				if ds and ts then dl_str = ds .. " / " .. ts end
		elseif type(bytes_done) == "number" and bytes_done > 0 then
				dl_str = fmt_bytes(bytes_done)
		end

		if type(bytes_done) == "number" and bytes_done > 0 and elapsed > 2 then
				local speed = bytes_done / elapsed
				speed_str = fmt_bytes(speed) and (fmt_bytes(speed) .. "/s") or nil

				if type(bytes_total) == "number" and bytes_total > bytes_done and speed > 0 then
						eta_str = fmt_time((bytes_total - bytes_done) / speed)
				end
		end

		-- Parse file counts for MLX and rich stats for Ollama directly from the logs
		if type(raw_line) == "string" and raw_line ~= "" then
				local clean_line = raw_line:gsub("\27%[[%d;]*%a", "")

        -- 1. Extract Ollama native progress (Ollama doesn't pass bytes_done via parameters)
        if not bytes_done then
            local o_pct = clean_line:match("(%d+)%%")
            if o_pct and tonumber(o_pct) then pct = tonumber(o_pct) end

            local o_dl = clean_line:match("(%d+%.?%d*%s*[KMG]?B%s*/%s*%d+%.?%d*%s*[KMG]?B)")
            if o_dl then dl_str = o_dl end

            local o_speed = clean_line:match("(%d+%.?%d*%s*[KMG]?B/s)")
            if o_speed then speed_str = o_speed end

            local o_eta = clean_line:match("%s+(%d+[hms%d]+)%s*$")
            if o_eta then eta_str = o_eta end
        end

        -- 2. MLX / HuggingFace file progress - Extremely strict matching
        for total in clean_line:gmatch("Fetching (%d+) files") do
            M._total_files = tonumber(total)
        end

        local found_files = false
        local padded_line = " " .. clean_line .. " "

        -- Primary match: tqdm format with pipe and bracket, e.g., "| 4/10 ["
        for a, b in padded_line:gmatch("|%s*(%d+)%s*/%s*(%d+)%s*%[") do
            if not M._total_files or tonumber(b) == M._total_files then
                local num_a = tonumber(a) or 0
                local num_b = tonumber(b) or 1
                if num_a <= num_b then
                    local last_a = M._last_file_count and tonumber(M._last_file_count:match("(%d+)%s*/")) or -1
                    -- Prevent visual regressions if terminal artifacts jump backwards
                    if num_a >= last_a then
                        file_count_str = a .. "/" .. b
                        M._last_file_count = file_count_str
                        if not M._total_files then M._total_files = num_b end
                        found_files = true
                    end
                end
            end
        end

        -- Secondary fallback: Look for X/Y anywhere, BUT strictly bounded to prevent file size collision
        if not found_files and M._total_files then
            -- [^%.%w] strictly forbids dots and letters immediately around the numbers
            for a, b in padded_line:gmatch("[^%.%w](%d+)%s*/%s*(%d+)[^%.%w]") do
                if tonumber(b) == M._total_files then
                    local num_a = tonumber(a) or 0
                    local last_a = M._last_file_count and tonumber(M._last_file_count:match("(%d+)%s*/")) or -1
                    if num_a >= last_a and num_a <= M._total_files then
                        file_count_str = a .. "/" .. b
                        M._last_file_count = file_count_str
                        found_files = true
                    end
                end
            end
        end

        if not file_count_str and M._last_file_count then
            file_count_str = M._last_file_count
        end
    elseif M._last_file_count then
        file_count_str = M._last_file_count
    end

    -- The Python size-watcher emits __FILECOUNT__:N as (completed_weights + 1), i.e. the
    -- 1-based index of the file currently being downloaded. Anti-regression: never go backwards.
    if type(python_file_count) == "number" and python_file_count > 0 then
        local display_count = python_file_count
        local total_files   = M._total_files
        if total_files and display_count > total_files then display_count = total_files end
        local last_a = M._last_file_count and tonumber(M._last_file_count:match("^(%d+)")) or -1
        if display_count > last_a then
            local total_str = total_files and tostring(total_files) or "?"
            file_count_str = tostring(display_count) .. "/" .. total_str
            M._last_file_count = file_count_str
        end
    end

    -- Cap at 99% during download: 100% is reserved exclusively for done()
    pct = math.min(math.max(0, pct), 99)

    local js = string.format("update(%d,%s,%s,%s,%s)",
        math.floor(pct), js_str(dl_str), js_str(speed_str), js_str(eta_str), js_str(file_count_str))

    eval(js)
    if not _log_shown then
        _log_shown = true
        eval("showLog()")
    end
    if type(raw_line) == "string" and raw_line ~= "" then
        local normalized = raw_line:gsub("\r\n", "\n"):gsub("\r", "\n")
        for line in normalized:gmatch("([^\n]+)") do
            if line ~= "" then
                local safe = line:gsub("\\", "\\\\"):gsub("\"", "\\\"")
                eval("addLog(\"" .. safe .. "\")")
            end
        end
    end
end

--- Finalizes the download UI state (download mode).
--- @param success boolean True if download was successful.
--- @param _model_name string The name of the downloaded model.
--- @param error_kind string|nil Error kind metadata for contextual actions.
function M.complete(success, _model_name, error_kind)
    if not _wv then return end

    local is_ok = success == true
    local msg   = is_ok and i18n.get("download_window.done_success") or i18n.get("download_window.done_failed")
    local js    = string.format("done(%s,%s,%s); showLog()", is_ok and "true" or "false", js_str(msg), js_str(error_kind))

    eval(js)

    if is_ok then
        -- Capture the session BEFORE arming, and hide only if it is unchanged.
        -- This window is shared: a four-second timer belonging to a finished
        -- operation otherwise closes whatever unrelated operation happens to own
        -- the window when it fires. The session identity exists for exactly this
        -- and was applied to one deferred-hide site; these two never got it.
        local sid = M.session_id()
        DeferredWork.after(4, function()
            if M.session_id() ~= sid then
                Logger.debug(LOG, "Auto-hide skipped: the window now belongs to a newer operation.")
                return
            end
            pcall(M.hide)
        end, "download_window.success_dismiss")
    end
end


--- ======================================================
--- ====== 4.2) Bootstrap mode (engine install API) ======
--- ======================================================

--- Updates the current step label (the second, brighter line). Use this
--- on every macro-step boundary (e.g. "Installation de uv…").
--- @param label string French step description.
function M.set_step(label)
    if not _wv then return end
    if type(label) ~= "string" then return end
    Logger.debug(LOG, "Step: %s", label)
    eval(string.format("setStep(%s)", js_str(label)))
end

--- Updates the verbose detail line (third, dimmed monospaced line). Use
--- this on every stdout/stderr line received from the subprocess.
--- @param text string Raw verbose output.
function M.set_detail(text)
    if not _wv then return end
    if type(text) ~= "string" then return end
    eval(string.format("setDetail(%s)", js_str(text)))
end

--- Appends a single line to the scrollable terminal log area. Use during
--- bootstrap to mirror every stdout/stderr line from the subprocess so
--- the user sees the real install progress (uv resolution, wheel
--- downloads, etc.), not just the highest-level step.
--- @param text string One line of subprocess output.
function M.append_log(text)
    if not _wv then return end
    if type(text) ~= "string" or text == "" then return end
    eval(string.format("addLog(%s)", js_str(text)))
end

--- Updates the bootstrap progress bar fill. Pass nil for indeterminate.
--- @param pct number|nil Percentage in [0, 100], or nil for indeterminate.
function M.set_progress(pct)
    if not _wv then return end
    if pct ~= nil and type(pct) ~= "number" then return end
    eval(string.format("setProgress(%s)", pct == nil and "null" or tostring(pct)))
end

--- Switches the UI to "error" presentation: red accent, error step color,
--- and an automatic dismiss after ERROR_AUTO_DISMISS_SEC.
--- @param msg string Short French error message (one line).
function M.set_error(msg)
    if not _wv then
        -- Surface the error in logs so it never goes silent
        Logger.error(LOG, "set_error called with no active UI: %s", tostring(msg))
        return
    end
    local text = type(msg) == "string" and msg or i18n.get("download_window.error_unknown")
    Logger.warn(LOG, "Progress UI flipped to error state: %s", text)
    eval(string.format("setError(%s)", js_str(text)))
    -- Same session capture as M.complete: "_wv is non-nil" only proves SOME
    -- window is open, not that it is still this operation's.
    local sid = M.session_id()
    DeferredWork.after(ERROR_AUTO_DISMISS_SEC, function()
        if not _wv then return end
        if M.session_id() ~= sid then
            Logger.debug(LOG, "Error auto-dismiss skipped: the window now belongs to a newer operation.")
            return
        end
        pcall(M.hide)
    end, "download_window.error_dismiss")
end

return M
