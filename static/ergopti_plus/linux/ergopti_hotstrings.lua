--- static/ergopti_plus/linux/ergopti_hotstrings.lua

--- ==============================================================================
--- MODULE: Ergopti Hotstrings Daemon (Linux)
--- DESCRIPTION:
--- Entry point for the Linux hotstring daemon. Reads keyboard events from an
--- evdev device, matches the rolling typing buffer against loaded hotstring
--- definitions, and replays expansions via ydotool (uinput). The daemon is
--- entirely self-contained and runs outside of any display server dependency.
---
--- USAGE:
---   luajit ergopti_hotstrings.lua [OPTIONS]
---
---   --config  <path>   Path to a TOML config file or directory containing
---                       TOML hotstring files. Defaults to
---                       ~/.config/ergopti/hotstrings/ if that directory exists,
---                       then falls back to the shared/hotstrings/ tree shipped
---                       alongside the script.
---   --device  <path>   Evdev device to listen on (e.g. /dev/input/event3).
---                       When omitted, device_finder auto-selects the keyboard.
---   --layout  <name>   Keyboard layout for keycode mapping: "qwerty" or
---                       "azerty". Default: auto-detect from $XKBLAYOUT env var.
---   --dry-run          Log matches without injecting any keystrokes.
---   --verbose          Enable debug-level logging.
---   --help             Print usage and exit.
---
--- FEATURES & RATIONALE:
--- 1. Zero-config startup: auto-detection of both the hotstring data directory
---    and the keyboard device means the daemon works out of the box on a
---    standard ergopti installation.
--- 2. Modular architecture: each concern (loading, matching, injection, input,
---    metrics) lives in its own module so individual pieces can be unit-tested
---    or swapped without touching this file.
--- 3. Buffer reset on control keys: Backspace, Enter, and Tab clear the engine
---    buffer so stale prefixes from incomplete words never trigger expansions
---    unexpectedly.
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
-- Must be done before any require() so logger.shim and keymap.terminators resolve.
local SHARED_LUA_DIR = SCRIPT_DIR .. "/../shared/lua"
package.path = SCRIPT_DIR .. "/?.lua;" ..
               SCRIPT_DIR .. "/modules/hotstrings/?.lua;" ..
               SHARED_LUA_DIR .. "/?.lua;" ..
               SHARED_LUA_DIR .. "/?/init.lua;" ..
               package.path


-- =========================================
-- =========================================
-- ======= 2/ Logger =======================
-- =========================================
-- =========================================

-- Use the canonical shared logger shim. It tries the shared logger core and
-- the macOS driver logger before falling back to plain print.
local Logger = require("logger.shim")

local LOG = "ergopti_hotstrings"


-- =========================================
-- =========================================
-- ======= 3/ Imports ======================
-- =========================================
-- =========================================

local engine_mod  = require("modules.hotstrings.engine")
local loader      = require("modules.hotstrings.loader")
local injector    = require("modules.hotstrings.injector")
local input_mod   = require("modules.hotstrings.input_reader")
local dev_finder  = require("modules.hotstrings.device_finder")
local metrics     = require("modules.keylogger.metrics_collector")


-- =========================================
-- =========================================
-- ======= 4/ Constants ====================
-- =========================================
-- =========================================

-- Default hotstring data location (XDG-compliant user config).
local DEFAULT_CONFIG_DIR = (os.getenv("HOME") or "~") .. "/.config/ergopti/hotstrings"

-- Terminator catalogue: loaded from the shared module so Linux and macOS
-- recognise exactly the same set of terminator characters. The shared module
-- owns the single source of truth (TERMINATOR_DEFS) and exposes is_terminator()
-- as an O(1) lookup against its pre-built hash set.
local terminators_mod = (function()
	local ok, mod = pcall(require, "keymap.terminators")
	if ok and mod then return mod end
	-- Graceful fallback: if the shared module is absent (e.g. stripped install),
	-- fall back to the minimal set to avoid a hard crash.
	Logger.warn(LOG, "shared keymap.terminators not found — falling back to minimal terminator set.")
	local _fallback = { [" "] = true, ["."] = true, [","] = true, ["\n"] = true }
	return { is_terminator = function(ch) return _fallback[ch] == true end }
end)()


-- =========================================
-- =========================================
-- ======= 5/ CLI Argument Parser ==========
-- =========================================
-- =========================================

--- Parses the command-line argument list (arg global) into an options table.
--- @return table  { config?, device?, layout?, dry_run, verbose, help }
local function parse_args()
	-- Auto-detect layout from $XKBLAYOUT env var; default to qwerty.
	local default_layout = (os.getenv("XKBLAYOUT") or ""):lower()
	if default_layout ~= "azerty" then default_layout = "qwerty" end

	local opts = {
		layout  = default_layout,
		dry_run = false,
		verbose = false,
		help    = false,
	}
	local i = 1
	while i <= #arg do
		local a = arg[i]
		if     a == "--help"    or a == "-h"  then opts.help    = true
		elseif a == "--dry-run"               then opts.dry_run = true
		elseif a == "--verbose" or a == "-v"  then opts.verbose = true
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

--- Prints usage information to stdout (French UI text).
local function print_usage()
	print("Utilisation : luajit ergopti_hotstrings.lua [OPTIONS]")
	print("")
	print("  --config <chemin>   Fichier TOML ou répertoire de définitions.")
	print("                      Défaut : ~/.config/ergopti/hotstrings/")
	print("  --device <chemin>   Périphérique evdev (ex. /dev/input/event3).")
	print("                      Défaut : détection automatique.")
	print("  --layout <nom>      Disposition clavier : qwerty | azerty.")
	print("                      Défaut : variable $XKBLAYOUT, sinon qwerty.")
	print("  --dry-run           Journalise les correspondances sans injecter.")
	print("  --verbose           Active les messages de débogage.")
	print("  --help              Afficher ce message.")
end


-- =========================================
-- =========================================
-- ======= 6/ Config Resolution ============
-- =========================================
-- =========================================

--- Resolves the list of TOML files to load from opts.config or the default
--- directory tree. Returns an empty table if nothing is found.
--- @param config_path string|nil  Value of --config, or nil.
--- @return table  Array of absolute .toml file paths.
local function resolve_toml_paths(config_path)
	local root = config_path

	-- Fall back to ~/.config/ergopti/hotstrings/ if it exists.
	if not root then
		local fh = io.open(DEFAULT_CONFIG_DIR, "r")
		if fh then
			fh:close()
			root = DEFAULT_CONFIG_DIR
		end
	end

	-- Last resort: the shared/hotstrings/ tree co-located with the script.
	if not root then
		local shared = SCRIPT_DIR .. "/../../shared/hotstrings"
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

	-- If root is a single .toml file, wrap it in an array.
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

--- Installs SIGINT / SIGTERM handlers that flush metrics and close the reader.
--- LuaJIT on Linux does not expose posix.signal directly; we use a pcall-guarded
--- attempt with the luaposix library and silently skip if it is absent.
--- @param reader table  The input_reader instance (has a :stop() method).
local function install_signal_handlers(reader)
	local ok, signal = pcall(require, "posix.signal")
	if not ok or not signal then
		Logger.debug(LOG, "posix.signal unavailable — SIGINT/SIGTERM not intercepted.")
		return
	end

	local function on_signal(sig)
		Logger.info(LOG, "Signal %d received — shutting down…", sig)

		-- Log final session stats before exit.
		local stats = metrics.get_session_stats()
		Logger.info(LOG, "Session: %d keystroke(s), ~%d word(s), %ds.",
			stats.keystrokes, stats.words, math.floor(stats.duration_ms / 1000))

		reader:stop()
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

--- Entry point — called at the bottom of the script.
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

	-- 7.1) Load hotstring mappings.
	local toml_paths = resolve_toml_paths(opts.config)
	Logger.info(LOG, "%d TOML file(s) to load.", #toml_paths)

	local mappings = loader.load(toml_paths)

	-- 7.2) Initialise the engine and feed it the mappings.
	local engine = engine_mod.new()
	engine:load_mappings(mappings)

	-- 7.3) Initialise the metrics collector.
	metrics.init({})

	-- 7.4) Resolve the input device.
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

	-- 7.5) Define the character callback.
	-- The buffer is updated on every character; matches are attempted on every
	-- keypress. When a terminator is typed it is passed too (appearing at the
	-- tail of the buffer) and terminator_consumed is set to true so the engine
	-- adds 1 to the backspace count.
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
			-- After injection the buffer state is stale; reset it.
			engine:reset()
		end
	end

	-- 7.6) Define the control-key callback (resets the buffer on structural keys).
	local function on_control(key_name)
		-- Backspace, Enter, and Tab all break word context.
		engine:reset()
		Logger.debug(LOG, "Control key '%s' — buffer reset.", key_name)
	end

	-- 7.7) Create the input reader and install signal handlers.
	local reader = input_mod.new(device, opts.layout, on_char, on_control)
	install_signal_handlers(reader)

	Logger.success(LOG, "Daemon ready (device=%s layout=%s mappings=%d dry_run=%s).",
		device, opts.layout, #mappings, tostring(opts.dry_run))

	-- Blocking call — returns only when the device is closed or an error occurs.
	reader:start()

	-- Final metrics summary on clean exit.
	local stats = metrics.get_session_stats()
	Logger.info(LOG, "Session ended: %d keystroke(s), ~%d word(s), %ds.",
		stats.keystrokes, stats.words, math.floor(stats.duration_ms / 1000))

	Logger.info(LOG, "Daemon exiting.")
end

main()
