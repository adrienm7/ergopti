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
local LOG = "ergopti_hotstrings"


-- =========================================
-- =========================================
-- ======= 3/ Imports ======================
-- =========================================
-- =========================================

local engine_mod    = require("modules.hotstrings.engine")
local loader        = require("modules.hotstrings.loader")
local injector      = require("modules.hotstrings.injector")
local dev_finder    = require("modules.hotstrings.device_finder")
local metrics       = require("modules.keylogger.metrics_collector")
local keyboard_hook = require("adapters.keyboard_hook")	-- Optional adapters (may fail to load if deps missing — daemon still runs).
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

local function resolve_toml_paths(config_path)
	local root = config_path
	if not root then
		local fh = io.open(DEFAULT_CONFIG_DIR, "r")
		if fh then
			fh:close()
			root = DEFAULT_CONFIG_DIR
		end
	end
	if not root then
		local shared = SCRIPT_DIR .. "/../../_shared/modules/hotstrings"
		local fh = io.open(shared, "r")
		if fh then
			fh:close()
			root = shared
		end
	end
	if not root then
		Logger.warn(LOG, "No hotstring data directory found — no mappings loaded.")
		return {}
	end
	if root:match("%.toml$") then
		return { root }
	end
	return loader.find_toml_files(root)
end


-- =========================================
-- =========================================
-- ======= 7/ Signal Handler Setup =========
-- =========================================
-- =========================================

local function install_signal_handlers()
	local ok, signal = pcall(require, "posix.signal")
	if not ok or not signal then
		Logger.debug(LOG, "posix.signal unavailable — SIGINT/SIGTERM not intercepted.")
		return
	end

	local function on_signal(sig)
		Logger.info(LOG, "Signal %d received — shutting down…", sig)
		local stats = metrics.get_session_stats()
		Logger.info(LOG, "Session: %d keystroke(s), ~%d word(s), %ds.",
			stats.keystrokes, stats.words, math.floor(stats.duration_ms / 1000))
		keyboard_hook.stop()
		if tray_menu then tray_menu.destroy() end
	end

	pcall(signal.signal, signal.SIGINT,  on_signal)
	pcall(signal.signal, signal.SIGTERM, on_signal)
	Logger.debug(LOG, "Signal handlers installed.")
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

	-- 8.1) Load hotstring mappings.
	local toml_paths = resolve_toml_paths(opts.config)
	Logger.info(LOG, "%d TOML file(s) to load.", #toml_paths)
	local mappings = loader.load(toml_paths)

	-- 8.2) Initialise the engine and feed it the mappings.
	local engine = engine_mod.new()
	engine:load_mappings(mappings)

	-- 8.3) Initialise the metrics collector.
	metrics.init({})

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
		metrics.on_keydown(ch, now_ms)

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
			-- The engine buffer is internal — we pass the character and let
			-- prediction_engine track its own context buffer.
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

	-- 8.7) Start the keyboard hook adapter (pump-based, non-blocking start).
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

	-- 8.8) Start the tray menu if requested and available.
	if opts.tray and tray_menu then
		Logger.info(LOG, "Tray icon requested — starting.")
		tray_menu.setIcon({ title = "Ergopti" })

		if menu_builder then
			-- Build the full rich menu from daemon state.
			local menu_items = menu_builder.build({
				_version  = "3.0.0",
				engine    = engine,
				mappings  = mappings,
				layout    = opts.layout,
				on_layout_change = function(new_layout)
					Logger.info(LOG, "Layout change requested: %s (restart daemon to apply)", new_layout)
				end,
				metrics   = metrics,
				llm       = prediction_engine,
				dry_run   = opts.dry_run,
				verbose   = opts.verbose,
				on_quit   = function() keyboard_hook.stop() end,
			})
			tray_menu.setMenu(menu_items)
		else
			-- Fallback: minimal menu.
			tray_menu.setMenu({
				{ title = "Ergopti " .. (opts.layout or "qwerty"), fn = function() end },
				{ title = "Quitter", fn = function() keyboard_hook.stop() end },
			})
		end
	elseif opts.tray and not tray_menu then
		Logger.warn(LOG, "Tray icon requested but tray_menu adapter unavailable (install yad).")
	end

	-- 8.9) Install signal handlers (calls keyboard_hook.stop + tray_menu.destroy).
	install_signal_handlers()

	Logger.success(LOG, "Daemon ready (device=%s layout=%s mappings=%d dry_run=%s tray=%s).",
		device, opts.layout, #mappings, tostring(opts.dry_run), tostring(opts.tray and tray_menu ~= nil))

	-- 8.10) Pump-based event loop.
	-- keyboard_hook.pump() blocks on pipe:read("*l") until input arrives.
	-- tray_menu.pump() processes signal-file callbacks (fast, non-blocking).
	-- Run tray_menu.pump() BEFORE keyboard_hook.pump() so menu clicks are
	-- serviced between keystrokes.
	while keyboard_hook.isRunning() do
		if tray_menu then
			pcall(tray_menu.pump)
		end
		pcall(keyboard_hook.pump)
	end

	-- 8.11) Clean exit.
	if tray_menu then tray_menu.destroy() end

	local stats = metrics.get_session_stats()
	Logger.info(LOG, "Session ended: %d keystroke(s), ~%d word(s), %ds.",
		stats.keystrokes, stats.words, math.floor(stats.duration_ms / 1000))
	Logger.info(LOG, "Daemon exiting.")
end

main()
