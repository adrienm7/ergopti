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

-- Optional adapters (may fail to load if deps missing — daemon still runs).
local tray_menu = nil
local ok_tray, tray_mod = pcall(require, "adapters.tray_menu")
if ok_tray then tray_menu = tray_mod end

-- Menu builder (builds rich submenus from daemon state).
local menu_builder = nil
local ok_menu, menu_mod = pcall(require, "modules.menu.menu_builder")
if ok_menu then menu_builder = menu_mod end

-- LLM prediction engine (optional — daemon runs without it).
local prediction_engine = nil
local ok_llm, llm_mod = pcall(require, "modules.llm.prediction_engine")
if ok_llm then prediction_engine = llm_mod end

-- Window info tracker (optional — provides app_id for keylogger per-app stats).
local window_info = nil
local ok_wi, wi_mod = pcall(require, "adapters.window_info")
if ok_wi then window_info = wi_mod end


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

	-- 8.5) Define the character callback.
	local function on_char(ch)
		local now_ms = math.floor(os.clock() * 1000)

		-- Detect current app for per-app keylogger stats.
		local app_id = nil
		if window_info and window_info.getActiveAppID then
			app_id = window_info.getActiveAppID()
		end

		-- Check password suppression.
		if keylogger.is_password_app(app_id) then
			keylogger.suppress()
		else
			keylogger.unsuppress()
		end

		keylogger.on_keydown(ch, now_ms, app_id)

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
				injector.inject(result.backspace_count, result.replacement)
			end
			engine:reset()
		end

		-- Feed the character to the LLM prediction engine.
		if prediction_engine then
			pcall(function() prediction_engine.on_char(ch) end)
		end
	end

	-- 8.6) Initialise the LLM prediction engine if available.
	if prediction_engine then
		prediction_engine.init({
			engine        = engine,
			keyboard_hook = keyboard_hook,
			triggers      = { "//", ";;", "--" },
			max_context   = 2000,
			auto_inject   = true,
		})
		Logger.info(LOG, "LLM prediction engine initialised.")
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
	keyboard_hook.start({
		device = device,
		layout = opts.layout,
		onChar  = on_char,
		onKey   = on_control,
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
			local menu_items = menu_builder.build({
				_version      = Version.VERSION,
				config        = hotstrings_config,
				engine        = engine,
				layout        = opts.layout,
				on_layout_change = function(new_layout)
					Logger.info(LOG, "Layout change requested: %s (restart daemon to apply)", new_layout)
				end,
				keylogger     = keylogger,
				llm           = prediction_engine,
				dry_run       = opts.dry_run,
				verbose       = opts.verbose,
				on_quit       = function() keyboard_hook.stop() end,
			})
			tray_menu.setMenu(menu_items)
		else
			tray_menu.setMenu({
				{ title = "Ergopti " .. (opts.layout or "qwerty"), fn = function() end },
				{ title = "Quitter", fn = function() keyboard_hook.stop() end },
			})
		end
	elseif opts.tray and not tray_menu then
		Logger.warn(LOG, "Tray icon requested but tray_menu adapter unavailable (install yad).")
	end

	-- 8.10) Install signal handlers.
	install_signal_handlers()

	Logger.success(LOG, "Daemon ready (device=%s layout=%s mappings=%d dry_run=%s tray=%s).",
		device, opts.layout, mapping_count, tostring(opts.dry_run), tostring(opts.tray and tray_menu ~= nil))

	-- 8.11) Pump-based event loop.
	while keyboard_hook.isRunning() do
		if tray_menu then
			pcall(tray_menu.pump)
		end
		pcall(keyboard_hook.pump)
	end

	-- 8.12) Clean exit.
	if tray_menu then tray_menu.destroy() end

	local stats = keylogger.get_session_stats()
	Logger.info(LOG, "Session ended: %d keystroke(s), ~%d word(s), %ds.",
		stats.keystrokes, stats.words, math.floor(stats.duration_ms / 1000))
	keylogger.flush()
	Logger.info(LOG, "Daemon exiting.")
end

main()
