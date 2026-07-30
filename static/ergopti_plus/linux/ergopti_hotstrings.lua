--- static/ergopti_plus/linux/ergopti_hotstrings.lua

--- ==============================================================================
--- MODULE: Ergopti Hotstrings Daemon (Linux)
--- DESCRIPTION:
--- Entry point for the Linux hotstring daemon. Reads keyboard events from an
--- evdev device via the keyboard_hook adapter (libinput/evtest subprocess),
--- matches the rolling typing buffer against loaded hotstring definitions,
--- and replays expansions via ydotool (uinput). Runs a pump-based event loop
--- that also services the tray_menu signal-file callbacks.
---
--- USAGE:
---   luajit ergopti_hotstrings.lua [OPTIONS]
---
---   --config  <path>   Path to a TOML config file or directory containing
---                       TOML hotstring files. Defaults to
---                       ~/.config/ergopti/hotstrings/ if that directory exists.
---   --device  <path>   Evdev device to listen on (e.g. /dev/input/event3).
---                       When omitted, device_finder auto-selects the keyboard.
---   --layout  <name>   Keyboard layout for keycode mapping: "qwerty" or
---                       "azerty". Default: auto-detect from $XKBLAYOUT env var.
---   --tray             Enable the tray icon (requires yad).
---   --dry-run          Log matches without injecting any keystrokes.
---   --verbose          Enable debug-level logging.
---   --help             Print usage and exit.
---
--- FEATURES & RATIONALE:
--- 1. Pump-based event loop: keyboard_hook.pump() reads from the evdev subprocess
---    pipe in batches of 50 lines; tray_menu.pump() reads the signal file for
---    menu callbacks. Both are called on each iteration so tray menu interactions
---    are serviced even when the user is typing rapidly.
--- 2. Modular architecture: each concern (loading, matching, injection, input,
---    metrics, tray) lives in its own adapter/module so individual pieces can
---    be unit-tested or swapped without touching this file.
--- 3. Buffer reset on control keys: Backspace, Enter, and Tab clear the engine
---    buffer so stale prefixes from incomplete words never trigger expansions.
--- 4. Metrics collection: every keypress is forwarded to the metrics collector
---    so WPM and n-gram statistics accumulate for the full daemon session.
--- ==============================================================================


-- =========================================
-- =========================================
-- ======= 1/ Module Search Path ===========
-- =========================================
-- =========================================

-- Resolve the directory that contains this script so relative requires work
-- when the daemon is launched from any working directory.
local SCRIPT_DIR = (function()
	local src = debug.getinfo(1, "S").source
	local path = src:match("^@(.+)$") or "."
	return path:match("^(.*)[/\\][^/\\]+$") or "."
end)()

-- Prepend the script directory and the shared Lua library to the search path.
local SHARED_LUA_DIR = SCRIPT_DIR .. "/../_shared/lua"
package.path = SCRIPT_DIR .. "/?.lua;" ..
               SCRIPT_DIR .. "/modules/hotstrings/?.lua;" ..
               SHARED_LUA_DIR .. "/?.lua;" ..
               SHARED_LUA_DIR .. "/?/init.lua;" ..
               package.path


-- =========================================
-- =========================================
-- ======= 2/ Logger & UTF-8 Shim ==========
-- =========================================
-- =========================================

-- Install the pure-Lua utf8 compatibility shim BEFORE any shared module require.
-- LuaJIT 2.x does not bundle Lua 5.3's utf8 library.
local utf8_compat = require("compat.utf8")
if utf8_compat.install() then
	-- Installed — shared modules will now get real utf8 support.
end

local Logger = require("logger.shim")

-- The shared logger core only writes to an injected sink, so install ours before
-- the first Logger.* call. Without this every log line on Linux — including the
-- two fatal errors below — went to a ring buffer and nowhere else.
local LoggerSink = require("lib.logger_sink")
LoggerSink.install(Logger)

-- Single source of the driver version (never a re-typed literal).
local Version = require("lib.version")
local LOG = "ergopti_hotstrings"


-- =========================================
-- =========================================
-- ======= 3/ Imports ======================
-- =========================================
-- =========================================

local engine_mod        = require("modules.hotstrings.engine")
local hotstrings_config = require("modules.hotstrings.hotstrings_config")
local injector          = require("modules.hotstrings.injector")
local dev_finder        = require("modules.hotstrings.device_finder")
local keylogger         = require("modules.keylogger.keylogger")
local keyboard_hook     = require("adapters.keyboard_hook")
local Monotonic         = require("lib.monotonic")

-- Optional adapters (may fail to load if deps missing — daemon still runs).
local tray_menu = nil
local ok_tray, tray_mod = pcall(require, "adapters.tray_menu")
if ok_tray then tray_menu = tray_mod end

-- Event loop adapter (luv when available, pump fallback otherwise).
local event_loop = require("adapters.event_loop")

-- Menu builder (builds rich submenus from daemon state).
local menu_builder = nil
local ok_menu, menu_mod = pcall(require, "modules.menu.menu_builder")
if ok_menu then menu_builder = menu_mod end

-- LLM prediction engine (optional — daemon runs without it).
local prediction_engine = nil
local ok_llm, llm_mod = pcall(require, "modules.llm.prediction_engine")
if ok_llm then prediction_engine = llm_mod end

-- Dynamic hotstrings engine (optional — loads personal_info.toml, registers
-- @-tag letter shortcuts and date expansion rules).
local dyn_hotstrings = nil
local ok_dh, dh_mod = pcall(require, "modules.dynamic_hotstrings.manager")
if ok_dh then dyn_hotstrings = dh_mod end

-- Updater engine (optional — checks GitHub releases, downloads and installs updates).
local updater = nil
local ok_up, up_mod = pcall(require, "modules.updater.manager")
if ok_up then updater = up_mod end

-- Gestures manager (optional — trackpad/mouse gesture recognition via libinput).
local gestures = nil
local ok_ge, ge_mod = pcall(require, "modules.gestures.manager")
if ok_ge then gestures = ge_mod end

-- Shortcuts manager (optional — wrap symbols, CapsWord, text manipulation).
local shortcuts = nil
local ok_sc, sc_mod = pcall(require, "modules.shortcuts.manager")
if ok_sc then shortcuts = sc_mod end

-- Window info tracker (optional — provides app_id for keylogger per-app stats).
local window_info = nil
local ok_wi, wi_mod = pcall(require, "adapters.window_info")
if ok_wi then window_info = wi_mod end

-- Process lifecycle tracker (optional — drives focus-change events on Linux).
local process_lifecycle = nil
local ok_pl, pl_mod = pcall(require, "adapters.process_lifecycle")
if ok_pl then process_lifecycle = pl_mod end

-- WebView manager (optional — GTK/WebKit2GTK window creation for UI apps).
-- Auto-inits on load (probes lgi); windows are created on demand via show().
local webview_manager = nil
local ok_wm, wm_mod = pcall(require, "modules.ui.webview_manager")
if ok_wm then webview_manager = wm_mod end

-- Kanata manager (optional — key remapping daemon lifecycle).
-- Handles .kbd generation and kanata process start/stop/restart.
local kanata = nil
local ok_kan, kan_mod = pcall(require, "modules.kanata.manager")
if ok_kan then kanata = kan_mod end

-- File watchers (optional — inotify-based TOML/.lua hot reload).
-- When luv is present, uses native inotify via luv.new_fs_event();
-- otherwise falls back to mtime polling driven by the event loop.
local file_watchers = nil
local ok_fw, fw_mod = pcall(require, "lib.file_watchers")
if ok_fw then file_watchers = fw_mod end


-- =========================================
-- =========================================
-- ======= 4/ Constants ====================
-- =========================================
-- =========================================

-- Default hotstring data location (XDG-compliant user config).
local DEFAULT_CONFIG_DIR = (os.getenv("HOME") or "~") .. "/.config/ergopti/hotstrings"

-- Terminator catalogue: shared between Linux and macOS.
local terminators_mod = (function()
	local ok, mod = pcall(require, "keymap.terminators")
	if ok and mod then return mod end
	Logger.error(LOG, "shared keymap.terminators failed to load (%s).", tostring(mod))
	error("ergopti_plus: shared keymap.terminators is required but failed to load")
end)()


-- =========================================
-- =========================================
-- ======= 5/ CLI Argument Parser ==========
-- =========================================
-- =========================================

local function parse_args()
	local default_layout = (os.getenv("XKBLAYOUT") or ""):lower()
	if default_layout ~= "azerty" then default_layout = "qwerty" end

	local opts = {
		layout  = default_layout,
		dry_run = false,
		verbose = false,
		help    = false,
		tray    = false,
	}
	local i = 1
	while i <= #arg do
		local a = arg[i]
		if     a == "--help"    or a == "-h"  then opts.help    = true
		elseif a == "--dry-run"               then opts.dry_run = true
		elseif a == "--verbose" or a == "-v"  then opts.verbose = true
		elseif a == "--tray"                  then opts.tray    = true
		elseif a == "--config"  and arg[i+1]  then i = i + 1; opts.config = arg[i]
		elseif a == "--device"  and arg[i+1]  then i = i + 1; opts.device = arg[i]
		elseif a == "--layout"  and arg[i+1]  then i = i + 1; opts.layout = arg[i]
		else
			Logger.warn(LOG, "Unknown argument '%s' — ignored.", tostring(a))
		end
		i = i + 1
	end
	return opts
end

local function print_usage()
	print("Utilisation : luajit ergopti_hotstrings.lua [OPTIONS]")
	print("")
	print("  --config <chemin>   Fichier TOML ou répertoire de définitions.")
	print("                      Défaut : ~/.config/ergopti/hotstrings/")
	print("  --device <chemin>   Périphérique evdev (ex. /dev/input/event3).")
	print("                      Défaut : détection automatique.")
	print("  --layout <nom>      Disposition clavier : qwerty | azerty.")
	print("                      Défaut : variable $XKBLAYOUT, sinon qwerty.")
	print("  --tray              Active l'icône de la barre système (nécessite yad).")
	print("  --dry-run           Journalise les correspondances sans injecter.")
	print("  --verbose           Active les messages de débogage.")
	print("  --help              Afficher ce message.")
end


-- =========================================
-- =========================================
-- ======= 6/ Config Resolution ============
-- =========================================
-- =========================================

local function resolve_config_path(config_path)
	if type(config_path) == "string" and config_path ~= "" then
		return config_path
	end
	-- Check the XDG-compliant user config directory.
	local fh = io.open(DEFAULT_CONFIG_DIR, "r")
	if fh then
		fh:close()
		return DEFAULT_CONFIG_DIR
	end
	-- Fall back to bundled shared hotstrings.
	local shared = SCRIPT_DIR .. "/../../_shared/modules/hotstrings"
	local fh2 = io.open(shared, "r")
	if fh2 then
		fh2:close()
		return shared
	end
	return nil
end

--- Attempts the SIGHUP reload flow.  Called from a signal handler so it must
--- be self-contained and not throw.
local function on_sighup_reload()
	Logger.info(LOG, "SIGHUP received — reloading hotstring config…")
	local ok, count = pcall(function() return hotstrings_config.reload() end)
	if ok then
		Logger.success(LOG, "Hotstrings reloaded: %d mapping(s) active.", count or 0)
	else
		Logger.error(LOG, "Hotstrings reload failed: %s.", tostring(count))
	end
end


-- =========================================
-- =========================================
-- ======= 7/ Signal Handler Setup =========
-- =========================================
-- =========================================

local function install_signal_handlers()
	local ok, signal = pcall(require, "posix.signal")
	if not ok or not signal then
		Logger.debug(LOG, "posix.signal unavailable — signal handlers not installed.")
		return
	end

	local function on_term(sig)
		Logger.info(LOG, "Signal %d received — shutting down…", sig)
		local stats = keylogger.get_session_stats()
		Logger.info(LOG, "Session: %d keystroke(s), ~%d word(s), %ds.",
			stats.keystrokes, stats.words, math.floor(stats.duration_ms / 1000))
		keylogger.flush()
		keyboard_hook.stop()
		if tray_menu then tray_menu.destroy() end
	end

	pcall(signal.signal, signal.SIGINT,  on_term)
	pcall(signal.signal, signal.SIGTERM, on_term)

	-- SIGHUP → hot reload.
	pcall(signal.signal, signal.SIGHUP,  function(_) on_sighup_reload() end)

	Logger.debug(LOG, "Signal handlers installed (INT, TERM, HUP).")
end


-- =========================================
-- =========================================
-- ======= 8/ Main Daemon Loop =============
-- =========================================
-- =========================================

local function main()
	local opts = parse_args()

	if opts.help then
		print_usage()
		os.exit(0)
	end

	Logger.start(LOG, "Ergopti hotstrings daemon starting…")

	if opts.dry_run then
		Logger.info(LOG, "Dry-run mode: matches will be logged but not injected.")
	end

	-- 8.1) Initialise the hotstring engine.
	local engine = engine_mod.new()

	-- 8.2) Initialise hotstrings_config and load all mappings.
	local config_path = resolve_config_path(opts.config)
	hotstrings_config.init(engine, config_path)
	local mapping_count = hotstrings_config.load_all()
	Logger.info(LOG, "%d hotstring mapping(s) loaded (%d parse error(s)).",
		mapping_count, hotstrings_config.parse_error_count())

	-- 8.3) Initialise the full keylogger.
	keylogger.init({})

	-- 8.4) Resolve the input device.
	local device = opts.device
	if not device then
		device = dev_finder.find_keyboard()
	end
	if not device then
		Logger.error(LOG, "No keyboard device found. Specify one with --device.")
		print("Erreur : aucun périphérique clavier détecté. Utilisez --device.")
		os.exit(1)
	end
	Logger.info(LOG, "Using device: %s.", device)

	-- Focused app id, cached off the input path by the process_lifecycle
	-- onFocusChange callback (see 8.12). Declared BEFORE on_char so on_char
	-- captures it as an upvalue — otherwise on_char would read a never-assigned
	-- global that stays nil, silently disabling password-app suppression.
	local _cached_app_id = nil

	-- 8.5) Define the character callback.
	local function on_char(ch, scancode)
		-- If an injection is in flight, queue this character so it is replayed
		-- after the synthetic backspace+replacement events complete. This
		-- prevents physical keystrokes from interleaving with injected text
		-- and corrupting the output (the "abcd"→"acd" class of race bug).
		if injector._is_injecting() then
			injector._queue_char({ char = ch, scancode = scancode })
			return
		end

		-- CapsWord: process BEFORE the engine so the capitalized character
		-- enters the buffer correctly (not as a duplicate after the original).
		if shortcuts and shortcuts.is_enabled() and shortcuts.is_caps_word_active() then
			local cap_ch = shortcuts.process_caps_word(ch)
			if cap_ch then ch = cap_ch end
		end

		-- Monotonic wall clock: the keylogger derives real inter-keystroke delays
		-- from this. The CPU clock barely advances between keystrokes on Linux, so
		-- it would make every recorded delay meaningless.
		local now_ms = math.floor(Monotonic.now_ms())

		-- Detect current app for per-app keylogger stats. Read from the
		-- process_lifecycle focus cache (updated off the input path at 250 ms
		-- intervals) so no subprocess is spawned on the keystroke thread. The
		-- cache variable is an upvalue declared before on_char (getFocused()
		-- used to be called here, forking up to 5 subprocesses per keystroke).
		local app_id = _cached_app_id or "Unknown"

		-- Check password suppression.
		if keylogger.is_password_app(app_id) then
			keylogger.suppress()
		else
			keylogger.unsuppress()
		end

		keylogger.on_keydown(ch, now_ms, app_id, scancode)

		local terminator_consumed = terminators_mod.is_terminator(ch)
		local result = engine:on_char(ch, { terminator_consumed = terminator_consumed })

		if result then
			Logger.info(
				LOG,
				"Match: trigger='%s' → '%s' (bc=%d).",
				result.trigger,
				result.replacement,
				result.backspace_count
			)
			if not opts.dry_run then
				-- Keep the keylogger's aggregate contract aligned with macOS and
				-- Windows: generated text and the physical trigger are distinct.
				keylogger.record_hotstring(app_id, result.trigger, result.replacement,
					now_ms, result.group, result.backspace_count)
				injector._begin_injection()
				injector.inject(result.backspace_count, result.replacement)
				-- Drain any physical characters that arrived during
				-- injection and replay them through the engine so they
				-- are re-injected in arrival order.
				for _, queued in ipairs(injector._end_injection()) do
					local queued_ch = type(queued) == "table" and queued.char or queued
					local queued_scancode = type(queued) == "table" and queued.scancode or nil
					local ok, err = pcall(on_char, queued_ch, queued_scancode)
					if not ok then
						Logger.error(LOG, "Error replaying queued char '%s': %s", queued_ch, tostring(err))
					end
				end
			end
			engine:reset()
		end

		-- Feed the character AND the current typing buffer to the LLM prediction
		-- engine. Without the buffer arg, prediction_engine.on_char early-returns
		-- (it needs the buffer to detect its trigger sequences) so the LLM never
		-- predicted anything.
		-- Materialise the buffer ONCE per keystroke and pass the same string to
		-- both consumers — table.concat over up to 256 codepoints is O(buffer)
		-- heap allocation, and the buffer does not change between the two calls.
		if prediction_engine or (dyn_hotstrings and dyn_hotstrings.is_enabled()) then
			local buf = engine:current_buffer()
			if prediction_engine then
				pcall(function() prediction_engine.on_char(ch, buf, { app_id = app_id }) end)
			end
			-- Dynamic hotstrings: check if the trigger character just fired an
			-- @-tag expansion (e.g. "@p★" → first name, "td★" → date).
			-- Must run AFTER the static hotstring matcher so explicit triggers
			-- take precedence over dynamic expansions.
			if dyn_hotstrings and dyn_hotstrings.is_enabled() then
				local ok_dh2, expanded, dynamic_event = pcall(function()
					return dyn_hotstrings.on_trigger(buf, ch)
				end)
				if ok_dh2 and expanded then
					if dynamic_event then
						keylogger.record_hotstring(app_id, dynamic_event.trigger,
							dynamic_event.replacement, now_ms, dynamic_event.h_type,
							dynamic_event.backspace_count)
					end
					-- Dynamic expansion consumed the trigger — reset the engine
					-- buffer so the expansion text doesn't trigger further matches.
					engine:reset()
				end
			end
		end


	end

	-- All physical keydowns, including modifiers and navigation keys, feed the
	-- separate hardware heatmap. Character handling above records only printable
	-- output, so this callback is the single place that prevents special keys
	-- from disappearing and avoids a printable-key double count.
	local function on_physical(scancode, _key_name, _char)
		local app_id = _cached_app_id or "Unknown"
		if keylogger.is_password_app(app_id) then
			keylogger.suppress()
		else
			keylogger.unsuppress()
		end
		keylogger.record_physical_key(app_id, scancode, math.floor(Monotonic.now_ms()))
	end

	-- 8.6) Initialise the LLM prediction engine if available.
	-- Use the shared canonical DEFAULT_CONTEXT_LENGTH from the linux_bridge
	-- (mirrors _shared/modules/llm/defaults.json llm_context_length = 500)
	-- so all three drivers send the same context window.
	if prediction_engine then
		local canonical_ctx = 500  -- defensive fallback
		local ok_lb, lb = pcall(require, "llm.linux_bridge")
		if ok_lb and lb and lb.DEFAULT_CONTEXT_LENGTH then
			canonical_ctx = lb.DEFAULT_CONTEXT_LENGTH
		end
		prediction_engine.init({
			engine        = engine,
			keyboard_hook = keyboard_hook,
			triggers      = { "//", ";;", "--" },
			max_context   = canonical_ctx,
			auto_inject   = true,
			on_output = function(text, context)
				local output_app = type(context) == "table" and context.app_id or _cached_app_id
				keylogger.record_synthetic_output(output_app, text, "llm",
					math.floor(Monotonic.now_ms()), 0,
					type(context) == "table" and context.input_chars or 0)
			end,
		})
		Logger.info(LOG, "LLM prediction engine initialised (max_context=%d).", canonical_ctx)
	end

	-- 8.6a) Initialise dynamic hotstrings (@-tag expansions).
	if dyn_hotstrings then
		dyn_hotstrings.init({
			trigger_char = "\\",  -- default magic key (backslash)
		})
		Logger.info(LOG, "Dynamic hotstrings initialised (%d rule(s)).",
			dyn_hotstrings.get_rules_count())
	end

	-- 8.7) Define the control-key callback.
	local function on_control(key_name)
		engine:reset()
		-- Cancel any in-flight LLM prediction on Backspace or Escape.
		if key_name == "backspace" or key_name == "escape" then
			if prediction_engine then
				pcall(function() prediction_engine.cancel() end)
			end
		end
		Logger.debug(LOG, "Control key '%s' — buffer reset.", key_name)
	end

	-- 8.8) Start the keyboard hook adapter.
	-- NOTE (hotstring race): this starts in OBSERVE mode (no `intercept`), so
	-- libinput does NOT grab the device and physical keys reach the app directly.
	-- During a match's erase-then-type injection, keys the user keeps typing can
	-- therefore interleave with the synthetic backspace+replacement stream and
	-- scramble the output (the "abcd"→"acd" corruption). The injector's queue
	-- (_begin/_queue/_end_injection) only helps once the daemon OWNS the output
	-- stream — i.e. in intercept mode (evtest --grab / EVIOCGRAB).
	-- onEmitRaw is wired unconditionally: it is inert in observe mode (nothing was
	-- consumed, so nothing needs putting back), and it is what makes intercept a
	-- one-word change rather than a rewrite. The grab itself stays off until it
	-- can be measured on real hardware — one `ydotool key` process per physical
	-- event is a fork per keystroke, and the device kanata auto-detects is not
	-- coordinated with the one device_finder picks here.
	keyboard_hook.start({
		device = device,
		layout = opts.layout,
		onChar  = on_char,
		onKey   = on_control,
		onPhysical = on_physical,
		onEmitRaw  = injector.emit_key,
	})

	if not keyboard_hook.isRunning() then
		Logger.error(LOG, "Keyboard hook failed to start — exiting.")
		print("Erreur : impossible de démarrer le hook clavier.")
		os.exit(1)
	end

	-- 8.9) Start the tray menu if requested.
	if opts.tray and tray_menu then
		Logger.info(LOG, "Tray icon requested — starting.")
		tray_menu.setIcon({ title = "Ergopti" })

	if menu_builder then
		local config_dir = resolve_config_path(opts.config) or DEFAULT_CONFIG_DIR

		-- Build the menu context once; shared between the initial menu build
		-- and the updater's on_available callback (which triggers a rebuild
		-- so the menu label changes when an update is found).
		local function _build_menu_ctx()
			return {
				_version      = Version.VERSION,
				config        = hotstrings_config,
				engine        = engine,
				layout        = opts.layout,
				on_layout_change = function(new_layout)
					Logger.info(LOG, "Layout change requested: %s (restart daemon to apply)", new_layout)
				end,
		keylogger     = keylogger,
		llm           = prediction_engine,
		gestures      = gestures,
		shortcuts     = shortcuts,
		kanata        = kanata,
		updater       = updater,
		webview       = webview_manager,
			dry_run       = opts.dry_run,
			verbose       = opts.verbose,
			on_quit       = function() keyboard_hook.stop() end,
			on_open_config = function(dir)
				local d = dir or config_dir
				Logger.info(LOG, "Opening config folder: %s", d)
				os.execute(string.format("xdg-open '%s' 2>/dev/null &", d:gsub("'", "'\\''")))
			end,
			on_open_logs = function()
				-- Single resolver, shared with the sink that writes there: this action
				-- used to open a hardcoded HOME path that ignored XDG_DATA_HOME and
				-- that nothing ever wrote to.
				local log_dir = LoggerSink.log_dir()
				Logger.info(LOG, "Opening log folder: %s", log_dir)
				os.execute(string.format("xdg-open '%s' 2>/dev/null &", log_dir:gsub("'", "'\\''")))
			end,
			on_healthcheck = function()
				if webview_manager then
					webview_manager.show("healthcheck")
				else
					Logger.info(LOG, "[stub] Healthcheck — webview manager not available.")
				end
			end,
			on_show_setup_wizard = function()
				if webview_manager then
					webview_manager.show("onboarding")
				else
					Logger.info(LOG, "[stub] Setup wizard — webview manager not available.")
				end
			end,
			on_enable_all = function()
				if hotstrings_config.enable_all then
					hotstrings_config.enable_all()
					Logger.info(LOG, "All hotstring groups enabled.")
				end
			end,
			on_disable_all = function()
				if hotstrings_config.disable_all then
					hotstrings_config.disable_all()
					Logger.info(LOG, "All hotstring groups disabled.")
				end
			end,
			on_set_log_level = function(lvl)
				if Logger.set_level then
					Logger.set_level(lvl)
				end
				Logger.info(LOG, "Log level set to %s.", lvl)
			end,
			}
		end

		local menu_items = menu_builder.build(_build_menu_ctx())
		tray_menu.setMenu(menu_items)
		else
			tray_menu.setMenu({
				{ title = "Ergopti " .. (opts.layout or "qwerty"), fn = function() end },
				{ title = "Quitter", fn = function() keyboard_hook.stop() end },
			})
		end
	elseif opts.tray and not tray_menu then
		Logger.warn(LOG, "Tray icon requested but tray_menu adapter unavailable (install yad).")
	else
		-- Always state the tray decision: without this a launch that forgot --tray
		-- looks identical in the log to one where the adapter failed to load.
		Logger.info(LOG, "Tray icon disabled (no --tray) — running headless.")
	end

	-- 8.10) Install signal handlers.
	install_signal_handlers()

	-- 8.10a) Initialise i18n (loads persisted locale, enables ★ substitution).
	local ok_i18n, i18n_mod = pcall(require, "lib.i18n")
	if ok_i18n and i18n_mod then
		i18n_mod.init()
		i18n_mod.set_trigger_provider(function()
			return "\\"  -- default magic key (backslash)
		end)
	end

	-- 8.10c) Initialise the gestures manager (trackpad/mouse gesture recognition).
	if gestures then
		gestures.init({ enabled = false, persist = true })
		Logger.info(LOG, "Gestures manager initialised.")
	end

	-- 8.10d) Initialise the shortcuts manager (wrap symbols, CapsWord, text transforms).
	if shortcuts then
		shortcuts.init({ enabled = false })
		Logger.info(LOG, "Shortcuts manager initialised.")
	end

	-- 8.10e) Wire daemon state into the webview manager so bridge handlers
	-- can query/control daemon modules (keylogger, LLM, config, engine).
	if webview_manager then
		webview_manager.set_daemon_state({
			engine    = engine,
			keylogger = keylogger,
			config    = hotstrings_config,
			llm       = prediction_engine,
			layout    = opts.layout,
		})
		Logger.info(LOG, "WebView manager daemon state wired.")
	end

	if updater then
		local on_available = function(release)
			Logger.info(LOG, "Update available: %s — rebuilding menu.", release.tag)
			-- Rebuild the tray menu so the update label changes.
			if tray_menu and menu_builder then
				tray_menu.setMenu(menu_builder.build(_build_menu_ctx()))
			end
		end
		updater.init({ on_available = on_available })
	end

	Logger.success(LOG, "Daemon ready (device=%s layout=%s mappings=%d dry_run=%s tray=%s).",
		device, opts.layout, mapping_count, tostring(opts.dry_run), tostring(opts.tray and tray_menu ~= nil))

	-- 8.11) Start file watchers (inotify-based TOML/.lua hot reload).
	-- Watches the hotstrings config directory and the project .lua files.
	-- When luv is available, uses native inotify; otherwise falls back
	-- to mtime polling driven by the event loop's onPeriodic callback.
	if file_watchers then
		file_watchers.start({
			hotstrings_dir = config_path,
			base_dir       = SCRIPT_DIR,
			personal_dir   = config_path,  -- personal TOMLs live alongside bundled ones
			on_reload      = function()
				Logger.info(LOG, "Config change detected — reloading hotstrings…")
				local ok, count = pcall(function() return hotstrings_config.reload() end)
				if ok then
					Logger.success(LOG, "Hotstrings reloaded: %d mapping(s) active.", count or 0)
				else
					Logger.error(LOG, "Hotstrings reload failed: %s.", tostring(count))
				end
			end,
		})
		Logger.info(LOG, "File watchers armed (%s).",
			file_watchers.has_inotify() and "inotify" or "mtime poll")
	end

	-- 8.12) Start process lifecycle polling if the adapter loaded.
	-- tick() drives focus-change and app-launch/quit detection at 250 ms
	-- intervals; the event loop calls it periodically.
	-- The focused app_id upvalue is declared above (before on_char so both
	-- share it); the onFocusChange callback below keeps it current off the
	-- input path so on_char never spawns subprocesses on every keystroke.
	local tick_count = 0
	if process_lifecycle then
		process_lifecycle.onFocusChange(function(appName, windowTitle)
			_cached_app_id = (type(appName) == "string" and appName ~= "" and appName) or nil
			-- The private-browsing verdict is computed HERE, off the input path.
			-- The title was previously received and discarded, which is why the
			-- driver had no private-browsing filter at all.
			keylogger.set_private_window(keylogger.is_private_window(windowTitle))
			if _cached_app_id then
				keylogger.on_app_focus(_cached_app_id, math.floor(Monotonic.now_ms()))
			end
		end)
		-- start() seeds its change detector with the current window and therefore
		-- does not emit an initial callback. Prime the keylogger explicitly so a
		-- dashboard opened before the first application switch has an owner for
		-- its foreground interval.
		local foreground = process_lifecycle.getForegroundApp()
		_cached_app_id = foreground and foreground.appId or nil
		keylogger.set_private_window(
			keylogger.is_private_window(foreground and foreground.windowTitle))
		if type(_cached_app_id) == "string" and _cached_app_id ~= "" then
			keylogger.on_app_focus(_cached_app_id, math.floor(Monotonic.now_ms()))
		end
		process_lifecycle.start()
	end

	-- 8.13) Event loop — luv native when available, pump fallback otherwise.
	-- The idle callback pumps the keyboard hook + tray menu;
	-- the periodic callback drives process_lifecycle.tick(),
	-- file_watchers.pump() (deadline check + mtime polling) and one batch of the
	-- at-rest migration.
	local on_periodic = function()
		tick_count = tick_count + 1
		if process_lifecycle then
			pcall(process_lifecycle.tick, tick_count)
		end
		if file_watchers then
			file_watchers.pump()
		end
		-- One bounded batch per tick, and only while a migration is in flight.
		-- Deliberately NOT on the idle callback: that one runs between keystrokes,
		-- and a batch costs one openssl spawn per value.
		pcall(keylogger.pump_migration)
	end

	event_loop.run({
		onIdle = function()
			if not keyboard_hook.isRunning() then
				event_loop.stop()
				return
			end
			if tray_menu then
				pcall(tray_menu.pump)
			end
			pcall(keyboard_hook.pump)
		end,
		onPeriodic = on_periodic,
		periodSec = 0.25,
	})

	-- 8.14) Clean exit.
	if file_watchers then file_watchers.stop() end
	if process_lifecycle then process_lifecycle.stop() end
	if tray_menu then tray_menu.destroy() end

	local stats = keylogger.get_session_stats()
	Logger.info(LOG, "Session ended: %d keystroke(s), ~%d word(s), %ds.",
		stats.keystrokes, stats.words, math.floor(stats.duration_ms / 1000))
	keylogger.flush()
	Logger.info(LOG, "Daemon exiting.")
end

main()
