--- static/ergopti_plus/linux/ergopti_hotstrings.lua

--- ==============================================================================
--- MODULE: Ergopti Hotstrings Daemon (Linux)
--- DESCRIPTION:
--- Entry point for the Linux hotstring daemon. Reads keyboard events straight
--- from an evdev device through the keyboard_hook adapter, which holds
--- EVIOCGRAB and re-emits every event through its own uinput device; matches the
--- rolling typing buffer against loaded hotstring definitions; and types
--- expansions as keystrokes resolved against the session's real XKB layout. Runs
--- a pump-based event loop that also services the tray_menu callbacks.
---
--- USAGE:
---   luajit ergopti_hotstrings.lua [OPTIONS]
---
---   --config  <path>   Path to a TOML config file or directory containing
---                       TOML hotstring files. Defaults to
---                       ~/.config/ergopti/hotstrings/ if that directory exists.
---   --device  <path>   Evdev device to listen on (e.g. /dev/input/event3).
---                       When omitted, device_finder auto-selects the keyboard.
---   --layout  <name>   INPUT layout for keycode-to-character mapping: "qwerty"
---                       or "azerty". Default: auto-detect from $XKBLAYOUT.
---   --keymap  <path>   OUTPUT layout override: a keymap dump to type against,
---                       for a session whose keymap cannot be probed. Normally
---                       unnecessary — the layout is read from the server.
---   --tray             Enable the tray icon (needs libayatana-appindicator).
---   --dry-run          Log matches without injecting any keystrokes.
---   --verbose          Raise the log level to debug for this run.
---   --help             Print usage and exit.
---
--- FEATURES & RATIONALE:
--- 1. Pump-based event loop: keyboard_hook.pump() drains whatever the grabbed
---    device has ready, without blocking; tray_menu.pump() services menu
---    callbacks. Both run on each iteration, so the tray and every timer advance
---    whether or not anyone is typing — which was not true while capture went
---    through a blocking pipe read.
--- 2. Modular architecture: each concern (loading, matching, injection, input,
---    metrics, tray) lives in its own adapter/module so individual pieces can
---    be unit-tested or swapped without touching this file.
--- 3. Control routing: Backspace and navigation reset stale buffer state, while
---    bare Enter and Tab reach the matcher as catalogue terminators.
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
local RuntimeGuard = require("infra.runtime_guard")

-- The shared logger core only writes to an injected sink, so install ours before
-- the first Logger.* call. Without this every log line on Linux — including the
-- two fatal errors below — went to a ring buffer and nowhere else.
local LoggerSink = require("infra.logger_sink")
LoggerSink.install(Logger)

-- Single source of the driver version (never a re-typed literal).
local Version = require("infra.version")
local LOG = "ergopti_hotstrings"


-- =========================================
-- =========================================
-- ======= 3/ Imports ======================
-- =========================================
-- =========================================

local engine_mod        = require("modules.hotstrings.engine")
local hotstrings_config = require("modules.hotstrings.hotstrings_config")
local injector          = require("modules.hotstrings.injector")
local keyboard_layout   = require("adapters.keyboard_layout")
local MagicKey          = require("modules.hotstrings.magic_key")
local PreviewSettings   = require("modules.hotstrings.preview_settings")
local RepeatKey         = require("modules.hotstrings.repeat_key")

-- The user's own modifier chords. Hard require rather than optional: the module
-- has no external dependency, and a shortcut layer that silently fails to load
-- leaves every binding the user made doing nothing with no sign why.
local keyboard_shortcuts = require("modules.shortcuts.keyboard_shortcuts")

-- Battery, network, lock and suspend, for the metrics.
local system_metrics = RuntimeGuard.optional_require("modules.keylogger.system_metrics")

-- The typing-speed pill (optional — needs a graphics renderer and a display).
local wpm_widget = RuntimeGuard.optional_require("ui.wpm.widget")

-- Desktop notifications (optional — needs notify-send and a session bus). The
-- adapter degrades to a log line on a headless machine, so a missing one is not
-- a reason to refuse to start.
local notifier = RuntimeGuard.optional_require("adapters.notifier")

-- Preview tooltip (optional — needs lgi and a display; the daemon expands
-- hotstrings perfectly well without one, and a driver whose expansions work
-- must not stop working because it cannot draw a hint about them).
local tooltip_preview = RuntimeGuard.optional_require("ui.tooltip.preview")
local llm_overlay = RuntimeGuard.optional_require("ui.tooltip.llm")
local dev_finder        = require("modules.hotstrings.device_finder")
local keylogger         = require("modules.keylogger.keylogger")
local keyboard_hook     = require("adapters.keyboard_hook")
local InputEvent        = require("infra.input_event")
local Monotonic         = require("infra.monotonic")
local ManifestReader    = require("infra.manifest_reader")
local ScriptSettings    = require("infra.script_settings")
local Timings           = require("infra.timings")
local CrashReporter     = require("modules.diagnostics.crash_reporter")
local FocusGuard        = require("modules.keylogger.focus_guard")
local InputCaptureGate  = require("infra.input_capture_gate")

-- Optional adapters (may fail to load if deps missing — daemon still runs).
local tray_menu = RuntimeGuard.optional_require("adapters.tray_menu")

-- Event loop adapter (luv when available, pump fallback otherwise).
local event_loop = require("adapters.event_loop")

-- Menu builder (builds rich submenus from daemon state).
local menu_builder = RuntimeGuard.optional_require("ui.menu.menu_builder")

-- LLM prediction engine (optional — daemon runs without it).
local prediction_engine = RuntimeGuard.optional_require("modules.llm.prediction_engine")

-- Dynamic hotstrings engine (optional — loads personal_info.toml, registers
-- @-tag letter shortcuts and date expansion rules).
local dyn_hotstrings = RuntimeGuard.optional_require("modules.dynamic_hotstrings.manager")

-- Updater engine (optional — checks GitHub releases, downloads and installs updates).
local updater = RuntimeGuard.optional_require("modules.updater.manager")

-- Gestures manager (optional — trackpad/mouse gesture recognition via libinput).
local gestures = RuntimeGuard.optional_require("modules.gestures.manager")

-- Shortcuts manager (optional — wrap symbols, CapsWord, text manipulation).
local shortcuts = RuntimeGuard.optional_require("modules.shortcuts.manager")

-- Window info tracker (optional — provides app_id for keylogger per-app stats).
local window_info = RuntimeGuard.optional_require("adapters.window_info")

-- Process lifecycle tracker (optional — drives focus-change events on Linux).
local process_lifecycle = RuntimeGuard.optional_require("adapters.process_lifecycle")

-- Optional probe, mandatory posture: when AT-SPI cannot load, FocusGuard keeps
-- metrics and text automation closed instead of treating absence as permission.
local secure_field_detector = RuntimeGuard.optional_require("adapters.secure_field_detector")

-- WebView manager (optional — GTK/WebKit2GTK window creation for UI apps).
-- Auto-inits on load (probes lgi); windows are created on demand via show().
local webview_manager = RuntimeGuard.optional_require("ui.webview_manager")
local input_capture_gate = nil

-- Kanata manager (optional — key remapping daemon lifecycle).
-- Handles .kbd generation and kanata process start/stop/restart.
local kanata = RuntimeGuard.optional_require("platform.remap.manager")

-- Tap-hold writer (optional — persists a menu change to the user's tap_hold.toml
-- and reloads kanata). Initialised here because it needs the manager above: this
-- driver could READ its tap-hold configuration and not change it until
-- 2026-08-08, so every row of that submenu was greyed.
if kanata then
	local thw_mod = RuntimeGuard.optional_require("platform.remap.tap_hold_writer")
	if thw_mod and type(thw_mod.init) == "function" then
		thw_mod.init({ manager = kanata })
	end
end

-- File watchers (optional — inotify-based TOML/.lua hot reload).
-- When luv is present, uses native inotify via luv.new_fs_event();
-- otherwise falls back to mtime polling driven by the event loop.
local file_watchers = RuntimeGuard.optional_require("infra.file_watchers")

-- Every owner below may keep a luv handle referenced. They must stop BEFORE
-- event_loop.stop(), otherwise luv.run() waits for the very cleanup that the
-- daemon used to perform only after run() returned.
local TimerScheduler = require("adapters.timer_scheduler")
local ShutdownCoordinator = require("infra.shutdown_coordinator")
local shutdown = ShutdownCoordinator.new({
	pre_wait = {
		{
			name = "updater background checks",
			stop = function()
				if updater and type(updater.stop_background_checks) == "function" then
					updater.stop_background_checks()
				end
			end,
		},
		{
			name = "LLM prediction request",
			stop = function()
				if prediction_engine and type(prediction_engine.cancel) == "function" then
					prediction_engine.cancel()
				end
			end,
		},
		{
			name = "file watchers",
			stop = function()
				if file_watchers and type(file_watchers.stop) == "function" then file_watchers.stop() end
			end,
		},
		{
			name = "process lifecycle",
			stop = function()
				if process_lifecycle and type(process_lifecycle.stop) == "function" then process_lifecycle.stop() end
			end,
		},
		{
			name = "tooltip preview",
			stop = function()
				if tooltip_preview and type(tooltip_preview.destroy) == "function" then tooltip_preview.destroy() end
			end,
		},
		{
			name = "gesture reader",
			stop = function()
				if gestures and type(gestures.stop_reading) == "function" then gestures.stop_reading() end
			end,
		},
		{
			name = "webview manager",
			stop = function()
				if webview_manager and type(webview_manager.shutdown) == "function" then
					webview_manager.shutdown()
				end
			end,
		},
		{
			name = "input capture gate",
			stop = function()
				if input_capture_gate and type(input_capture_gate.release_all) == "function" then
					input_capture_gate.release_all()
				end
			end,
		},
		{
			name = "timer scheduler",
			stop = TimerScheduler.cancelAll,
		},
	},
	keyboard_hook = keyboard_hook,
	event_loop = event_loop,
})


-- =========================================
-- =========================================
-- ======= 4/ Constants ====================
-- =========================================
-- =========================================

-- Default hotstring data location (XDG-compliant user config).
-- How many periodic ticks between metric flushes. The periodic callback runs
-- four times a second (periodSec = 0.25 below), and the cross-driver ingest
-- cadence is _shared/modules/timings/constants.toml [keylogger] ingest_tick_ms —
-- what Windows uses as INGEST_TICK_MS and macOS as INGEST_TICK_SEC. Derived
-- rather than written as a literal so a change to the canon moves all three.
local PERIODIC_TICK_MS   = 250
local FLUSH_EVERY_TICKS  = math.max(1,
	math.floor(Timings.ms("keylogger", "ingest_tick_ms") / PERIODIC_TICK_MS))

local DEFAULT_CONFIG_DIR = require("infra.config_paths").config("hotstrings")

-- How many candidates the preview asks the engine for. The panel itself caps the
-- rows it draws; this cap is about the WORK — the enumeration runs on every
-- keystroke, and a bucket for a common tail character holds hundreds of mappings.
-- Slightly above the panel's own limit so it never shows fewer than it could.
local PREVIEW_MAX_CANDIDATES = 8

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
		-- Grab the device by default. Observe mode lets every physical keystroke
		-- reach the application while the daemon is mid-expansion, which is the
		-- "abcd" -> "acd" corruption: the user's next keys interleave with the
		-- synthetic backspaces. --no-grab is the escape hatch, not the default,
		-- because the default has to be the correct behaviour.
		grab    = true,
	}
	local i = 1
	while i <= #arg do
		local a = arg[i]
		if     a == "--help"    or a == "-h"  then opts.help    = true
		elseif a == "--dry-run"               then opts.dry_run = true
		elseif a == "--verbose" or a == "-v"  then opts.verbose = true
		elseif a == "--tray"                  then opts.tray    = true
		elseif a == "--no-grab"               then opts.grab    = false
		elseif a == "--config"  and arg[i+1]  then i = i + 1; opts.config = arg[i]
		elseif a == "--device"  and arg[i+1]  then i = i + 1; opts.device = arg[i]
		elseif a == "--layout"  and arg[i+1]  then i = i + 1; opts.layout = arg[i]
		elseif a == "--keymap"  and arg[i+1]  then i = i + 1; opts.keymap = arg[i]
		else
			Logger.warn(LOG, "Unknown argument '%s' — ignored.", tostring(a))
		end
		i = i + 1
	end
	return opts
end

--- Prints the CLI usage. Deliberately ENGLISH, not translated.
---
--- This runs from parse_args, long before i18n.init() — which cannot move
--- earlier, because the config directory it reads the persisted locale from is
--- itself settable with --config. So at this point the user's chosen language is
--- genuinely unknown, and routing the text through i18n would render it in the
--- default locale rather than theirs. Every other pre-i18n surface in this file
--- (the two startup error prints) is English for the same reason.
local function print_usage()
	print("Usage: luajit ergopti_hotstrings.lua [OPTIONS]")
	print("")
	print("  --config <path>     TOML file or directory of definitions.")
	print("                      Default: ~/.config/ergopti/hotstrings/")
	print("  --device <path>     evdev device (e.g. /dev/input/event3).")
	print("                      Default: auto-detected.")
	print("  --layout <name>     Keyboard layout: qwerty | azerty.")
	print("                      Default: $XKBLAYOUT, else qwerty.")
	print("  --tray              Enable the system tray icon.")
	print("  --no-grab           Do NOT take an exclusive grab on the device.")
	print("                      Physical keys then reach the application while an")
	print("                      expansion is being typed, which can scramble it.")
	print("                      Use only if the grab misbehaves on your hardware.")
	print("  --dry-run           Log matches without injecting.")
	print("  --verbose           Log at debug level for this run.")
	print("  --help              Show this message.")
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
	-- One level up, not two: SCRIPT_DIR is the driver root and _shared is its
	-- sibling. The old "../../" resolved outside the tree, so this fallback
	-- never found the bundled hotstrings and silently returned the default dir.
	local Paths = require("infra.paths")
	local shared = Paths.shared("modules/hotstrings")
	if not shared then return DEFAULT_CONFIG_DIR end
	local fh2 = io.open(shared, "r")
	if fh2 then
		fh2:close()
		return shared
	end
	return nil
end

--- Reloads the hotstring config.  Reached from the SIGHUP handler and from the
--- tray menu's Reload item, so it must be self-contained and not throw.
---
--- The menu used to reach this by shelling out `kill -HUP $$`, which signalled
--- the /bin/sh that os.execute had just spawned rather than this process — the
--- item logged success and reloaded nothing. There is no reason to leave the
--- process to signal itself: the menu now calls this directly.
--- @param trigger string What asked for the reload, for the log line.
local function perform_reload(trigger)
	Logger.info(LOG, "Reload requested by %s — reloading hotstring config…", trigger)
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
		shutdown.request("signal " .. tostring(sig))
		-- Keep the signal path self-contained after quiescence. The ordinary clean
		-- exit repeats both operations idempotently, but an unexpected loop backend
		-- failure must not leave the last metrics batch or the uinput FD behind.
		keylogger.flush()
		-- The coordinator stopped and ungrabbed the hook first. Closing this channel
		-- before that point can strand held keys because the hook restores them
		-- through the same uinput device.
		injector.close_fast_channel()
	end

	pcall(signal.signal, signal.SIGINT,  on_term)
	pcall(signal.signal, signal.SIGTERM, on_term)

	-- SIGHUP → hot reload.
	pcall(signal.signal, signal.SIGHUP,  function(_) perform_reload("SIGHUP") end)

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

	-- Restore the user's durable preference before the first line. --verbose is a
	-- one-run override: diagnostic output must not rewrite that preference.
	ScriptSettings.apply(opts.verbose and "DEBUG" or nil)

	Logger.start(LOG, "Ergopti hotstrings daemon starting…")

	if opts.dry_run then
		Logger.info(LOG, "Dry-run mode: matches will be logged but not injected.")
	end

	-- 8.1) Initialise the hotstring engine.
	local engine = engine_mod.new()

	-- 8.2) Initialise hotstrings_config and load all mappings.
	local config_path = resolve_config_path(opts.config)
	-- Forward-declared so hotstrings_config can call it: the menu is built much
	-- later (section 8.9), and a `local` declared after this closure would be
	-- captured as a nil global instead — the trap this repo has hit three times.
	local rebuild_tray_menu = nil

	-- The rebuild is what makes a toggle visible. Without it the menu was drawn
	-- once at startup and only ever redrawn by the updater's callback, so every
	-- category the user enabled or disabled kept its old checkmark until restart.
	hotstrings_config.init(engine, config_path, function()
		if rebuild_tray_menu then rebuild_tray_menu() end
	end)
	if hotstrings_config.set_magic_key(MagicKey.get(), MagicKey.default()) ~= true then
		error("The configured magic key cannot be applied to the hotstring catalogue.")
	end

	-- Dynamic hotstrings come up BEFORE the catalogue is loaded, not after, because
	-- the prefix expansions they build from personal_info.toml are part of what
	-- load_all() assembles. Initialising them afterwards would need a second full
	-- load — magickey.toml alone is 305 KB — to pick the mappings up.
	--
	-- The magic key is declared once, in the shared feature manifest, and every
	-- driver reads it from there. Linux used to hardcode a backslash while the
	-- manifest, both other drivers, the shared engine and the onboarding page all
	-- say "★" — so the @-tag expansions were the only feature in the product
	-- listening for a different key, and the personal-info editor told the user so.
	-- Through MagicKey, not the manifest default: the default is what ships, and
	-- reading it here would ignore a key the user chose from the menu.
	if dyn_hotstrings then
		dyn_hotstrings.init({ trigger_char = MagicKey.get() })
		Logger.info(LOG, "Dynamic hotstrings initialised (%d rule(s)).",
			dyn_hotstrings.get_rules_count())

		-- Rebuilt on every load rather than cached: the user can edit
		-- personal_info.toml or switch a prefix family off, and either has to change
		-- what the engine holds. The gate is read here and not at match time because
		-- the ordinary matcher knows nothing about dynamic families.
		hotstrings_config.set_extra_mappings_provider(function()
			return dyn_hotstrings.prefix_mappings()
		end)
	end

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
		print("Error: no keyboard device detected. Specify one with --device.")
		os.exit(1)
	end
	Logger.info(LOG, "Using device: %s.", device)

	-- Focused app id, cached off the input path by the process_lifecycle
	-- onFocusChange callback (see 8.12). Declared BEFORE on_char so on_char
	-- captures it as an upvalue — otherwise on_char would read a never-assigned
	-- global that stays nil, silently disabling password-app suppression.
	local _cached_app_id = nil

	-- The expansion that just fired, kept only until the next keystroke. A
	-- Backspace pressed immediately after an expansion means "that is not what I
	-- wanted": the trigger comes back instead of the user having to delete the
	-- replacement by hand and retype it. Cleared by anything else, because an
	-- undo two words later would resurrect text from nowhere.
	local _undoable = nil

	-- The suggestion currently on offer, so the same one is counted once rather
	-- than once per keystroke while it stays on screen. Declared here for the
	-- same reason as the line above: the closure that reads it is below.
	local _last_offered = nil

	-- A control can change while app ID and window title stay identical. Raw Tab
	-- and pointer events therefore invalidate the AT-SPI verdict synchronously;
	-- the periodic loop probes only after the desktop has consumed the event.
	local secure_focus_guard = FocusGuard.new({
		detector   = secure_field_detector,
		keylogger  = keylogger,
		prediction = prediction_engine,
		now_ms     = Monotonic.now_ms,
		settle_ms  = Timings.ms("privacy", "focus_settle_ms"),
		reset_text = function()
			_undoable = nil
			_last_offered = nil
			if tooltip_preview then tooltip_preview.hide() end
			if llm_overlay then llm_overlay.hide() end
			engine:reset()
		end,
	})
	-- Close the input path before the hook starts, then publish a conclusive
	-- initial answer if the accessibility service is already usable.
	secure_focus_guard.prime()
	if input_capture_gate ~= nil then error("input capture gate already initialised") end
	input_capture_gate = InputCaptureGate.new({
		on_block = function()
			_undoable = nil
			_last_offered = nil
			engine:reset()
			secure_focus_guard.invalidate()
			if tooltip_preview then tooltip_preview.hide() end
			if llm_overlay then llm_overlay.hide() end
			if prediction_engine and type(prediction_engine.cancel) == "function" then
				prediction_engine.cancel()
			end
		end,
	})

	-- 8.5) Define the character callback.
	local on_char
	local function handle_char(ch, scancode)
		-- If an injection is in flight, queue this character so it is replayed
		-- after the synthetic backspace+replacement events complete. This
		-- prevents physical keystrokes from interleaving with injected text
		-- and corrupting the output (the "abcd"→"acd" class of race bug).
		if injector._is_injecting() then
			injector._queue_char({ char = ch, scancode = scancode })
			return
		end

		-- The raw Tab has already been passed through to the desktop. Its target
		-- control is not necessarily focused yet, so invalidate now and wait for
		-- the off-input-path settle/probe cycle. Nothing from the new control may
		-- reach a hotstring, metric buffer, log, or model in that interval.
		if ch == "\t" then
			secure_focus_guard.invalidate()
			return
		end
		if secure_focus_guard.blocks_text() then return end

		-- The preview describes the buffer as it was; the character being typed
		-- now changes it. Dismissed here rather than redrawn, because the redraw
		-- (if any) happens below once the engine has re-evaluated.
		if tooltip_preview and tooltip_preview.is_visible() then tooltip_preview.hide() end

		-- Any keystroke that is not the immediate Backspace ends the undo window.
		-- Kept this narrow deliberately: an undo that survived a word of typing
		-- would insert a trigger in a place the user had moved on from.
		_undoable = nil

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

		-- `is_terminator` opens the engine's end-char path, where a trigger that
		-- did NOT opt into auto_expand is allowed to fire. Without it every entry
		-- behaved as auto and "ya" expanded in the middle of "yaourt".
		-- `terminator_consumed` stays separate: every end-char must be erased to
		-- reach the trigger, but only catalogue entries with consume=true stay
		-- erased. The others are replayed after the replacement.
		local is_terminator = terminators_mod.is_terminator(ch)
		local result = engine:on_char(ch, {
			is_terminator       = is_terminator,
			terminator_consumed = is_terminator
				and terminators_mod.terminator_is_consumed(ch),
			typed_at_ms         = now_ms,
		})

		-- The per-category expansion delay, which nothing consumed until 2026-08-05.
		-- hotstrings_config.resolve() had no production caller at all: the whole
		-- five-rung cascade, the shared DelayResolver and every override the
		-- settings window persisted resolved into nothing, so setting a delay saved
		-- it to disk and changed no behaviour.
		--
		-- The semantics are macOS's, read out of keymap/init.lua so the two agree:
		-- the delay is the maximum PAUSE BETWEEN ANY CONSECUTIVE KEYSTROKES in the
		-- consumed trigger, and 0 means "always". The engine keeps timestamps aligned
		-- with its rolling buffer, including resets and chained expansions, so an
		-- earlier pause cannot disappear merely because the final pair was quick.
		if result and hotstrings_config and type(hotstrings_config.resolve) == "function" then
			local ok_delay, resolved = pcall(hotstrings_config.resolve, result.group, result.section)
			local delay_sec = ok_delay and type(resolved) == "table" and tonumber(resolved.delay) or nil
			if delay_sec and not engine_mod.within_interkey_delay(result, delay_sec) then
				Logger.debug(LOG,
					"Expired: '%s' had a %.2fs pause, its category allows %.2fs.",
					tostring(result.trigger),
					(tonumber(result.max_interkey_gap_ms) or math.huge) / 1000, delay_sec)
				result = nil
			end
		end

		-- The magic-key repeat, when nothing else matched: `po★` gives `poo`. A real
		-- match always wins, which is why this is tested against `result` being nil
		-- rather than run before the engine.
		if not result and RepeatKey.is_enabled() then
			local repeated = RepeatKey.resolve(engine:current_buffer(), MagicKey.get())
			if repeated then
				result = {
					trigger         = MagicKey.get(),
					replacement     = repeated.replacement,
					backspace_count = repeated.backspace_count,
					group           = "repeat_key",
					final_result    = true,
				}
			end
		end

		if result then
			-- A private mapping's trigger is a fragment of its own secret — the
			-- first six characters of the IBAN, the first five digits of the SSN —
			-- so neither half of this line may be printed. The driver's default
			-- level is DEBUG and this log is kept for 14 days, which makes it the
			-- same sink as the database as far as a leak is concerned.
			if result.is_private then
				Logger.info(LOG, "Match: private mapping fired (content withheld, bc=%d).",
					result.backspace_count)
			else
				Logger.info(
					LOG,
					"Match: trigger='%s' → '%s' (bc=%d).",
					result.trigger,
					result.replacement,
					result.backspace_count
				)
			end
			local expansion_committed = opts.dry_run
			if not opts.dry_run then
				injector._begin_injection()
				local replay_terminator = result.end_char
					and not result.consume_terminator and result.terminator or nil
				local ok_delivery, delivery = pcall(
					injector.inject,
					result.backspace_count,
					result.replacement,
					result.is_private,
					replay_terminator
				)
				local queued_input = injector._end_injection()
				expansion_committed = ok_delivery and type(delivery) == "table"
					and delivery.ok == true
				local delivery_error = ok_delivery and type(delivery) == "table"
					and delivery.error or delivery

				if expansion_committed then
					-- Logical telemetry and undo are commit records: publishing either
					-- before the last checked SYN_REPORT invents an expansion the target
					-- application may never have received.
					keylogger.record_hotstring(app_id, result.trigger, result.replacement,
						now_ms, result.group, result.backspace_count, result.is_private)
					_undoable = {
						trigger     = result.trigger,
						replacement = result.replacement,
					}
					-- Replay queued input only after output committed. On failure the
					-- hook emergency-ungrabs and the logical text position is unknown.
					for _, queued in ipairs(queued_input) do
						local queued_ch = type(queued) == "table" and queued.char or queued
						local queued_scancode = type(queued) == "table" and queued.scancode or nil
						local ok, err = pcall(on_char, queued_ch, queued_scancode)
						if not ok then
							Logger.error(LOG, "Error replaying queued char '%s': %s",
								queued_ch, tostring(err))
						end
					end
				else
					_undoable = nil
					engine:reset()
					Logger.error(LOG, "Expansion output did not commit — logical state invalidated: %s.",
						tostring(delivery_error))
				end
			end
			-- final_result means "this expansion is the end of it": drop the
			-- buffer so nothing can chain off the replacement. Otherwise keep the
			-- expanded text in the buffer, which is what Windows and macOS do —
			-- resetting unconditionally is why Linux could never chain, and made
			-- final_result unobservable here.
			if expansion_committed then
				if result.final_result then
					engine:reset()
				else
					engine:apply_expansion(result)
				end
			end
		end

		-- The preview bubble, which nothing drew until 2026-08-05.
		--
		-- ui/tooltip/preview.lua was complete — it gates on the four toggles,
		-- resolves the accent, builds the rows and calls the renderer — and
		-- `M.show` had no caller anywhere in the driver. So the whole preview
		-- surface was inert on every desktop and in every configuration, even with
		-- lgi installed and the renderer reporting itself available, and the four
		-- toggles above it governed nothing.
		--
		-- Skipped entirely when an expansion just fired: the bubble describes what
		-- is ABOUT to happen, and after a match the buffer no longer says that.
		if tooltip_preview and not result then
			local ok_preview, err_preview = pcall(function()
				local candidates = engine:candidates(PREVIEW_MAX_CANDIDATES)
				-- The @-family's SECOND candidate source. `engine:candidates()` reads
				-- the static matcher's buckets, and no @-tag has ever been in them:
				-- the single-letter tags live in the dynamic engine and the
				-- multi-letter combos are resolved at fire time and registered
				-- nowhere. So the whole family expanded correctly and previewed
				-- nothing — the identical gap Windows had, closed the identical way.
				--
				-- Prepended, not appended: this row is the one the magic key will
				-- actually deliver (the static matcher has nothing for "@…"), and the
				-- bubble renders the first row undimmed.
				if dyn_hotstrings and type(dyn_hotstrings.preview_candidates) == "function" then
					local extra = dyn_hotstrings.preview_candidates(engine:current_buffer())
					for index = #extra, 1, -1 do
						table.insert(candidates, 1, extra[index])
					end
				end
				if #candidates == 0 then
					tooltip_preview.hide()
					-- Nothing is on offer any more, so the next distinct offer counts
					-- again even if it repeats the one before.
					_last_offered = nil
					return
				end
				-- "star" while the last character typed is the magic key, since that
				-- is the family about to validate; "autocorrect" otherwise. The kind
				-- decides which of the four toggles gates the bubble.
				local kind = (ch == MagicKey.get()) and "star" or "autocorrect"
				tooltip_preview.show(candidates, kind)

				-- Counted once per DISTINCT offer, not once per keystroke. The bubble
				-- redraws on every character while the same candidate stays on top,
				-- and counting each redraw would inflate the denominator without
				-- bound — the acceptance rate would fall towards zero the longer the
				-- user hesitated, which is backwards.
				local top = candidates[1]
				local offered = type(top) == "table" and (top.trigger or top.key or top.label) or tostring(top)
				if offered and offered ~= _last_offered then
					_last_offered = offered
					keylogger.record_suggestion(app_id, "hotstring", now_ms)
				end
			end)
			if not ok_preview then
				Logger.error(LOG, "Preview failed for '%s': %s", tostring(ch), tostring(err_preview))
			end
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
				pcall(function()
					prediction_engine.on_char(ch, buf, {
						app_id = app_id,
						hotstring_preview_visible = tooltip_preview
							and tooltip_preview.is_visible() or false,
					})
				end)
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
						-- The seventh argument is not optional, whatever its default
						-- says. The STATIC path a hundred lines up has always passed
						-- `result.is_private`; this one never did, so every @-tag
						-- expansion — the single-letter ones included, which have
						-- existed since this driver shipped — wrote its resolved value
						-- into the keylogger's per-character synthetic record in full.
						-- For "@i★" that is the user's IBAN, one entry per character,
						-- persisted and replicated. Windows redacts the equivalent
						-- record and macOS skips it; Linux was writing it.
						keylogger.record_hotstring(app_id, dynamic_event.trigger,
							dynamic_event.replacement, now_ms, dynamic_event.h_type,
							dynamic_event.backspace_count, dynamic_event.is_private)
					end
					-- Dynamic expansion consumed the trigger — reset the engine
					-- buffer so the expansion text doesn't trigger further matches.
					engine:reset()
				end
			end
		end


	end
	on_char = input_capture_gate.guard(handle_char)

	-- All physical keydowns, including modifiers and navigation keys, feed the
	-- separate hardware heatmap. Character handling above records only printable
	-- output, so this callback is the single place that prevents special keys
	-- from disappearing and avoids a printable-key double count.
	local capture_owned_scancodes = {}
	local function handle_physical(scancode, _key_name, _char, value)
		if value ~= InputEvent.VALUE_DOWN then return end
		local app_id = _cached_app_id or "Unknown"
		if keylogger.is_password_app(app_id) then
			keylogger.suppress()
		else
			keylogger.unsuppress()
		end
		keylogger.record_physical_key(app_id, scancode, math.floor(Monotonic.now_ms()))
	end
	local on_physical = input_capture_gate.guard(handle_physical,
		function(scancode, _key_name, _char, value)
			if value == InputEvent.VALUE_DOWN then capture_owned_scancodes[scancode] = true end
		end)

	-- 8.6) Initialise the LLM prediction engine if available.
	-- Use the shared canonical DEFAULT_CONTEXT_LENGTH from the linux_bridge
	-- (mirrors _shared/modules/llm/defaults.json llm_context_length = 500)
	-- so all three drivers send the same context window.
	if prediction_engine then
		local canonical_ctx = 500  -- defensive fallback
		local ok_lb, lb = pcall(require, "infra.llm_bridge")
		if ok_lb and lb and lb.DEFAULT_CONTEXT_LENGTH then
			canonical_ctx = lb.DEFAULT_CONTEXT_LENGTH
		end
		prediction_engine.init({
			engine        = engine,
			keyboard_hook = keyboard_hook,
			triggers      = { "//", ";;", "--" },
			max_context   = canonical_ctx,
			overlay       = llm_overlay,
			apply_prediction = function(candidate)
				local result = injector.inject(candidate.deletes, candidate.to_type, false)
				return type(result) == "table" and result.ok == true
			end,
			on_offer = function(context)
				local output_app = type(context) == "table" and context.app_id or _cached_app_id
				keylogger.record_suggestion(output_app or "Unknown", "llm", math.floor(Monotonic.now_ms()))
			end,
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
	-- 8.7) Define the control-key callback.
	local function handle_control(key_name, detail)
		-- A modifier chord. Two things happen here that could not happen before,
		-- because the hook reported the bare string "shortcut" and dropped which
		-- key it was: the user's own binding runs, and the press is recorded.
		--
		-- Recorded whether or not anything is bound to it. The metrics question is
		-- "what does this person press", and answering it only for the chords the
		-- daemon happens to own would make the dashboard a picture of the driver's
		-- configuration rather than of the user's habits.
		if key_name == "shortcut" and type(detail) == "table" then
			local chord = keyboard_shortcuts.chord_name(detail)
			if chord then
				keylogger.record_shortcut(_cached_app_id or "Unknown", chord,
					math.floor(Monotonic.now_ms()))
			end
			-- The same master switch gates CapsWord and every menu operation. It must
			-- also gate modifier chords; otherwise "Shortcuts off" still opens ChatGPT
			-- and runs the user's assignments while claiming the feature is disabled.
			if shortcuts and shortcuts.is_enabled() then
				pcall(keyboard_shortcuts.dispatch, detail)
			end
		end
		-- Modified Tab (Alt+Tab, Ctrl+Tab) reaches the control callback rather
		-- than on_char. It can cross a privacy boundary just as bare/Shift+Tab can.
		if key_name == "tab" then
			secure_focus_guard.invalidate()
			return
		end

		-- Undo: a Backspace immediately after an expansion puts the trigger back.
		--
		-- The arithmetic is off by one on purpose. Under a grab the Backspace was
		-- re-emitted to the application BEFORE this callback ran, so it has already
		-- removed one character of the replacement; the erase here has to cover
		-- what is left. Counted in codepoints, not bytes: "N'T" is three
		-- characters and four bytes, and erasing four would eat the character
		-- before it.
		if key_name == "backspace" and _undoable and not opts.dry_run then
			local remaining = 0
			for _ in _undoable.replacement:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
				remaining = remaining + 1
			end
			if remaining >= 1 then
				Logger.info(LOG, "Undo: restoring trigger '%s'.", _undoable.trigger)
				injector.inject(remaining - 1, _undoable.trigger)
				engine:reset()
				_undoable = nil
				return
			end
		end
		_undoable = nil

		engine:reset()
		-- Cancel any in-flight LLM prediction on Backspace or Escape.
		if key_name == "backspace" or key_name == "escape" then
			if prediction_engine then
				pcall(function() prediction_engine.cancel() end)
			end
		end
		Logger.debug(LOG, "Control key '%s' — buffer reset.", key_name)
	end
	local on_control = input_capture_gate.guard(handle_control)

	-- 8.7b) A pointer click moves the caret.
	--
	-- Every character in the buffer describes text at a position the user has
	-- just left, so an expansion after a click would fire against a line that is
	-- no longer under the cursor — and erase characters belonging to whatever is
	-- there now. The pointer is watched, never grabbed.
	local function on_click()
		secure_focus_guard.invalidate()
		Logger.debug(LOG, "Pointer click — text privacy state invalidated.")
	end

	-- 8.7b) Restore the word-delimiter choices.
	--
	-- The shared catalogue keeps them in memory only, so every delimiter the user
	-- switched off came back on at the next start — and the feature exists
	-- precisely so a user can say "expand on ★ and nothing else". A setting that
	-- forgets itself is worse than one that is missing.
	-- The FULL state, both directions, plus the user's own delimiters.
	--
	-- This stored only the OFF list until 2026-08-05, and that is not the same
	-- thing: 15 of the 25 catalogue delimiters ship DISABLED, so a user who
	-- switched ")" or "/" on got it for the session and found it off again after
	-- a restart, with nothing said. Recording a delta against a default only works
	-- when the default is one-sided, and this one is not.
	--
	-- Custom delimiters were not stored at all, so one added from the menu
	-- vanished at the next start.
	local TERMINATORS_KEY = "hotstrings.terminator_state"
	local CUSTOM_TERMINATORS_KEY = "hotstrings.custom_terminators"

	-- The record separator inside each stored list. Chosen because a delimiter is
	-- a single printable character and a comma is a plausible one, so the old
	-- comma-joined format could not have held custom entries unambiguously.
	local RECORD_SEP = "\30"
	local FIELD_SEP = "\31"

	local function persist_terminators()
		if not terminators_mod or type(terminators_mod.get_terminator_defs) ~= "function" then return false end
		local ok_storage, Storage = pcall(require, "adapters.storage")
		if not ok_storage or type(Storage.set_many) ~= "function" then
			Logger.error(LOG, "Word-delimiter state could not be persisted — storage is unavailable.")
			return false
		end

		local state, custom = {}, {}
		for _, def in ipairs(terminators_mod.get_terminator_defs() or {}) do
			if def.key then
				state[#state + 1] = def.key .. FIELD_SEP
					.. (terminators_mod.is_terminator_enabled(def.key) and "1" or "0")
				if def.custom then
					local char = type(def.chars) == "table" and def.chars[1] or nil
					if char then
						custom[#custom + 1] = table.concat({
							def.key, char, def.label or char, def.consume and "1" or "0",
						}, FIELD_SEP)
					end
				end
			end
		end
		table.sort(state)
		table.sort(custom)
		local persisted = Storage.set_many({
			[TERMINATORS_KEY] = table.concat(state, RECORD_SEP),
			[CUSTOM_TERMINATORS_KEY] = table.concat(custom, RECORD_SEP),
		})
		if not persisted then
			Logger.error(LOG, "Word-delimiter state could not be persisted — the menu change was refused.")
			return false
		end
		return true
	end

	local function restore_terminators()
		if not terminators_mod or type(terminators_mod.set_terminator_enabled) ~= "function" then return end
		local ok_storage, Storage = pcall(require, "adapters.storage")
		if not ok_storage then return end

		-- The user's own delimiters first: their enabled state is in the same list
		-- as the catalogue's, and applying it to a delimiter that does not exist yet
		-- would be dropped.
		local restored_custom = 0
		local raw_custom = Storage.get(CUSTOM_TERMINATORS_KEY, "")
		if type(raw_custom) == "string" and raw_custom ~= "" then
			for record in raw_custom:gmatch("[^" .. RECORD_SEP .. "]+") do
				local fields = {}
				for field in record:gmatch("[^" .. FIELD_SEP .. "]+") do fields[#fields + 1] = field end
				if #fields >= 4 and type(terminators_mod.add_custom_terminator) == "function" then
					terminators_mod.add_custom_terminator(fields[1], fields[2], fields[3], fields[4] == "1")
					restored_custom = restored_custom + 1
				end
			end
		end

		local applied = 0
		local raw = Storage.get(TERMINATORS_KEY, "")
		if type(raw) == "string" and raw ~= "" then
			for record in raw:gmatch("[^" .. RECORD_SEP .. "]+") do
				local key, flag = record:match("^(.-)" .. FIELD_SEP .. "([01])$")
				if key then
					terminators_mod.set_terminator_enabled(key, flag == "1")
					applied = applied + 1
				end
			end
		end

		Logger.info(LOG, "Restored %d word-delimiter state(s) and %d custom delimiter(s).",
			applied, restored_custom)
	end

	restore_terminators()

	-- 8.8) Start the keyboard hook adapter, in INTERCEPT mode by default.
	--
	-- Observe mode does not grab the device, so every physical keystroke reaches
	-- the application in real time no matter what the daemon is doing. During the
	-- erase-then-type window of an expansion the user's next keys interleave with
	-- the synthetic backspaces and the replacement, and the screen ends up
	-- scrambled non-deterministically — the "abcd" -> "acd" corruption. The
	-- injector's queue (_begin/_queue/_end_injection) only does anything once the
	-- daemon OWNS the output stream, which is what the grab buys.
	--
	-- What makes this affordable: the channel opened immediately below. Under a
	-- grab the daemon is the only remaining path to the application, so every
	-- physical event it consumes has to be put back — and the fallback does that
	-- by forking `ydotool key` ONCE PER EVENT, on the input path. Writing struct
	-- input_event straight to /dev/uinput is what a grab can pay for; a fork per
	-- keystroke is not, which is why the open is a precondition of the start
	-- below and not an optimisation applied later.
	--
	-- The two daemons are coordinated through names, not luck: the generated
	-- remap config excludes our uinput device by exact name, and device_finder
	-- asks for the remap daemon's output device before it ranks anything else. So
	-- the grab lands on the stream carrying POST-remap keycodes — the same ones
	-- the application receives — and neither daemon can grab the other's output.
	-- STILL UNVERIFIED ON HARDWARE. `--no-grab` restores the old behaviour without
	-- a rebuild, which is why that flag exists — but observe mode is a
	-- known-corrupting default, so it is the escape hatch and not the norm.
	-- Open the non-forking re-emit channel BEFORE the grab, never after. The
	-- ordering is the whole point: between a grab and an open channel the daemon
	-- owns the keyboard and can only give keys back one fork at a time, which is
	-- the state the grab was held back for in the first place.
	if not injector.open_fast_channel() and opts.grab then
		-- Fail here, loudly, rather than three layers down as "no hotstrings
		-- happen". A grab with no way to put keys back is a dead keyboard, and the
		-- reason is almost always one the user can act on: /dev/uinput needs the
		-- uinput group and the module loaded. Silence used to be the answer to all
		-- three of "wrong permissions", "module absent" and "no FFI".
		Logger.error(LOG, "Cannot open /dev/uinput — refusing to grab the keyboard.")
		print("Erreur : impossible d'ouvrir /dev/uinput.")
		print("Le daemon a besoin d'y écrire pour rendre les touches qu'il intercepte.")
		print("Corrigez les permissions (bash install.sh --setup-perms) ou lancez avec --no-grab.")
		os.exit(1)
	end

	-- Resolve the OUTPUT layout before the first expansion can fire. This is the
	-- inverse of the capture layout and a different question entirely: capture
	-- turns a keycode into the character the user typed, injection turns a
	-- character into the keycode that produces it under THEIR layout. Without it
	-- every accented replacement is typed as whatever the US layout would put on
	-- that key, which is the defect ydotool has never been able to fix.
	if not keyboard_layout.refresh(opts.keymap) then
		Logger.warn(LOG, "Layout unresolved — replacements will not be typed as keystrokes.")
	end
	local on_consume = input_capture_gate.guard(function(detail)
		return prediction_engine
			and type(prediction_engine.handle_shortcut) == "function"
			and prediction_engine.handle_shortcut(detail) == true
	end)
	local function handle_hold(scancode, held_ms)
		if capture_owned_scancodes[scancode] then
			capture_owned_scancodes[scancode] = nil
			return
		end
		keylogger.record_hold(_cached_app_id or "Unknown", scancode, held_ms)
	end
	local on_hold = input_capture_gate.guard(handle_hold, function(scancode)
		capture_owned_scancodes[scancode] = nil
	end)

	keyboard_hook.start({
		device = device,
		pinned = opts.device ~= nil,
		layout = opts.layout,
		intercept  = opts.grab,
		onChar  = on_char,
		onKey   = on_control,
		onClick = on_click,
		onPhysical = on_physical,
		onConsume = on_consume,
		onDesync = function()
			_undoable = nil
			_last_offered = nil
			if tooltip_preview then tooltip_preview.hide() end
			if prediction_engine then prediction_engine.cancel() end
			engine:reset()
		end,
		-- How long each key was held. The release is seen only inside the hook,
		-- which is why the measurement lives there and the accounting here.
		onHold = on_hold,
		onEmitRaw  = injector.emit_key,
	})
	Logger.info(LOG, "Keyboard hook started in %s mode.",
		opts.grab and "INTERCEPT (device grabbed)" or "OBSERVE (--no-grab)")

	if not keyboard_hook.isRunning() then
		Logger.error(LOG, "Keyboard hook failed to start — exiting.")
		print("Error: could not start the keyboard hook.")
		os.exit(1)
	end

	-- 8.8b) Initialise i18n (loads persisted locale, enables ★ substitution).
	--
	-- BEFORE the tray, and this ordering is the whole point. init() is what reads
	-- the locale the user chose; until it runs, i18n answers in the default, which
	-- is French. Running it after section 8.9 meant the first tray a non-French
	-- user ever saw was drawn entirely in French, and stayed that way until
	-- something happened to rebuild the menu.
	local ok_i18n, i18n_mod = pcall(require, "infra.i18n")
	if ok_i18n and i18n_mod then
		i18n_mod.init()
		-- From the manifest, like every other reader of this value. This was the
		-- last hardcoded backslash: the i18n layer substitutes the magic key into
		-- every localised label that mentions it, so a driver that answered "\"
		-- here printed the wrong key in 21 languages while the engine listened for
		-- ★ — a menu that documented a keystroke nothing responded to.
		-- Read on every substitution rather than captured once, so changing the key
		-- from the menu relabels the 21 locales without a restart.
		i18n_mod.set_trigger_provider(function()
			return MagicKey.get()
		end)
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
				-- The dynamic-hotstrings manager, so its category can be a real row
				-- rather than the greyed "(no group loaded)" the manifest's
				-- hotstring_categories_dynamic used to resolve to: this driver's
				-- groups come from TOML file stems, and there is no dynamic TOML.
				dyn_hotstrings = dyn_hotstrings,
				layout        = opts.layout,
				log_level     = ScriptSettings.current(),
				-- Applied live rather than logged. The qwerty/azerty label describes
				-- the physical family used by heatmaps and finger metrics; text capture
				-- follows the active XKB state and never trusts this two-value label.
				--
				-- refresh() gives the same freshly dumped server keymap to stateful
				-- capture and to the inverse injection table, so hot system changes
				-- cannot update only one direction.
				on_layout_change = function(new_layout)
					Logger.start(LOG, "Applying layout '%s'…", tostring(new_layout))
					if not keyboard_hook.set_layout(new_layout) then
						Logger.error(LOG, "Layout '%s' refused — nothing changed.", tostring(new_layout))
						return
					end
					if not keyboard_layout.refresh(opts.keymap) then
						Logger.warn(LOG,
							"Physical layout label applied; active XKB keymap refresh failed.")
					end
					opts.layout = new_layout
					if webview_manager and webview_manager.set_daemon_state then
						webview_manager.set_daemon_state({
							engine = engine, keylogger = keylogger,
							config = hotstrings_config, llm = prediction_engine,
							gestures = gestures, magic_key = MagicKey,
							input_capture_gate = input_capture_gate,
							layout = new_layout,
							on_config_changed = function()
								if rebuild_tray_menu then rebuild_tray_menu() end
							end,
						})
					end
					-- So the tick moves to the row the user just chose. Without it the
					-- menu still marks the old layout and the change reads as ignored.
					if rebuild_tray_menu then rebuild_tray_menu() end
					Logger.success(LOG, "Layout '%s' applied.", tostring(new_layout))
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
			on_quit       = function() shutdown.request("tray quit") end,
			-- Same code path the SIGHUP handler takes. The menu item used to
			-- shell out "kill -HUP $$", which signals the /bin/sh os.execute
			-- spawned — never this process — so Reload logged success and
			-- reloaded nothing.
			on_reload     = function() perform_reload("the tray menu") end,
			-- Opens one category's TOML in the user's editor. The category submenu
			-- offers it because a pack is a file people edit, and finding it by
			-- hand means knowing whether it came from the bundle or the user's own
			-- directory — which is exactly what the loader already resolved.
			-- Called by any menu row whose change the menu itself must reflect.
			-- Persisting here rather than in the shared catalogue keeps that module
			-- free of a storage dependency it has no other reason to carry.
			on_persist_terminators = persist_terminators,
			on_menu_changed = function()
				if rebuild_tray_menu then rebuild_tray_menu() end
			end,
			-- Adding a delimiter needs a text field, and this driver's only text
			-- field is the settings window. Opening it is honest; a native prompt
			-- would mean a second dialog toolkit for one input.
			on_add_delimiter = function()
				if type(webview_manager) == "table" and type(webview_manager.show) == "function" then
					-- The directory name under _shared/ui/, which is what
					-- webkit_host.resolve_app_dir() looks for. It used to say
					-- "hotstrings_config": that name has a bridge in BRIDGE_MODULES but
					-- no page on disk, so the window opened and rendered
					-- "Error: app 'hotstrings_config' not found".
					webview_manager.show("hotstrings_config_window")
				else
					Logger.warn(LOG, "No settings window available — a custom delimiter cannot be added.")
				end
			end,
			on_open_file = function(path)
				if type(path) ~= "string" or path == "" then return end
				Logger.info(LOG, "Opening hotstring file: %s", path)
				-- "'\\''" in Lua source is the four characters '\'' — the POSIX
				-- close-escape-reopen idiom. Written "'\''" it collapses to three
				-- apostrophes, which closes the quote and leaves the rest of the path
				-- unquoted: a pack under "/home/me/l'ergopti" then reached xdg-open as
				-- two broken words and silently opened nothing.
				os.execute(string.format("xdg-open '%s' 2>/dev/null &", path:gsub("'", "'\\''")))
			end,
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
			-- The two rows the shared manifest has always declared for this platform
			-- and that this driver never built: they are translated in all 21
			-- locales and present on the other two drivers. Both paths come from
			-- the sink that writes them, so neither can name a file nobody fills.
			on_open_today_log = function()
				local path = LoggerSink.main_log_path()
				Logger.info(LOG, "Opening today's log: %s", path)
				os.execute(string.format("xdg-open '%s' 2>/dev/null &", path:gsub("'", "'\\''")))
			end,
			on_open_error_log = function()
				local path = LoggerSink.errors_log_path()
				Logger.info(LOG, "Opening the errors log: %s", path)
				os.execute(string.format("xdg-open '%s' 2>/dev/null &", path:gsub("'", "'\\''")))
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
			-- Called directly. These used to be guarded by `if
			-- hotstrings_config.enable_all then`, and the functions did not exist —
			-- so the guard was false, the row did nothing, and a click that did
			-- nothing is indistinguishable from a click that missed.
			on_enable_all  = function() hotstrings_config.enable_all() end,
			on_disable_all = function() hotstrings_config.disable_all() end,
			on_reset_defaults = function() hotstrings_config.reset_defaults() end,
			on_set_log_level = function(lvl)
				if not ScriptSettings.set(lvl) then return end
				Logger.info(LOG, "Log level set to %s.", lvl)
				if rebuild_tray_menu then rebuild_tray_menu() end
			end,
			}
		end

		rebuild_tray_menu = function()
			local ctx = _build_menu_ctx()
			-- Probed here rather than inside the builder. Answering truthfully means
			-- asking the system whether ANY kanata is running — including one under
			-- systemd — and that is a subprocess. Building a menu must not spawn
			-- one, so the daemon does it at the moment it decides to rebuild and
			-- hands the answer over as state.
			if kanata then
				local ok_state, running = pcall(kanata.is_running)
				ctx.kanata_running = ok_state and running or false
			end
			local ok_build, items = pcall(menu_builder.build, ctx)
			if not ok_build then
				Logger.error(LOG, "Menu rebuild failed — %s", tostring(items))
				return
			end
			tray_menu.setMenu(items)
		end
		rebuild_tray_menu()
		else
			-- The degraded tray, shown when the menu builder is unavailable.
			--
			-- The only two rows in this driver the shared renderer does not draw,
			-- and deliberately: they exist FOR the case where the menu subsystem
			-- failed to load, so routing them through it would make the fallback
			-- depend on the very thing it is there to survive without. Two rows,
			-- a name and a way out.
			--
			-- Their labels are still translated like every other one: this row
			-- carried the French word for « quit » written into the source, which is
			-- a label in one of the twenty-one languages this driver speaks.
			local quit_label = "Quitter"
			if ok_i18n and i18n_mod then
				quit_label = (i18n_mod.get("menu.global.quit"):gsub("^%S+%s+", ""))
			end
			tray_menu.setMenu({
				{ title = "Ergopti " .. (opts.layout or "qwerty"), fn = function() end },
				{ title = quit_label, fn = function() shutdown.request("degraded tray quit") end },
			})
		end
	elseif opts.tray and not tray_menu then
		Logger.warn(LOG, "Tray icon requested but the tray adapter could not load.")
	else
		-- Always state the tray decision: without this a launch that forgot --tray
		-- looks identical in the log to one where the adapter failed to load.
		Logger.info(LOG, "Tray icon disabled (no --tray) — running headless.")
	end

	-- 8.10) Install signal handlers.
	install_signal_handlers()

	-- 8.9b) Initialise the preview tooltip.
	--
	-- Fail-fast on the STYLE and soft on the renderer: a missing key in the
	-- shared constants is a broken install and must be loud, while an absent lgi
	-- is an ordinary machine that simply gets no preview.
	if tooltip_preview then
		local ok_style, style = pcall(function()
			return require("ui.tooltip.config").load()
		end)
		if ok_style then
			tooltip_preview.init({
				style = style,
				config = hotstrings_config,
				on_expire = function()
					if prediction_engine and type(prediction_engine.on_hotstring_expired) == "function" then
						prediction_engine.on_hotstring_expired(engine:current_buffer(), {
							app_id = _cached_app_id,
						})
					end
				end,
			})
			if llm_overlay and not llm_overlay.init({ style = style }) then llm_overlay = nil end
			Logger.info(LOG, "Preview tooltip initialised (renderer available: %s).",
				tostring(require("adapters.graphics_renderer").is_available()))
		else
			Logger.error(LOG, "Tooltip style unreadable — no preview. %s", tostring(style))
			tooltip_preview = nil
			llm_overlay = nil
		end
	end

	-- 8.9c) Apply the user's four preview toggles.
	--
	-- Until 2026-08-05 nothing did. preview.lua initialises its switch table to
	-- four `true`s at load and exposes set_enabled() to change them; no caller
	-- existed, so the manifest declared the four features for this driver, the
	-- renderer honoured them on the hot path, and the values could never be
	-- anything but the load-time ones. The stored choice is pushed in once here
	-- and again on every menu change, rather than read inside M.show — that runs
	-- on the keystroke that might fire a hotstring, and a file read belongs
	-- nowhere near it.
	if tooltip_preview then
		PreviewSettings.init(function(name, value)
			tooltip_preview.set_enabled(name, value)
		end)
		PreviewSettings.apply(tooltip_preview)
	end

	-- 8.10b) Let a magic-key change actually reach the engine.
	--
	-- MagicKey.set() has always fired an _on_change callback after persisting, and
	-- until 2026-08-05 nobody registered one — so changing the key from the menu
	-- relabelled the row, relabelled the 21 locales through the provider above,
	-- and left every expansion listening for the old character. That is worse than
	-- the feature being absent: the interface reports success and the product
	-- silently disagrees with it.
	--
	-- The dynamic rules bake the character into their triggers at registration
	-- time, so they have to be rebuilt; the catalogue reload covers the rest.
	MagicKey.init(function(new_char)
		Logger.info(LOG, "Magic key changed to '%s' — re-registering.", tostring(new_char))
		if hotstrings_config.set_magic_key(new_char, MagicKey.default()) ~= true then
			Logger.error(LOG, "Magic-key change refused by the catalogue — mappings remain unchanged.")
			return
		end
		if dyn_hotstrings then
			dyn_hotstrings.init({ trigger_char = new_char })
		end
		perform_reload("the magic key")
		if rebuild_tray_menu then rebuild_tray_menu() end
	end)

	-- 8.10b') Put the WPM widget back the way the user left it. Its visibility and
	-- colour mode were not stored at all until now, so a user who turned it on
	-- found it gone after the next restart with the menu row unticked — which
	-- reads as a control that does not work rather than one whose answer is not
	-- kept.
	if wpm_widget and type(wpm_widget.restore) == "function" then
		pcall(wpm_widget.restore)
	end

	-- 8.10c) Initialise the gestures manager (trackpad/mouse gesture recognition).
	if gestures then
		gestures.init({ persist = true })
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
			gestures  = gestures,
			magic_key = MagicKey,
			input_capture_gate = input_capture_gate,
			layout    = opts.layout,
			on_config_changed = function()
				if rebuild_tray_menu then rebuild_tray_menu() end
			end,
		})
		Logger.info(LOG, "WebView manager daemon state wired.")
	end

	if updater then
		-- The one release that has been notified, so a background check every few
		-- hours does not re-announce the same version for as long as the user
		-- leaves it uninstalled.
		local _notified_tag = nil

		local on_available = function(release)
			Logger.info(LOG, "Update available: %s — rebuilding menu.", release.tag)

			-- Told to the user, not only to the log. The other two drivers have
			-- notified here since the updater existed and the strings are already
			-- translated into all twenty-one locales; this driver wrote a log line
			-- nobody reads and left the news in the tray label.
			--
			-- The tag lands on the REPLACEMENT side of gsub, where "%" is special:
			-- a release tagged "v2.1%-rc1" would raise inside the notification and
			-- take the menu rebuild below with it.
			if notifier and ok_i18n and i18n_mod and release.tag ~= _notified_tag then
				_notified_tag = release.tag
				local safe_tag = tostring(release.tag):gsub("%%", "%%%%")
				local body = i18n_mod.get("updater.tray_new_version_body"):gsub("{1}", safe_tag)
				notifier.send(body, {
					title = i18n_mod.get("updater.tray_new_version_title"),
					level = "info",
				})
			end

			-- Rebuild the tray menu so the update label changes.
			if tray_menu and menu_builder then
				if rebuild_tray_menu then rebuild_tray_menu() end
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
			-- A focus change moves the caret to a different text context. The matcher
			-- and its aligned timing history must cross that boundary together.
			_undoable = nil
			if tooltip_preview then tooltip_preview.hide() end
			if llm_overlay then llm_overlay.hide() end
			engine:reset()
			_cached_app_id = (type(appName) == "string" and appName ~= "" and appName) or nil
			-- The private-browsing verdict is computed HERE, off the input path.
			-- The title was previously received and discarded, which is why the
			-- driver had no private-browsing filter at all.
			keylogger.set_private_window(keylogger.is_private_window(windowTitle))
			-- The title itself, which was received and discarded. The apps dashboard
			-- groups a day by window — the difference between "four hours in the
			-- editor" and "four hours across three files" — and this driver had
			-- nothing to group by. Handed over AFTER the private-window verdict, so
			-- a title that marks an incognito session is judged before it is stored.
			keylogger.set_window_title(_cached_app_id, windowTitle,
				math.floor(Monotonic.now_ms()))
			-- And the secure-field verdict, likewise. adapters/secure_field_detector
			-- was written, tested and never called: `refresh()` had no caller
			-- anywhere in the driver, so `isSecureField()` answered false forever and
			-- keylogger.set_secure_field was a setter nothing set. The whole
			-- password-field filter — the reason the metrics manifest ships
			-- secure_filter_enabled at all — was inert, and it fails in the direction
			-- that records what it exists to suppress.
			--
			-- Here rather than per keystroke, deliberately: the probe spawns an AT-SPI
			-- query, and the focused element is what it can answer about.
			secure_focus_guard.prime()
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
		-- Primed here too. Without it the first window of the session — which on a
		-- login that restores a password manager is exactly the window that matters
		-- — is recorded until the user switches away from it.
		secure_focus_guard.prime()
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
	local function stop_input_loop()
		shutdown.request("runtime callback failure", "runtime callback failure")
	end

	local on_periodic = function()
		tick_count = tick_count + 1
		-- Here rather than in onIdle: it re-reads /proc/bus/input/devices, which
		-- has no business on the keystroke path. A keyboard unplugged and plugged
		-- back in gets a new eventN node, and restarting the remap daemon
		-- recreates the device this one prefers — neither announces itself on the
		-- descriptor already held.
		if not RuntimeGuard.call("keyboard device watchdog", keyboard_hook.check_device,
			stop_input_loop) then return end
		if process_lifecycle then
			local owner = process_lifecycle
			RuntimeGuard.call("process lifecycle tick", function() owner.tick(tick_count) end, function()
				if type(owner.stop) == "function" then owner.stop() end
				process_lifecycle = nil
			end)
		end
		-- A raw Tab/click invalidates synchronously on the input path. Only this
		-- periodic path may run the blocking accessibility probe, after its shared
		-- focus-settle deadline. Unknown and probe failure stay fail-closed.
		secure_focus_guard.refresh(false)
		if file_watchers then
			local owner = file_watchers
			RuntimeGuard.call("file watcher pump", owner.pump, function()
				if type(owner.stop) == "function" then owner.stop() end
				file_watchers = nil
			end)
		end
		-- One bounded batch per tick, and only while a migration is in flight.
		-- Deliberately NOT on the idle callback: that one runs between keystrokes,
		-- and a batch costs one openssl spawn per value.
		RuntimeGuard.call("keylogger migration pump", keylogger.pump_migration)

		-- Persist. Until now the ONLY two flush() call sites were the SIGTERM
		-- handler and the clean exit after the loop returns — so a SIGKILL, an OOM
		-- kill, a power loss or an X crash discarded the entire session's metrics,
		-- and a session spanning midnight was stamped end to end with the shutdown
		-- date because both the date and the timestamp are computed at flush time.
		--
		-- The cadence is the cross-driver one: _shared/modules/timings/constants
		-- .toml [keylogger] ingest_tick_ms, which Windows already uses as its
		-- INGEST_TICK_MS and macOS as INGEST_TICK_SEC. Counted in ticks rather than
		-- measured against a clock, because the periodic callback's own period is
		-- the only interval this loop can be sure of.
		if tick_count % FLUSH_EVERY_TICKS == 0 then
			RuntimeGuard.call("keylogger periodic flush", keylogger.flush)
		end

		-- The machine's own state. The sampler decides for itself whether enough
		-- time has passed, so calling it every tick costs a comparison — putting
		-- the interval here as well would be a second place to change it.
		if system_metrics then
			local owner = system_metrics
			RuntimeGuard.call("system metrics sampler", function()
				owner.sample(math.floor(Monotonic.now_ms()), os.date("%Y-%m-%d"))
			end, function() system_metrics = nil end)
		end

		-- The WPM widget's only clock. `ui/wpm/widget.lua` was complete — it
		-- computes the frame, picks the colour from the keystroke source, throttles
		-- redraws to what a user could actually see — and `tick` had no caller
		-- anywhere in the driver, so the whole surface was inert on every desktop.
		-- The same shape the preview bubble had.
		--
		-- Driven from here rather than from its own timer: a widget with a private
		-- clock is a second thing to stop on shutdown and a second thing to leak.
		if wpm_widget then
			local owner = wpm_widget
			RuntimeGuard.call("WPM widget tick", function()
				wpm_widget.tick(keylogger.get_session_stats(), tick_count * PERIODIC_TICK_MS / 1000)
			end, function()
				if type(owner.stop) == "function" then owner.stop() end
				wpm_widget = nil
			end)
		end
	end

	event_loop.run({
		onIdle = function()
			if not keyboard_hook.isRunning() then
				shutdown.request("keyboard hook stopped")
				return
			end
			if tray_menu then
				local owner = tray_menu
				RuntimeGuard.call("tray pump", owner.pump, function()
					if type(owner.destroy) == "function" then owner.destroy() end
					tray_menu = nil
				end)
			end
			if not RuntimeGuard.call("keyboard pump", keyboard_hook.pump, stop_input_loop) then return end
			-- The touchpad, on the same tick as the keyboard. Cheap when nothing is
			-- reading: gestures.pump() returns 0 immediately unless start_reading()
			-- found a device and opened it, so a machine without a touchpad pays a
			-- function call per tick and nothing else.
			if gestures and type(gestures.pump) == "function" then
				local owner = gestures
				RuntimeGuard.call("gesture pump", owner.pump, function()
					if type(owner.stop_reading) == "function" then owner.stop_reading() end
					gestures = nil
				end)
			end
		end,
		onPeriodic = on_periodic,
		periodSec = 0.25,
	})

	-- 8.14) Clean exit.
	-- Also covers an event-loop backend that returned on its own: every owner is
	-- quiesced before any final resource is destroyed, and duplicate requests are
	-- harmless.
	shutdown.request("event loop returned")
	if tooltip_preview then tooltip_preview.destroy() end
	if llm_overlay then llm_overlay.hide() end
	injector.close_fast_channel()
	if file_watchers then file_watchers.stop() end
	if process_lifecycle then process_lifecycle.stop() end
	if tray_menu then tray_menu.destroy() end

	local stats = keylogger.get_session_stats()
	Logger.info(LOG, "Session ended: %d keystroke(s), ~%d word(s), %ds.",
		stats.keystrokes, stats.words, math.floor(stats.duration_ms / 1000))
	keylogger.flush()
	Logger.info(LOG, "Daemon exiting.")
end

-- The daemon runs under the crash reporter, which until now had no caller at
-- all: modules/diagnostics/crash_reporter.lua was written, tested, and reachable
-- only from its own test file. A driver that runs for weeks in the background
-- and dies at 3 a.m. leaves the user with a tray icon that is simply gone and
-- nothing on disk saying why — the log's last line is whatever it was doing, not
-- what killed it.
--
-- protect() rather than a bare xpcall here, so the traceback, the log line and
-- the crash file all come from one place. It captures the stack inside the
-- message handler, before the unwind.
local ok_main, err_main = CrashReporter.protect("ergopti_hotstrings", main)
if not ok_main then
	Logger.error(LOG, "Daemon terminated by an unhandled error: %s", tostring(err_main))
	-- Non-zero, so systemd sees a failure and its Restart= policy applies. A daemon
	-- that crashes and exits 0 is a daemon the supervisor believes finished its work.
	os.exit(1)
end
