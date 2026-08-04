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
---   --verbose          Enable debug-level logging.
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
local dev_finder        = require("modules.hotstrings.device_finder")
local keylogger         = require("modules.keylogger.keylogger")
local keyboard_hook     = require("adapters.keyboard_hook")
local Monotonic         = require("infra.monotonic")
local ManifestReader    = require("infra.manifest_reader")

-- Optional adapters (may fail to load if deps missing — daemon still runs).
local tray_menu = nil
local ok_tray, tray_mod = pcall(require, "adapters.tray_menu")
if ok_tray then tray_menu = tray_mod end

-- Event loop adapter (luv when available, pump fallback otherwise).
local event_loop = require("adapters.event_loop")

-- Menu builder (builds rich submenus from daemon state).
local menu_builder = nil
local ok_menu, menu_mod = pcall(require, "ui.menu.menu_builder")
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
local ok_wm, wm_mod = pcall(require, "ui.webview_manager")
if ok_wm then webview_manager = wm_mod end

-- Kanata manager (optional — key remapping daemon lifecycle).
-- Handles .kbd generation and kanata process start/stop/restart.
local kanata = nil
local ok_kan, kan_mod = pcall(require, "platform.remap.manager")
if ok_kan then kanata = kan_mod end

-- File watchers (optional — inotify-based TOML/.lua hot reload).
-- When luv is present, uses native inotify via luv.new_fs_event();
-- otherwise falls back to mtime polling driven by the event loop.
local file_watchers = nil
local ok_fw, fw_mod = pcall(require, "infra.file_watchers")
if ok_fw then file_watchers = fw_mod end


-- =========================================
-- =========================================
-- ======= 4/ Constants ====================
-- =========================================
-- =========================================

-- Default hotstring data location (XDG-compliant user config).
local DEFAULT_CONFIG_DIR = require("infra.config_paths").config("hotstrings")

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
	print("  --verbose           Enable debug messages.")
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
		local stats = keylogger.get_session_stats()
		Logger.info(LOG, "Session: %d keystroke(s), ~%d word(s), %ds.",
			stats.keystrokes, stats.words, math.floor(stats.duration_ms / 1000))
		keylogger.flush()
		keyboard_hook.stop()
		-- After the hook, never before: closing the channel destroys the uinput
		-- device, and the hook's ungrab may still have keys to put back through it.
		injector.close_fast_channel()
		if tray_menu then tray_menu.destroy() end
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
		-- `terminator_consumed` stays separate: it is the caller's statement that
		-- the terminator should also be erased on the AUTO path. On the end-char
		-- path the engine sets it itself, because the terminator necessarily sits
		-- between the trigger and the caret there.
		local is_terminator = terminators_mod.is_terminator(ch)
		local result = engine:on_char(ch, {
			is_terminator       = is_terminator,
			terminator_consumed = is_terminator,
		})

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
				-- Armed AFTER the injection, so a failed one leaves nothing to undo.
				_undoable = {
					trigger     = result.trigger,
					replacement = result.replacement,
				}
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
			-- final_result means "this expansion is the end of it": drop the
			-- buffer so nothing can chain off the replacement. Otherwise keep the
			-- expanded text in the buffer, which is what Windows and macOS do —
			-- resetting unconditionally is why Linux could never chain, and made
			-- final_result unobservable here.
			if result.final_result then
				engine:reset()
			else
				engine:apply_expansion(result)
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
		local ok_lb, lb = pcall(require, "infra.llm_bridge")
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
		-- The magic key is declared once, in the shared feature manifest, and every
		-- driver reads it from there. Linux used to hardcode a backslash while the
		-- manifest, both other drivers, the shared engine and the onboarding page
		-- all say "★" — so the @-tag expansions were the only feature in the
		-- product listening for a different key, and the personal-info editor told
		-- the user so.
		dyn_hotstrings.init({
			trigger_char = ManifestReader.default_for("hotstrings.trigger_char"),
		})
		Logger.info(LOG, "Dynamic hotstrings initialised (%d rule(s)).",
			dyn_hotstrings.get_rules_count())
	end

	-- 8.7) Define the control-key callback.
	local function on_control(key_name)
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

	-- 8.7b) A pointer click moves the caret.
	--
	-- Every character in the buffer describes text at a position the user has
	-- just left, so an expansion after a click would fire against a line that is
	-- no longer under the cursor — and erase characters belonging to whatever is
	-- there now. The pointer is watched, never grabbed.
	local function on_click()
		_undoable = nil
		engine:reset()
		Logger.debug(LOG, "Pointer click — buffer reset.")
	end

	-- 8.7b) Restore the word-delimiter choices.
	--
	-- The shared catalogue keeps them in memory only, so every delimiter the user
	-- switched off came back on at the next start — and the feature exists
	-- precisely so a user can say "expand on ★ and nothing else". A setting that
	-- forgets itself is worse than one that is missing.
	local TERMINATORS_KEY = "hotstrings.disabled_terminators"
	local function persist_terminators()
		if not terminators_mod or type(terminators_mod.get_terminator_defs) ~= "function" then return end
		local off = {}
		for _, def in ipairs(terminators_mod.get_terminator_defs() or {}) do
			if def.key and not terminators_mod.is_terminator_enabled(def.key) then
				off[#off + 1] = def.key
			end
		end
		table.sort(off)
		local ok_storage, Storage = pcall(require, "adapters.storage")
		if ok_storage then Storage.set(TERMINATORS_KEY, table.concat(off, ",")) end
	end

	local function restore_terminators()
		if not terminators_mod or type(terminators_mod.set_terminator_enabled) ~= "function" then return end
		local ok_storage, Storage = pcall(require, "adapters.storage")
		if not ok_storage then return end
		local raw = Storage.get(TERMINATORS_KEY, "")
		if type(raw) ~= "string" or raw == "" then return end
		local count = 0
		for key in raw:gmatch("[^,]+") do
			terminators_mod.set_terminator_enabled(key, false)
			count = count + 1
		end
		Logger.info(LOG, "Restored %d disabled word delimiter(s).", count)
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

	keyboard_hook.start({
		device = device,
		layout = opts.layout,
		intercept  = opts.grab,
		onChar  = on_char,
		onKey   = on_control,
		onClick = on_click,
		onPhysical = on_physical,
		onEmitRaw  = injector.emit_key,
	})
	Logger.info(LOG, "Keyboard hook started in %s mode.",
		opts.grab and "INTERCEPT (device grabbed)" or "OBSERVE (--no-grab)")

	if not keyboard_hook.isRunning() then
		Logger.error(LOG, "Keyboard hook failed to start — exiting.")
		print("Error: could not start the keyboard hook.")
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
			on_menu_changed = function()
				persist_terminators()
				if rebuild_tray_menu then rebuild_tray_menu() end
			end,
			-- Adding a delimiter needs a text field, and this driver's only text
			-- field is the settings window. Opening it is honest; a native prompt
			-- would mean a second dialog toolkit for one input.
			on_add_delimiter = function()
				if type(webview_manager) == "table" and type(webview_manager.show) == "function" then
					webview_manager.show("hotstrings_config")
				else
					Logger.warn(LOG, "No settings window available — a custom delimiter cannot be added.")
				end
			end,
			on_open_file = function(path)
				if type(path) ~= "string" or path == "" then return end
				Logger.info(LOG, "Opening hotstring file: %s", path)
				os.execute(string.format("xdg-open '%s' 2>/dev/null &", path:gsub("'", "'\''")))
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
				if Logger.set_level then
					Logger.set_level(lvl)
				end
				Logger.info(LOG, "Log level set to %s.", lvl)
			end,
			}
		end

		rebuild_tray_menu = function()
			local ok_build, items = pcall(menu_builder.build, _build_menu_ctx())
			if not ok_build then
				Logger.error(LOG, "Menu rebuild failed — %s", tostring(items))
				return
			end
			tray_menu.setMenu(items)
		end
		rebuild_tray_menu()
		else
			tray_menu.setMenu({
				{ title = "Ergopti " .. (opts.layout or "qwerty"), fn = function() end },
				{ title = "Quitter", fn = function() keyboard_hook.stop() end },
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

	-- 8.10a) Initialise i18n (loads persisted locale, enables ★ substitution).
	local ok_i18n, i18n_mod = pcall(require, "infra.i18n")
	if ok_i18n and i18n_mod then
		i18n_mod.init()
		-- From the manifest, like every other reader of this value. This was the
		-- last hardcoded backslash: the i18n layer substitutes the magic key into
		-- every localised label that mentions it, so a driver that answered "\"
		-- here printed the wrong key in 21 languages while the engine listened for
		-- ★ — a menu that documented a keystroke nothing responded to.
		i18n_mod.set_trigger_provider(function()
			return ManifestReader.default_for("hotstrings.trigger_char")
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
		-- Here rather than in onIdle: it re-reads /proc/bus/input/devices, which
		-- has no business on the keystroke path. A keyboard unplugged and plugged
		-- back in gets a new eventN node, and restarting the remap daemon
		-- recreates the device this one prefers — neither announces itself on the
		-- descriptor already held.
		pcall(keyboard_hook.check_device)
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

main()
