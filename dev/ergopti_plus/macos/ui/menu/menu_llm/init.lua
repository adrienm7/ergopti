--- ui/menu/menu_llm/init.lua

--- ==============================================================================
--- MODULE: Menu LLM
--- DESCRIPTION:
--- Builds and manages the LLM system tray menu and logic bindings.
---
--- FEATURES & RATIONALE:
--- 1. Backend Agnostic: Switches gracefully between MLX and Ollama.
--- 2. Dynamic UI: Reads models from JSON configuration to build menus.
--- ==============================================================================

local M = {}

local hs            = hs
local llm_mod       = require("modules.llm")
local shortcut_ui   = require("ui.menu.shortcut_utils")
local Logger        = require("lib.logger")
local notifications = require("lib.notifications")
local i18n          = require("lib.i18n")
local Models        = require("ui.menu.menu_llm.models_manager")
local Profiles      = require("ui.menu.menu_llm.profiles_manager")
local Settings      = require("ui.menu.menu_llm.settings_manager")
local TempPanel        = require("ui.menu.menu_llm.temperature_panel")
local StreamPanel      = require("ui.menu.menu_llm.streaming_panel")
local WarmupCtrl       = require("ui.menu.menu_llm.warmup_controller")
local BackendPanel     = require("ui.menu.menu_llm.backend_panel")
local TriggerPanel     = require("ui.menu.menu_llm.trigger_panel")
local ApiPanel         = require("ui.menu.menu_llm.api_panel")
local ModelsSelector   = require("ui.menu.menu_llm.models_selector")
local ModelSwitcher    = require("ui.menu.menu_llm.model_switcher")
-- Single source of truth for the MLX server address — the health probe reads the
-- configured port from here rather than hardcoding it.
local ApiMlx           = require("modules.llm.api_mlx")
local StartupCtrl      = require("ui.menu.menu_llm.startup_controller")
local TriggerOrch      = require("ui.menu.menu_llm.trigger_orchestrator")
-- Shared cross-platform layout spec (_shared/modules/llm/menu_layout.json): the
-- single source of truth for which rows grey out while the feature is OFF, consumed
-- identically by the Windows renderer so the two menus can never drift again.
local MenuLayout       = require("ui.menu.menu_llm.menu_layout")

-- Deps checkers — kicked off on backend switch and on first menu activation
-- so a fresh-out-of-the-box Mac auto-bootstraps the engine without any
-- manual user action. Both checkers are idempotent and exit silently when
-- nothing needs doing, so the menu opens instantly in the nominal case.
local mlx_deps_checker    = require("modules.llm.mlx_deps_checker")
local ollama_deps_checker = require("modules.llm.ollama_deps_checker")

--- Triggers the deps checker matching the given backend name. Designed to
--- be safe to call repeatedly: each underlying script is hash-gated /
--- liveness-gated and exits in milliseconds when the backend is already
--- ready, so this is effectively a no-op on a working system.
--- @param backend string Either "mlx" or "ollama".
local function check_backend_deps(backend)
	if backend == "mlx" then
		pcall(mlx_deps_checker.check_and_install_deps)
	elseif backend == "ollama" then
		pcall(ollama_deps_checker.check_and_install_deps)
	end
end

local LOG = "menu_llm"

--- Wraps pcall and logs Logger.error when the wrapped call fails, so we
--- never swallow exceptions silently (violates project rule 5.3). Pass
--- the call-site label as ``name`` so the log carries enough context to
--- find the failing call. Returns the same ``ok, …`` tuple as pcall.
--- @param name string Short label identifying the call site.
--- @param fn function The function to call.
--- @vararg any Arguments forwarded to ``fn``.
local function pcall_log(name, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		Logger.error(LOG, "pcall '%s' failed: %s", tostring(name), tostring(err))
	end
	return ok, err
end

-- Holds the active models manager so M.stop_mlx_server() can reach it from any context
-- (e.g., the Hammerspoon shutdown callback) without requiring a reference chain.
local _active_models_mgr = nil

-- Single source of truth for Apple-Silicon detection (F-MED-4): delegates to
-- BackendPanel.is_apple_silicon(), which uses `uname -m` — NOT a filesystem
-- existence check on /opt/homebrew. The old heuristic ("Homebrew on ARM
-- installs to /opt/homebrew") is wrong on a fresh arm64 Mac that has not
-- installed Homebrew yet, causing a first-run to seed llm_backend as
-- "ollama" on Apple Silicon instead of "mlx".
local is_apple_silicon = BackendPanel.is_apple_silicon()

M.DEFAULT_STATE = {
    llm_enabled           = llm_mod.DEFAULT_STATE.llm_enabled,
    llm_backend           = is_apple_silicon and "mlx" or "ollama",
    llm_debounce          = llm_mod.DEFAULT_STATE.llm_debounce,
    llm_model             = is_apple_silicon and llm_mod.DEFAULT_STATE.llm_model_mlx or llm_mod.DEFAULT_STATE.llm_model_ollama,
    llm_model_ollama      = llm_mod.DEFAULT_STATE.llm_model_ollama,
    llm_model_mlx         = llm_mod.DEFAULT_STATE.llm_model_mlx,
    llm_context_length    = llm_mod.DEFAULT_STATE.llm_context_length,
    llm_reset_on_nav      = llm_mod.DEFAULT_STATE.llm_reset_on_nav,
    llm_temperature       = llm_mod.DEFAULT_STATE.llm_temperature,
    llm_num_predictions   = llm_mod.DEFAULT_STATE.llm_num_predictions,
    llm_arrow_nav_enabled = llm_mod.DEFAULT_STATE.llm_arrow_nav_enabled,
    llm_nav_modifiers     = llm_mod.DEFAULT_STATE.llm_nav_modifiers,
    llm_show_info_bar     = llm_mod.DEFAULT_STATE.llm_show_info_bar,
    llm_val_modifiers     = llm_mod.DEFAULT_STATE.llm_val_modifiers,
    llm_pred_indent       = llm_mod.DEFAULT_STATE.llm_pred_indent,
    llm_active_profile    = llm_mod.DEFAULT_STATE.llm_active_profile,
    llm_user_models       = {},
    llm_disabled_apps          = {},
    llm_url_bar_filter_enabled        = true,
    llm_secure_field_filter_enabled   = true,
    llm_user_profiles     = {},
    llm_profile_shortcuts = {},
    -- On-demand prediction shortcut. Defaults to Ctrl+Space (real Ctrl,
    -- not Cmd — on macOS the Cmd+Space slot is owned by Spotlight and
    -- system-wide search, so it's a poor default for an editor cue).
    -- The user can rebind it from the trigger settings submenu or set
    -- the value to false to disable.
    llm_trigger_shortcut  = { mods = { "ctrl" }, key = "space" },
    llm_after_hotstring   = llm_mod.DEFAULT_STATE.llm_after_hotstring,
    llm_auto_raise_temp   = llm_mod.DEFAULT_STATE.llm_auto_raise_temp,
    llm_min_words         = llm_mod.DEFAULT_STATE.llm_min_words,
    llm_streaming           = llm_mod.DEFAULT_STATE.llm_streaming,
    llm_streaming_multi     = llm_mod.DEFAULT_STATE.llm_streaming_multi,
    llm_instant_on_word_end = llm_mod.DEFAULT_STATE.llm_instant_on_word_end,
}



-- Cached result of the last async server health check.
-- nil = not yet checked, true = server responded, false = server unreachable.
local _llm_health_status = nil

--- Resets the cached health-status flag to nil (not-yet-checked).
--- probe_llm_health() intentionally skips the "api" backend entirely (no
--- local server to probe there), so without this the status dot could show
--- a stale MLX/Ollama reading (e.g. a residual orange "warming up") that
--- leaked into the API backend's display until the user switched away and
--- back again (F-LOW-6). Call this whenever the active backend changes to
--- "api" so the indicator starts from a clean, honest "not applicable" state.
function M.reset_llm_health_status()
	_llm_health_status = nil
end

--- Fires an async health probe against the active backend.
--- Updates _llm_health_status and calls refresh_fn() when the result arrives.
--- @param backend string "mlx" or "ollama".
--- @param refresh_fn function Called with no args after the result is stored.
local function probe_llm_health(backend, refresh_fn)
	-- In API backend mode there is no local server to probe. Skip the health
	-- check entirely to avoid lighting the orange "warming" indicator based on
	-- a residual MLX server that happens to be listening on the same port.
	if backend == "api" then return end
	local url
	if backend == "ollama" then
		url = "http://127.0.0.1:11434/api/version"
	else
		-- The MLX health probe follows the configured port via api_mlx.get_base_url()
		-- (the single source of truth) — no hardcoded port literal.
		url = ApiMlx.get_base_url() .. "/v1/models"
	end

	hs.http.asyncGet(url, {}, function(status)
		-- Any HTTP response (even 4xx) means the server is reachable
		_llm_health_status = (type(status) == "number" and status > 0)
		if type(refresh_fn) == "function" then pcall(refresh_fn) end
	end)
end


--- Stops the MLX server process if one is currently running.
--- Safe to call even when no server is active or before M.create() has been called.
--- Intended for the Hammerspoon shutdown callback to prevent orphaned Python processes.
function M.stop_mlx_server()
	if _active_models_mgr and type(_active_models_mgr.stop_mlx_server_if_needed) == "function" then
		pcall(_active_models_mgr.stop_mlx_server_if_needed)
	end
end

--- Kills the orphan helper processes spawned for the local LLM backends (the
--- expander + http server). Shared by the genuine-quit shutdown callback AND the
--- script_quit action: script_quit exits via os.exit(0), which bypasses
--- hs.shutdownCallback, so it must perform the identical teardown. Centralising it
--- here means the two quit paths can never drift (the bug was that script_quit
--- killed Karabiner + flushed the keylogger but left the MLX server + helpers alive).
function M.terminate_helper_processes()
	pcall(hs.execute, "pkill -f 'ergopti_plus_expander'", true)
	pcall(hs.execute, "pkill -f 'ergopti_plus_http_server'", true)
	-- The `ollama serve` wrapper this driver launches is a third helper and was
	-- not on this list. It is spawned through a /bin/sh pipeline, so terminating
	-- the hs.task only reaps the shell — the server itself survived every quit
	-- path and kept appending to the Ergopti log after Hammerspoon was gone.
	-- Matched on the same shape api_ollama uses to kill a stale one at launch, so
	-- the two agree on what "our ollama serve" means.
	pcall(hs.execute, "pkill -f '[o]llama serve'", true)
end

--- Kills any orphan mlx_lm.server and frees its listening port. stop_mlx_server()
--- only terminates the in-process hs.task WRAPPER; the Python server runs in its
--- OWN process group (set +m) and survives that, so it must be reaped explicitly
--- via pgrep/lsof. Shared by BOTH the hs.shutdownCallback genuine-quit branch and
--- the script_quit (os.exit) action so the two quit paths can never drift — without
--- this, script_quit left the GPU-resident server holding the port (F-M7). The port
--- is read from the single source api_mlx.get_port().
function M.terminate_orphan_mlx_server()
	pcall(function()
		local ok_m, am = pcall(require, "modules.llm.api_mlx")
		local raw_port = (ok_m and type(am.get_port) == "function" and am.get_port())
		             or  (ok_m and am.DEFAULT_PORT)
		             or  3460
		local p = tostring(raw_port)
		hs.execute(
			"pgrep -f 'mlx_lm.*server' | xargs kill -9 2>/dev/null; " ..
			"lsof -tiTCP:" .. p .. " -sTCP:LISTEN | xargs kill -9 2>/dev/null", true)
	end)
end





-- =================================
-- =================================
-- ======= 1/ Helper Methods =======
-- =================================
-- =================================

local function format_mod_string(m_str)
    if type(m_str) ~= "string" then return "⌃" end
    local dict = { ctrl="⌃", cmd="⌘", alt="⌥", shift="⇧" }
    local res = ""
    for p in m_str:gmatch("[^+]+") do res = res .. (dict[p] or p) end
    return res == "" and "⌃" or res
end



-- ==========================================
-- ===== 1.1) Shortcut Title Formatting =====
-- ==========================================

--- Returns true when the mods table contains the sentinel "none" value
--- (regardless of position), indicating the shortcut is disabled.
local function mods_has_none(mods)
    if not mods then return false end
    for _, m in ipairs(mods) do if m == "none" then return true end end
    return false
end

local function format_shortcut_title(action, mods, none_label, mod_label)
    -- Fail closed on a wrong-typed value: a corrupt or AHK-migrated hs.settings
    -- entry can hold a STRING where a table is expected, and table.concat(string)
    -- raises. Because the whole AI submenu builder runs inside a pcall, that throw
    -- silently blanked the entire LLM submenu from the menubar. Treat any non-table
    -- as "disabled" before the concat can ever run.
    if type(mods) ~= "table" then
        return action .. " : " .. i18n.get("common.disabled")
    end
    if not mods or mods_has_none(mods) then
        return action .. " : " .. i18n.get("common.disabled")
    elseif #mods == 0 then
        return action .. " : " .. none_label
    else
        local sym = format_mod_string(table.concat(mods, "+"))
        return action .. " : " .. sym .. " " .. mod_label
    end
end





-- ===============================
-- ===============================
-- ======= 2/ Main Factory =======
-- ===============================
-- ===============================

function M.create(deps)
    if type(deps) ~= "table" then return {} end
    
    deps.active_tasks = deps.active_tasks or {}
    local state       = deps.state
    
    -- Migration logic for older configs
    if state.llm_use_mlx ~= nil then
        state.llm_backend = state.llm_use_mlx and "mlx" or "ollama"
        state.llm_use_mlx = nil
    end
    if state.llm_backend == nil then 
        state.llm_backend = M.DEFAULT_STATE.llm_backend 
    end
    llm_mod.set_backend(state.llm_backend)

    local models_mgr   = Models.new(deps)
    -- Register the manager so M.stop_mlx_server() can reach it from the shutdown callback
    _active_models_mgr = models_mgr

    -- profiles_mgr is re-created after apply_llm_profile_shortcut is bound into deps
    local profiles_mgr = nil
    local settings_mgr = Settings.new(deps)
    local keymap       = deps.keymap
    local save_prefs   = deps.save_prefs
    local update_menu  = deps.update_menu

    local switcher = ModelSwitcher.new({
        state       = state,
        models_mgr  = models_mgr,
        keymap      = keymap,
        save_prefs  = save_prefs,
        update_menu = update_menu,
    })
    local switch_model                     = switcher.switch_model
    local get_display_model_name           = switcher.get_display_model_name
    local get_model_power_level            = switcher.get_model_power_level
    local apply_recommended_prompt_profile = switcher.apply_recommended_prompt_profile
    local guarded_check_requirements       = switcher.guarded_check_requirements

    deps.set_llm_profile = switcher.set_llm_profile
    deps.apply_recommended_prompt_profile = function(opts)
        apply_recommended_prompt_profile(state.llm_model, opts)
    end

    -- Resolve display model name to actual backend names on startup —
    -- older configs may have persisted a backend-native name; normalise to
    -- the display name so the rest of the code sees a consistent value.
    if type(state.llm_model) == "string" and state.llm_model ~= "" then
        local presets_startup = models_mgr.get_presets()
        local display_name    = state.llm_model
        if type(presets_startup) == "table" then
            for _, provider in ipairs(presets_startup) do
                for _, family in ipairs(provider.families or {}) do
                    for _, m in ipairs(family.models or {}) do
                        local m_display = m.name or m.repo
                        if type(m_display) == "string" then
                            local actual = models_mgr.get_actual_model_name(m_display)
                            if actual == state.llm_model and m_display ~= state.llm_model then
                                display_name = m_display
                            end
                        end
                    end
                end
            end
        end
        if display_name ~= state.llm_model then
            Logger.debug(LOG, string.format("Correcting model name on startup (backend->display): '%s' -> '%s'.", state.llm_model, display_name))
            state.llm_model = display_name
        end

        local actual_name = models_mgr.get_actual_model_name(display_name)
        Logger.debug(LOG, string.format("Resolving model name on startup: '%s' -> '%s'.", display_name, actual_name))
        if state.llm_backend == "mlx" then
            state.llm_model_mlx = display_name
            llm_mod.set_llm_model_mlx(actual_name)
        else
            state.llm_model_ollama = display_name
            llm_mod.set_llm_model_ollama(actual_name)
        end
        if type(deps.keymap) == "table" and type(deps.keymap.set_llm_display_model_name) == "function" then
            pcall(deps.keymap.set_llm_display_model_name, display_name)
        end
        state.llm_model_power = get_model_power_level(display_name)
        Logger.debug(LOG, string.format("Model power on startup: %d.", state.llm_model_power))
    end

    if state.llm_num_predictions ~= nil and keymap and type(keymap.set_llm_num_predictions) == "function" then
        pcall(keymap.set_llm_num_predictions, state.llm_num_predictions)
    end
    if state.llm_max_words ~= nil and keymap and type(keymap.set_llm_max_words) == "function" then
        pcall(keymap.set_llm_max_words, state.llm_max_words)
    end
    if state.llm_min_words ~= nil and keymap and type(keymap.set_llm_min_words) == "function" then
        pcall(keymap.set_llm_min_words, state.llm_min_words)
    end
    if state.llm_streaming ~= nil and keymap and type(keymap.set_llm_streaming) == "function" then
        pcall(keymap.set_llm_streaming, state.llm_streaming)
    end
    if state.llm_streaming_multi ~= nil and keymap and type(keymap.set_llm_streaming_multi) == "function" then
        pcall(keymap.set_llm_streaming_multi, state.llm_streaming_multi)
    end



    -- ======================================
    -- ===== 2.2) Dynamic Menu Builders =====
    -- ======================================

    local function build_num_pred_menu()
        Logger.debug(LOG, "Building prediction count menu…")
        local m = {}
        for i = 1, 10 do
            table.insert(m, {
                title   = string.format(i18n.get("menu.llm.prediction_count_label"), i, i > 1 and "s" or ""),
                checked = (state.llm_num_predictions == i),
                fn      = function()
                    Logger.info(LOG, string.format("Changing number of predictions -> %d", i))
                    state.llm_num_predictions = i
                    if keymap and type(keymap.set_llm_num_predictions) == "function" then 
                        local ok = pcall(keymap.set_llm_num_predictions, i)
                        Logger.debug(LOG, string.format("keymap.set_llm_num_predictions(%d) execution -> %s", i, tostring(ok)))
                    else
                        Logger.warn(LOG, "keymap.set_llm_num_predictions is unavailable.")
                    end
                    save_prefs(); update_menu()
                end
            })
        end
        return m
    end



    -- =====================================
    -- ===== 2.3) Hotkeys & Triggers =======
    -- =====================================

    local _llm_trigger_hk  = nil
    local _llm_profile_hks = {}
    local _startup_silence = false
    local function get_startup_silence() return _startup_silence end
    local function set_startup_silence(v) _startup_silence = v end
    local function get_trigger_hk() return _llm_trigger_hk end
    local function set_trigger_hk(v) _llm_trigger_hk = v end
    local function get_profile_hks() return _llm_profile_hks end
    local function set_profile_hk(id, v) _llm_profile_hks[id] = v end

    local trigger_orch = TriggerOrch.new({
        state              = state,
        keymap             = keymap,
        save_prefs         = save_prefs,
        update_menu        = update_menu,
        get_startup_silence = get_startup_silence,
        set_startup_silence = set_startup_silence,
        get_trigger_hk     = get_trigger_hk,
        set_trigger_hk     = set_trigger_hk,
        get_profile_hks    = get_profile_hks,
        set_profile_hk     = set_profile_hk,
    })
    local bind_hotkey                  = trigger_orch.bind_hotkey
    local activate_hotkey              = trigger_orch.activate_hotkey
    local apply_llm_shortcut           = trigger_orch.apply_llm_shortcut
    local apply_llm_profile_shortcut   = trigger_orch.apply_llm_profile_shortcut

    deps.apply_llm_profile_shortcut = apply_llm_profile_shortcut

    profiles_mgr = Profiles.new(deps, models_mgr)



    -- =========================================
    -- ===== 2.4) Lifecycle & Main Build =======
    -- =========================================

    local check_startup
    local function build_item()
        Logger.debug(LOG, "Building LLM menu item (build_item)…")
        local paused = deps.script_control and type(deps.script_control.is_paused) == "function" and deps.script_control.is_paused() or false
        local is_disabled = (not state.llm_enabled) or paused
        Logger.debug(LOG, string.format("Menu state: paused=%s, llm_enabled=%s, is_disabled=%s", tostring(paused), tostring(state.llm_enabled), tostring(is_disabled)))
        local main_menu = {}


        local backend_title, backend_menu = BackendPanel.build({
            state                = state,
            keymap               = keymap,
            paused               = paused,
            models_mgr           = models_mgr,
            get_display_model_name = get_display_model_name,
            switch_model         = switch_model,
            save_prefs           = save_prefs,
            update_menu          = update_menu,
            WarmupCtrl           = WarmupCtrl,
            -- So the API-backend switch can clear a stale MLX/Ollama health
            -- reading instead of leaking it into the API backend's status
            -- dot display (F-LOW-6).
            reset_llm_health_status = M.reset_llm_health_status,
        })

        table.insert(main_menu, {
            title    = backend_title,
            disabled = MenuLayout.row_disabled("backend", is_disabled, paused),
            menu     = backend_menu
        })

        -- API entries CRUD — delegates entirely to ApiPanel.
        do
            local api_title, api_menu = ApiPanel.build({
                state       = state,
                paused      = paused,
                update_menu = update_menu,
                WarmupCtrl  = WarmupCtrl,
            })
            if api_title and api_menu then
                table.insert(main_menu, {
                    title    = api_title,
                    disabled = paused or nil,
                    menu     = api_menu,
                })
            end
        end
        local active_display_model = get_display_model_name(state.llm_model)
        local info = models_mgr.get_model_info(active_display_model) or {}
        local ram = models_mgr.get_model_ram(active_display_model) or 0
        local type_str = (info.type == "completion") and " [📝 Complétion]" or " [💬 Chat]"
        local params_ram_str = (info.params and info.params > 0)
            and string.format(" (%gB params, ~%d Go RAM)", info.params, math.ceil(ram))
            or string.format(" (~%d Go RAM)", math.ceil(ram))
        
        -- Trigger a fresh async probe on every menu open so the indicator stays accurate.
        -- The result arrives after the menu is shown; the next open will display it.
        -- Pass a guarded callback that only calls update_menu when _llm_health_status
        -- actually changes: passing update_menu directly causes a build → probe →
        -- update_menu → build loop at ~10-20 rebuilds/second with live HTTP requests.
        if state.llm_enabled and not paused then
            local probe_snapshot = _llm_health_status
            probe_llm_health(state.llm_backend or "mlx", function()
                if _llm_health_status ~= probe_snapshot then
                    pcall(update_menu)
                end
            end)
        end

        -- Health indicator — must be HONEST about whether predictions actually fire:
        -- 🟢 = backend confirmed ready (warmup POST returned 200 + tokens) → the
        --      prediction readiness gate is open, so suggestions will appear.
        -- 🟡 = server reachable (HTTP probe ok) but the model is still warming up;
        --      the prediction engine skips requests until warmup confirms, so a
        --      green dot here would be a lie ("vert mais aucune prédiction").
        -- 🔴 = server unreachable, OR the model was given up on (incompatible /
        --      never loaded). The second case overrides orange so a broken model is
        --      never shown as an eternal "still loading" spinner.
        -- is_backend_ready() is synchronous and reflects the warmup state accurately
        -- even on the first menu open after a model swap.
        local health_dot
        if not state.llm_enabled or paused then
            health_dot = ""
        else
            local backend_ready = false
            if type(llm_mod.is_backend_ready) == "function" then
                local ok, ready = pcall(llm_mod.is_backend_ready)
                backend_ready = ok and ready == true
            end
            -- A model given up on (incompatible / never loaded) must show RED even
            -- though the HTTP server may still answer /v1/models — otherwise the dot
            -- would stay stuck orange forever with no error the user can see.
            local load_failed = false
            if type(llm_mod.is_backend_load_failed) == "function" then
                local ok, failed = pcall(llm_mod.is_backend_load_failed)
                load_failed = ok and failed == true
            end
            if backend_ready then
                health_dot = "🟢 "
            elseif load_failed then
                health_dot = "🔴 "
            elseif _llm_health_status == true then
                health_dot = "🟡 "
            else
                health_dot = "🔴 "
            end
        end

        local rich_model_title = health_dot .. i18n.get("menu.llm.active_model_label")
        if not state.llm_model or state.llm_model == "" then
            rich_model_title = rich_model_title .. i18n.get("menu.llm.no_model_none")
        else
            rich_model_title = rich_model_title .. string.format("%s%s%s", active_display_model, type_str, params_ram_str)
        end

        local model_submenu
        if state.llm_backend == "api" then
            model_submenu = ApiPanel.build_model_picker({
                state       = state,
                paused      = paused,
                update_menu = update_menu,
                WarmupCtrl  = WarmupCtrl,
            })
        else
            model_submenu = ModelsSelector.build({
                state         = state,
                models_mgr    = models_mgr,
                switch_model  = switch_model,
                save_prefs    = save_prefs,
                update_menu   = update_menu,
                DEFAULT_STATE = M.DEFAULT_STATE,
                paused        = paused,   -- gate model rows while paused (M-16)
            })

            -- MLX server port — Ergopti's own server, so let the user move it off
            -- the default if it collides with another local server they run. Changing
            -- it persists (api_mlx → hs.settings), then relaunches the server on the
            -- new port for the current model so the change takes effect immediately.
            local ok_api, ApiMlx = pcall(require, "modules.llm.api_mlx")
            if ok_api and type(ApiMlx.get_port) == "function" then
                local function restart_mlx_for_current_port()
                    if state.llm_backend ~= "mlx" then return end
                    pcall(models_mgr.stop_mlx_server_if_needed)
                    if state.llm_enabled and state.llm_model and state.llm_model ~= "" then
                        -- Silent: a port change is not a model change, so don't pop the
                        -- recommended-profile dialog — just bring the server back up.
                        pcall(models_mgr.check_requirements, state.llm_model, nil, nil,
                            { silent_notifications = true })
                    end
                end
                table.insert(model_submenu, { title = "-" })
                table.insert(model_submenu, {
                    title    = string.format(i18n.get("menu.llm.mlx_port_label"), tostring(ApiMlx.get_port())),
                    disabled = paused or nil,
                    fn       = not paused and function()
                        settings_mgr.set_mlx_port(restart_mlx_for_current_port)
                    end or nil,
                })
                if type(ApiMlx.get_default_port) == "function" and ApiMlx.get_port() ~= ApiMlx.get_default_port() then
                    table.insert(model_submenu, {
                        title    = string.format(i18n.get("menu.llm.reset_label"), tostring(ApiMlx.get_default_port())),
                        disabled = paused or nil,
                        fn       = not paused and function()
                            settings_mgr.reset_mlx_port(restart_mlx_for_current_port)
                        end or nil,
                    })
                end
            end
        end

        table.insert(main_menu, {
            title    = rich_model_title,
            disabled = MenuLayout.row_disabled("model", is_disabled, paused),
            menu     = model_submenu,
        })

        if info and info.emojis and info.emojis:find("🧠💭") then
            table.insert(main_menu, { title = i18n.get("menu.llm.thinking_model_info"), disabled = true })
        end

        table.insert(main_menu, { title = "-" })

        local profiles_item = profiles_mgr.get_menu_item()
        profiles_item.disabled = MenuLayout.row_disabled("profile", is_disabled, paused)
        table.insert(main_menu, profiles_item)

        table.insert(main_menu, { title = string.format(i18n.get("menu.llm.num_predictions_label"), tostring(state.llm_num_predictions or llm_mod.DEFAULT_STATE.llm_num_predictions)), disabled = MenuLayout.row_disabled("num_predictions", is_disabled, paused), menu = build_num_pred_menu() })
        if state.llm_num_predictions ~= llm_mod.DEFAULT_STATE.llm_num_predictions then
            table.insert(main_menu, {
                title    = string.format(i18n.get("menu.llm.reset_label"), tostring(llm_mod.DEFAULT_STATE.llm_num_predictions)),
                disabled = MenuLayout.row_disabled("num_predictions", is_disabled, paused),
                fn       = function()
                    state.llm_num_predictions = llm_mod.DEFAULT_STATE.llm_num_predictions
                    if keymap and type(keymap.set_llm_num_predictions) == "function" then pcall(keymap.set_llm_num_predictions, state.llm_num_predictions) end
                    save_prefs(); update_menu()
                end
            })
        end

        table.insert(main_menu, { title = "-" })


        -- ===== Trigger submenu =====

        local trigger_menu = TriggerPanel.build({
            state              = state,
            keymap             = keymap,
            is_disabled        = is_disabled,
            save_prefs         = save_prefs,
            update_menu        = update_menu,
            settings_mgr       = settings_mgr,
            apply_llm_shortcut = apply_llm_shortcut,
        })

        table.insert(main_menu, { title = i18n.get("menu.llm.trigger_menu_title"), disabled = MenuLayout.row_disabled("trigger", is_disabled, paused), menu = trigger_menu })


        -- ===== Generation settings submenu =====

        local generation_menu = {}

        table.insert(generation_menu, { title = string.format(i18n.get("menu.llm.context_length_label"), tostring(state.llm_context_length)), disabled = is_disabled or nil, fn = settings_mgr.set_context_length })
        if state.llm_context_length ~= llm_mod.DEFAULT_STATE.llm_context_length then
            table.insert(generation_menu, { title = string.format(i18n.get("menu.llm.reset_label"), tostring(llm_mod.DEFAULT_STATE.llm_context_length)), disabled = is_disabled or nil, fn = settings_mgr.reset_context_length })
        end

        table.insert(generation_menu, {
            title    = i18n.get("menu.llm.reset_on_nav"),
            checked  = state.llm_reset_on_nav,
            disabled = is_disabled or nil,
            fn       = function()
                state.llm_reset_on_nav = not state.llm_reset_on_nav
                if keymap and type(keymap.set_llm_reset_on_nav) == "function" then pcall(keymap.set_llm_reset_on_nav, state.llm_reset_on_nav) end
                save_prefs(); update_menu()
            end
        })

        local mw_min = tonumber(state.llm_min_words)
        local min_words_display = (mw_min and mw_min > 0) and tostring(mw_min) or "1"
        table.insert(generation_menu, { title = string.format(i18n.get("menu.llm.min_words_label"), min_words_display), disabled = is_disabled or nil, fn = settings_mgr.set_min_words })
        if state.llm_min_words ~= llm_mod.DEFAULT_STATE.llm_min_words then
            table.insert(generation_menu, { title = string.format(i18n.get("menu.llm.reset_label"), tostring(llm_mod.DEFAULT_STATE.llm_min_words)), disabled = is_disabled or nil, fn = settings_mgr.reset_min_words })
        end

        local mw_max = tonumber(state.llm_max_words)
        local max_words_display = (mw_max and mw_max > 0) and tostring(mw_max) or i18n.get("menu.llm.unlimited")
        table.insert(generation_menu, { title = string.format(i18n.get("menu.llm.max_words_label"), max_words_display), disabled = is_disabled or nil, fn = settings_mgr.set_max_words })
        if state.llm_max_words ~= llm_mod.DEFAULT_STATE.llm_max_words then
            local def_w_disp = (llm_mod.DEFAULT_STATE.llm_max_words and llm_mod.DEFAULT_STATE.llm_max_words > 0) and tostring(llm_mod.DEFAULT_STATE.llm_max_words) or i18n.get("menu.llm.unlimited")
            table.insert(generation_menu, { title = string.format(i18n.get("menu.llm.reset_label"), def_w_disp), disabled = is_disabled or nil, fn = settings_mgr.reset_max_words })
        end

        TempPanel.build({
            state        = state,
            keymap       = keymap,
            is_disabled  = is_disabled,
            save_prefs   = save_prefs,
            update_menu  = update_menu,
            settings_mgr = settings_mgr,
        }, generation_menu)

        table.insert(main_menu, { title = i18n.get("menu.llm.generation_menu_title"), disabled = MenuLayout.row_disabled("generation", is_disabled, paused), menu = generation_menu })


        -- ===== Display submenu =====

        local display_menu = StreamPanel.build({
            state        = state,
            keymap       = keymap,
            is_disabled  = is_disabled,
            save_prefs   = save_prefs,
            update_menu  = update_menu,
            settings_mgr = settings_mgr,
        })

        table.insert(main_menu, { title = i18n.get("menu.llm.display_menu_title"), disabled = MenuLayout.row_disabled("display", is_disabled, paused), menu = display_menu })


        -- ===== Navigation submenu =====

        local nav_menu_items = {}

        local nav_mods = hs.settings.get("llm_nav_modifiers")
        -- Fail closed to the canonical default on any non-table (corrupt/AHK plist),
        -- so both the engine setter and format_shortcut_title get a valid table.
        if type(nav_mods) ~= "table" then nav_mods = llm_mod.DEFAULT_STATE.llm_nav_modifiers end
        if keymap and type(keymap.set_llm_nav_modifiers) == "function" then pcall(keymap.set_llm_nav_modifiers, nav_mods) end

        local val_mods = hs.settings.get("llm_val_modifiers")
        if type(val_mods) ~= "table" then val_mods = llm_mod.DEFAULT_STATE.llm_val_modifiers end
        if keymap and type(keymap.set_llm_val_modifiers) == "function" then pcall(keymap.set_llm_val_modifiers, val_mods) end

        local num_preds_safe = tonumber(state.llm_num_predictions) or llm_mod.DEFAULT_STATE.llm_num_predictions
        local nav_title = format_shortcut_title(i18n.get("menu.llm.nav_label"), nav_mods, i18n.get("menu.llm.arrows_only"), i18n.get("menu.llm.arrows"))
        table.insert(nav_menu_items, {
            title    = nav_title,
            disabled = (is_disabled or num_preds_safe < 2) or nil,
            menu     = settings_mgr.build_nav_modifier_menu()
        })

        local val_title = format_shortcut_title(string.format(i18n.get("menu.llm.val_label"), (num_preds_safe == 10) and "1-0" or ("1-" .. num_preds_safe)), val_mods, i18n.get("menu.llm.digits_only"), i18n.get("menu.llm.digits"))
        table.insert(nav_menu_items, {
            title    = val_title,
            disabled = (is_disabled or num_preds_safe < 2) or nil,
            menu     = settings_mgr.build_val_modifier_menu()
        })

        table.insert(main_menu, { title = i18n.get("menu.llm.nav_menu_title"), disabled = MenuLayout.row_disabled("navigation", is_disabled, paused), menu = nav_menu_items })

        return {
            title   = i18n.get("menu.llm.title"),
            checked = state.llm_enabled or nil,
            fn      = not paused and function()
                local function toggle_state()
                    Logger.info(LOG, string.format("Toggling LLM: %s -> %s", tostring(state.llm_enabled), tostring(not state.llm_enabled)))
                    state.llm_enabled = not state.llm_enabled
                    if keymap and type(keymap.set_llm_enabled) == "function" then
                        local ok = pcall(keymap.set_llm_enabled, state.llm_enabled)
                        Logger.debug(LOG, string.format("keymap.set_llm_enabled(%s) execution -> %s", tostring(state.llm_enabled), tostring(ok)))
                    else
                        Logger.warn(LOG, "keymap.set_llm_enabled is unavailable.")
                    end
                    -- The first activation is when the user expects to see the
                    -- backend’s deps install — fire the deps bootstrap here.
                    -- It's idempotent and silent when the venv is already in
                    -- sync, so toggling LLM on/off in succession costs nothing.
                    if state.llm_enabled then
                        check_backend_deps(state.llm_backend)
                    end
                    save_prefs(); update_menu()
                    pcall(function() notifications.notify(state.llm_enabled and i18n.get("notify.llm_enabled") or i18n.get("notify.llm_disabled"), i18n.get("notify.llm_suggestions")) end)
                end

                if not state.llm_enabled then
                    local function activate_llm()
                        toggle_state()
                        if state.llm_model and state.llm_model ~= "" then
                            -- Start the server in the background — the checkmark is
                            -- already showing, so no need to gate on server readiness.
                            models_mgr.check_requirements(state.llm_model, nil, nil)
                        end
                    end

                    if state.llm_backend == "mlx" then
                        -- Run the bootstrap (idempotent: fires callback immediately if
                        -- already ready). Activation happens in the on_complete callback
                        -- so the checkmark only appears once deps are confirmed good.
                        Logger.info(LOG, "Activating LLM — running MLX bootstrap check first.")
                        mlx_deps_checker.check_and_install_deps(function(ok)
                            if ok then
                                activate_llm()
                            else
                                Logger.error(LOG, "MLX bootstrap failed — cannot activate LLM.")
                            end
                        end)
                    else
                        activate_llm()
                    end
                else
                    toggle_state()
                end
            end or nil,
            menu    = main_menu
        }
    end

    check_startup = StartupCtrl.new({
        state                      = state,
        keymap                     = keymap,
        models_mgr                 = models_mgr,
        guarded_check_requirements = guarded_check_requirements,
        save_prefs                 = save_prefs,
        update_menu                = update_menu,
        apply_llm_shortcut         = apply_llm_shortcut,
        apply_llm_profile_shortcut = apply_llm_profile_shortcut,
        activate_hotkey            = activate_hotkey,
        mlx_deps_checker           = mlx_deps_checker,
        deps                       = deps,
        get_startup_silence        = get_startup_silence,
        set_startup_silence        = set_startup_silence,
        get_trigger_hk             = get_trigger_hk,
        get_profile_hks            = get_profile_hks,
    })

    --- Returns a menu item for the active download progress shortcut, or nil if no download is running.
    --- @return table|nil The menu item, or nil.
    local function build_download_item()
        local is_active = deps.active_tasks and (
            deps.active_tasks["download"] or
            deps.active_tasks["download_tail"] or
            deps.active_tasks["install"]
        )
        if not is_active then return nil end
        local _dw = package.loaded["ui.download_window"]
        return {
            title = i18n.get("menu.llm.show_download_window"),
            fn = function()
                if _dw and type(_dw.focus) == "function" then
                    pcall(_dw.focus)
                elseif _dw and type(_dw.is_active) == "function" and not _dw.is_active() then
                    -- Window was closed without cancelling — download still runs in background
                    pcall(notifications.notify, i18n.get("menu.llm.download_window_lost"), i18n.get("menu.llm.download_window_lost_body"), "info")
                end
            end
        }
    end

    return {
        build_item          = build_item,
        build_download_item = build_download_item,
        check_startup       = check_startup
    }
end

return M
