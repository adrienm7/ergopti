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

local Logger     = require("lib.logger")
local ui_builder = require("ui.ui_builder")

local LOG = "download_window"

local _wv        = nil
local _on_cancel = nil
local _on_resolve = nil
local _on_retry  = nil
local _start_ts  = nil
local _ready     = false
local _queued    = {}
local _log_shown = false
local _is_hiding = false
local _kind      = nil      -- Active kind, if any (mlx_install, ollama_install, mlx_model, ollama_model)
local _mode      = "download" -- "download" (model download) or "bootstrap" (engine install)

local _src  = debug.getinfo(1, "S").source:sub(2)
local ASSETS_DIR = _src:match("^(.*[/\\])") or "./"


-- Per-kind presets (titles / subtitles / accent colors). Kept in Lua so
-- non-webview callers can also introspect them; rendered values are pushed
-- to the webview at show time via setKind().
local PRESETS = {
	mlx_install = {
		mode             = "bootstrap",
		default_title    = "Installation du moteur IA (MLX)",
		default_subtitle = "Préparation des dépendances Python locales…",
		accent           = "#4da6ff",
	},
	ollama_install = {
		mode             = "bootstrap",
		default_title    = "Installation du moteur IA (Ollama)",
		default_subtitle = "Préparation du serveur Ollama local…",
		accent           = "#73d98c",
	},
	mlx_model = {
		mode             = "download",
		default_title    = "Téléchargement du modèle MLX",
		default_subtitle = "Récupération des poids depuis Hugging Face…",
		accent           = "#9973f2",
	},
	ollama_model = {
		mode             = "download",
		default_title    = "Téléchargement du modèle Ollama",
		default_subtitle = "Récupération des poids depuis Ollama Hub…",
		accent           = "#f2bf4d",
	},
}

-- Auto-dismiss delay applied after set_error before the window fades. Keeps
-- the failure message readable without forcing the user to dismiss it.
local ERROR_AUTO_DISMISS_SEC = 8.0





-- ====================================
-- ====================================
-- ======= 1/ Javascript Bridge =======
-- ====================================
-- ====================================

local _ucc = hs.webview.usercontent.new("dl_bridge")
_ucc:setCallback(function(msg)
    if type(msg) ~= "table" then return end

    if msg.body == "cancel" then
        -- Notify central manager hook (if set) so it can mark downloads aborted
        local hook = package.loaded and package.loaded["ui.menu.menu_llm.models_manager.download_abort_hook"]
        if type(hook) == "function" then pcall(hook) end
        if type(_on_cancel) == "function" then pcall(_on_cancel) end

    elseif msg.body == "resolve" then
        if type(_on_resolve) == "function" then pcall(_on_resolve) end

    elseif msg.body == "retry" then
        -- Un-abort the menubar icon lock so we can display progress again
        local retry_hook = package.loaded["ui.menu.menu_llm.models_manager.download_retry_hook"]
        if type(retry_hook) == "function" then pcall(retry_hook) end

        if type(_on_retry) == "function" then pcall(_on_retry) end

    elseif msg.body == "terminal" then
        -- In bootstrap mode, show the live Hammerspoon log; in download mode, use the model-specific cmd
        local cmd = _mode == "bootstrap" and "tail -f /tmp/ergopti.log" or (M._terminal_cmd or ("ollama pull " .. (M._current_model or "")))
        local apple_script = string.format(
            "osascript -e 'tell application \"Terminal\" to do script \"%s\"' -e 'tell application \"Terminal\" to activate'",
            cmd:gsub("\"", "\\\"")
        )
        pcall(hs.execute, apple_script)

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

    -- Both modes use the same 460x380 footprint: bootstrap now shows the live
    -- terminal log so the user can see uv output without needing to expand.
    local W = 460
    local H = 380
    return {
        x = f.x + f.w - W - 10,
        y = f.y + f.h - H - 10,
        w = W,
        h = H,
    }
end

--- Internally creates the webview if missing. Idempotent.
local function ensure_webview(title)
    if _wv then return end
    _ready  = false
    _queued = {}

    _wv = ui_builder.show_webview({
        frame             = compute_frame(_mode),
        title             = title or "Téléchargement",
        style_masks       = {"titled", "closable", "miniaturizable", "resizable", "nonactivating"},
        level             = hs.drawing.windowLevels.floating,
        allow_text_entry  = false,
        allow_gestures    = false,
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

            -- Auto-abort download and reset menubar if the window is closed natively
            local hook = package.loaded and package.loaded["ui.menu.menu_llm.models_manager.download_abort_hook"]
            if type(hook) == "function" then pcall(hook) end
            if type(_on_cancel) == "function" then pcall(_on_cancel) end
        end
    })

    -- Safety: even if didFinishNavigation never fires, flush queued JS after 1s
    hs.timer.doAfter(1.0, function()
        if _wv and not _ready then
            _ready = true
            local q = _queued
            _queued = {}
            for _, code in ipairs(q) do
                pcall(function() _wv:evaluateJavaScript(code) end)
            end
        end
    end)
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
function M.hide()
    _is_hiding = true
    if _wv and type(_wv.delete) == "function" then
        pcall(function() _wv:delete() end)
    end
    _wv = nil
    _on_cancel = nil
    _on_resolve = nil
    _on_retry  = nil
    _start_ts  = nil
    _ready     = false
    _queued    = {}
    _log_shown = false
    _is_hiding = false
    _kind      = nil
    _mode      = "download"
    M._total_files = nil
    M._last_file_count = nil
end


-- =============================================
-- ===== 4.1) Download mode (model pulls) ======
-- =============================================

--- Shows the progress window for a download or bootstrap operation.
--- Two calling conventions:
---   • Bootstrap / kind-driven: M.show({ kind = "mlx_install", title?, subtitle? })
---   • Legacy model download:  M.show(model_name_or_table, on_cancel, terminal_cmd, sizes, actions)
--- The two are dispatched on the shape of the first argument.
--- @param model_or_opts string|table Either the legacy model arg or an opts table with .kind.
--- @param on_cancel function|nil Legacy: callback invoked if the user cancels.
--- @param terminal_cmd string|nil Legacy: override for the terminal fallback command.
--- @param sizes table|nil Legacy: explicit sizes metadata.
--- @param actions table|nil Legacy: {on_resolve, on_retry} callbacks.
function M.show(model_or_opts, on_cancel, terminal_cmd, sizes, actions)
    -- Bootstrap path: opts table carrying a known kind.
    if type(model_or_opts) == "table" and type(model_or_opts.kind) == "string" and PRESETS[model_or_opts.kind] then
        local opts   = model_or_opts
        local preset = PRESETS[opts.kind]
        local title    = (type(opts.title)    == "string" and opts.title    ~= "") and opts.title    or preset.default_title
        local subtitle = (type(opts.subtitle) == "string" and opts.subtitle ~= "") and opts.subtitle or preset.default_subtitle

        Logger.start(LOG, "Showing progress UI (kind=%s, mode=%s).", opts.kind, preset.mode)

        _kind = opts.kind
        _mode = preset.mode

        if _wv then
            -- Reuse existing window: just refresh kind and titles
            eval(string.format("setKind(%s,%s,%s)", js_str(_kind), js_str(title), js_str(subtitle)))
        else
            ensure_webview(title)
            -- Push the kind first so the page initialises in the correct mode
            eval(string.format("setKind(%s,%s,%s)", js_str(_kind), js_str(title), js_str(subtitle)))
        end

        Logger.success(LOG, "Progress UI shown (title=%q).", title)
        return
    end

    -- Legacy model-download path.
    local model = model_or_opts
    local model_name = type(model) == "table" and (model.name or model.repo) or model
    M._current_model = type(model_name) == "string" and model_name or "inconnu"
    M._terminal_cmd  = type(terminal_cmd) == "string" and terminal_cmd or ("ollama pull " .. M._current_model)

    _on_cancel  = type(on_cancel) == "function" and on_cancel or nil
    _on_resolve = type(actions) == "table" and type(actions.on_resolve) == "function" and actions.on_resolve or nil
    _on_retry   = type(actions) == "table" and type(actions.on_retry)   == "function" and actions.on_retry   or nil
    -- Detect backend from terminal_cmd to set correct kind; reset from any prior bootstrap mode
    if type(M._terminal_cmd) == "string" and (M._terminal_cmd:find("mlx", 1, true) or M._terminal_cmd:find("huggingface", 1, true)) then
        _kind = "mlx_model"
    else
        _kind = "ollama_model"
    end
    _mode = "download"

    if _wv then
        -- Window already open — reset state to prevent zombie placeholders
        _start_ts  = hs.timer.secondsSinceEpoch()
        _queued    = {}
        _ready     = true
        _log_shown = false
        M._total_files = nil
        M._last_file_count = nil

        eval("resetUI()")
        eval(string.format("setKind(%s,null,null)", js_str(_kind)))
        local safe = M._current_model:gsub("'", "\\'"):gsub("\"", "\\\"")
        eval("setModel(\"" .. safe .. "\")")
        return
    end

    _start_ts  = hs.timer.secondsSinceEpoch()
    M._total_files = nil
    M._last_file_count = nil

    ensure_webview("Téléchargement du modèle")

    eval(string.format("setKind(%s,null,null)", js_str(_kind)))
    local safe = M._current_model:gsub("'", "\\'"):gsub("\"", "\\\"")
    eval("setModel(\"" .. safe .. "\")")
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
    local msg   = is_ok and "✅ Installation terminée !" or "Échec du téléchargement"
    local js    = string.format("done(%s,%s,%s); showLog()", is_ok and "true" or "false", js_str(msg), js_str(error_kind))

    eval(js)

    if is_ok then
        hs.timer.doAfter(4, M.hide)
    end
end


-- =====================================================
-- ===== 4.2) Bootstrap mode (engine install API) ======
-- =====================================================

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
    local text = type(msg) == "string" and msg or "Erreur inconnue."
    Logger.warn(LOG, "Progress UI flipped to error state: %s", text)
    eval(string.format("setError(%s)", js_str(text)))
    hs.timer.doAfter(ERROR_AUTO_DISMISS_SEC, function()
        -- Only auto-dismiss if we are still in an error state for the same window
        if _wv then pcall(M.hide) end
    end)
end

return M
