--- init.lua

--- ==============================================================================
--- MODULE: Application Entry Point
--- DESCRIPTION:
--- Loads all modules, discovers TOML hotstring files, then hands off to the
--- menubar UI and file watchers.
---
--- FEATURES & RATIONALE:
--- 1. Orchestration: Bootstraps the environment in a safe, predictable order.
--- 2. File Discovery: Dynamically loads private and public configuration files.
--- ==============================================================================

-- Inject the _shared/lua root into package.path so that lib/ shims for
-- toml_codec, toml_reader, and toml_writer can resolve their shared modules.
-- This must run before any require() that pulls in those libs.
do
	local _src = debug.getinfo(1, "S").source:gsub("^@", "")
	-- Resolve absolute path when source is relative (Hammerspoon always provides abs)
	local _abs = _src:match("^[/\\]") and _src or (hs.fs and hs.fs.currentDir and hs.fs.currentDir() .. "/" .. _src or _src)
	-- Strip "init.lua" to get the HS driver root
	local _hs_root = _abs:match("^(.*)[/\\][^/\\]+$") or _abs
	-- _shared/ lives one level up from the HS driver root (in ergopti_plus/)
	local _ergopti_plus = _hs_root:match("^(.*)[/\\][^/\\]+$") or _hs_root
	local _shared       = _ergopti_plus .. "/_shared/lua"
	if not package.path:find(_shared, 1, true) then
		package.path = _shared .. "/?.lua;" .. _shared .. "/?/init.lua;" .. package.path
	end

	-- Inject a custom searcher for the bundled touchdevice API so it can be loaded
	-- as its original module name ("hs._asm.undocumented.touchdevice") without
	-- needing to map exact folder structures into package.path / package.cpath.
	local searchers = package.searchers or package.loaders
	if searchers then
		table.insert(searchers, 2, function(modname)
			if type(modname) == "string" and modname:match("^hs%._asm%.undocumented%.touchdevice") then
				local sub = modname:match("^hs%._asm%.undocumented%.touchdevice%.(.+)$")
				local base = _hs_root .. "/vendor/hs_asm/undocumented/touchdevice/"
				if not sub then
					return loadfile(base .. "init.lua")
				else
					local so_path = base .. sub .. ".so"
					local func_name = "luaopen_" .. modname:gsub("%.", "_")
					local f = package.loadlib(so_path, func_name)
					if f then return f end
					-- Fallback symbol name if compiled differently
					local f2 = package.loadlib(so_path, "luaopen_hs__asm_undocumented_touchdevice_" .. sub)
					if f2 then return f2 end
					return "\n\tno file '" .. so_path .. "' (custom searcher)"
				end
			end
		end)
	end
end





-- ===============================
-- ================================
-- ======= 0/ Logger Setup =======
-- ================================
-- ===============================

-- Must run BEFORE any require() to suppress "Enabled hotkey ⌃X" spam at startup
-- hs.hotkey hardcodes its logger level to "debug" via hs.logger.new("hotkey", "debug"),
-- so defaultLogLevel/setGlobalLogLevel have no effect
-- We intercept hs.logger.new() to force "warning" for known noisy internal modules before they are loaded
-- Uncomment the guard below to restore full hs.* logging when debugging Hammerspoon internals
do
	local _orig_new = hs.logger.new
	hs.logger.new = function(id, level, ...)
		if id == "hotkey" or id == "window.filter" then level = "warning" end
		return _orig_new(id, level, ...)
	end
end

local Logger             = require("lib.logger")
local LOG                = "init"
local HS_BOOT_READY_SETTING_KEY = "ergopti_hs_boot_ready_v1"

-- Guard setting consumed by KE lifecycle notifications. It is set to false at
-- boot start and flipped to true only once init has fully completed.
pcall(function()
	hs.settings.set(HS_BOOT_READY_SETTING_KEY, false)
end)

-- Restore persisted log level from settings, or default to DEBUG
do
	local saved_level = pcall(function() return hs.settings.get("ergopti.log_level") end)
	       and hs.settings.get("ergopti.log_level")
	local valid = { DEBUG = true, INFO = true, WARNING = true, ERROR = true }
	if type(saved_level) == "string" and valid[saved_level] then
		Logger.set_level(saved_level)
	else
		Logger.set_level("DEBUG")  -- Default: show all logs
	end
end

-- Global user-notification logging bridge.
-- Any module using hs.notify.new() will now be traced in Logger.info.
do
	if hs.notify and type(hs.notify.new) == "function" and hs.notify.__ergopti_info_wrapped ~= true then
		local _orig_notify_new = hs.notify.new
		hs.notify.new = function(opts, ...)
			if type(opts) == "table" then
				local t = tostring(opts.title or "")
				local b = tostring(opts.informativeText or "")
				if t ~= "" or b ~= "" then
					local payload = (t ~= "" and t or "(sans titre)") .. (b ~= "" and (" | " .. b) or "")
					Logger.info("notify", "Notification utilisateur: %s", payload)
				end
			end
			return _orig_notify_new(opts, ...)
		end
		hs.notify.__ergopti_info_wrapped = true
	end
end

-- Boot-phase profiler — ported from the AHK driver. Begin timing as early as the
-- logger is ready so every subsequent Boot.mark() reports its delta + running
-- total in the boot log, making a slow startup self-diagnosing (no profiler attach).
local Boot               = require("lib.boot_profiler")
Boot.begin()

local i18n               = require("lib.i18n")
local locale_mod         = require("lib.locale")
local crash_reporter     = require("lib.crash_reporter")
local reload_guard       = require("lib.reload_guard")

-- Tell a reload apart from a real quit. A fresh boot starts with the sentinel
-- cleared, then every controlled hs.reload() drops it again right before the VM
-- re-execs; the shutdown handler reads it to keep the Karabiner bridge alive
-- across reloads (a real quit, where no reload was marked, still tears it down).
reload_guard.clear()
do
	local _orig_reload = hs.reload
	hs.reload = function(...)
		pcall(reload_guard.mark_reload)
		return _orig_reload(...)
	end
end

-- Wire i18n → locale so set_locale() updates the JSON loader's active locale.
-- Must run before any menu builder calls i18n.get() or locale_mod.get().
i18n.set_locale_injector(function(code) locale_mod.set_locale(code) end)
i18n.init()

local menu_paths         = require("ui.menu.menu_paths")
local gestures           = require("modules.gestures")
local keymap             = require("modules.keymap")
-- Wire keymap → locale so trigger-character substitutions (★) use the live char.
locale_mod.set_trigger_provider(function() return keymap.get_trigger_char and keymap.get_trigger_char() or "★" end)
-- Expose keymap in the global table so the Hammerspoon console can call
-- keymap.perf_report_all() / perf_enable() / perf_reset() without
-- having to type out require("modules.keymap") each time.
_G.keymap = keymap
local shortcuts          = require("modules.shortcuts")
local dynamic_hotstrings = require("modules.dynamic_hotstrings")
Boot.mark("Core module requires")

-- ===================================
-- ===================================
-- ======= 2/ Path Resolution =======
-- ===================================
-- ===================================

-- Initialize the paths module EARLY (before karabiner/keylogger modules load)
-- so they can access the user-configured config_dir instead of using fallbacks
local script_path = debug.getinfo(1, "S").source
if script_path:sub(1, 1) == "@" then script_path = script_path:sub(2) end

local base_dir = script_path:match("^(.*[/\\])") or "./"
if not base_dir:match("[/\\]$") then base_dir = base_dir .. "/" end

menu_paths.init(base_dir, function() hs.timer.doAfter(0.25, function() pcall(hs.reload) end) end)
Boot.mark("Path: config dir + paths.toml (menu_paths.init)")

-- Re-point the logger to <config_dir>/logs/ErgoptiPlus_YYYY-MM-DD.log now that
-- the user config dir is known. Earlier boot lines went to the fallback file.
-- (The old-log retention purge is scheduled off the boot path inside this call.)
Logger.init_log_path(menu_paths.get_config_dir(), 14)
Boot.mark("Path: log file open (retention purge deferred)")

-- Make the file log self-sufficient: capture errors that Hammerspoon would
-- otherwise only print to its (unexportable, far-too-noisy) Console. Wraps
-- hs.timer callbacks so a throw inside one is logged with a traceback instead of
-- vanishing into the runloop (the failure mode that silently killed predictions
-- and the LLM boot sequence), and tees print() into the file. Installed right
-- after the log path is known so every capture lands in today's dated file.
Logger.install_runtime_error_capture()
Boot.mark("Path: runtime error capture installed")

-- TOML hotstring snapshot cache. The shared parser walks every source byte by
-- hand, which dominates the "Hotstring groups registered" boot phase; caching the
-- parsed result as a precompiled Lua chunk makes every boot with unchanged files
-- load ~10x faster. Wired here — before any keymap.load_toml — so the first boot
-- after a file change re-parses and refreshes the snapshot, every later boot reads
-- it, and the same-boot delay-reading pass also hits the snapshot. Kept in an
-- adapter so _shared/ stays filesystem-free (the reader sees only a load/store hook).
do
	local ok_cache, toml_cache = pcall(require, "adapters.toml_cache")
	if ok_cache and type(toml_cache) == "table" and type(toml_cache.init) == "function" then
		toml_cache.init((hs.configdir or ".") .. "/cache/toml_hotstrings")
		local ok_reader, toml_reader = pcall(require, "lib.toml_reader")
		if ok_reader and type(toml_reader) == "table" and type(toml_reader.set_cache_provider) == "function" then
			toml_reader.set_cache_provider(toml_cache)
		end
	else
		Logger.warn(LOG, "TOML hotstring cache adapter unavailable — falling back to full parsing.")
	end
end
Boot.mark("TOML hotstring cache wired")

-- Now safe to load modules that depend on config_dir
local file_system        = require("adapters.file_system")
local karabiner          = require("modules.karabiner")
local menu               = require("ui.menu")
local hotstring_editor   = require("ui.hotstring_editor")
local mlx_deps_checker    = require("modules.llm.mlx_deps_checker")
local ollama_deps_checker = require("modules.llm.ollama_deps_checker")
local backend_detector    = require("modules.llm.backend_detector")
local notifications       = require("lib.notifications")
local ui_restore         = require("lib.ui_restore")

-- Wire Logger.error → system notification so every ERROR surfaces to the user
-- without any module needing to call notifications.notify() directly.
-- Registered here (after notifications is loaded) to keep logger dependency-free.
Logger.set_error_notification_handler(function(module_name, message)
	pcall(notifications.notify, i18n.get("common.error_prefix") .. tostring(module_name), message, "error")
end)
Boot.mark("Config-dependent module requires")

-- Global uncaught-error handler: offer the user an opt-in crash report.
-- Hammerspoon surfaces unhandled errors via hs.crash.crashLog, but there is no
-- official OnError hook; we register a message watcher on the HS console to
-- catch errors bubbled up from coroutines and timers.
-- The simplest cross-version approach is to wrap the protected-call pattern in
-- every timer/callback, but we also expose a direct entry point here so any
-- module can call it after a pcall failure it cannot recover from.
_G.ergopti_report_crash = function(err, ctx)
	-- Surface a failure WITHIN the reporter loudly instead of swallowing it — a
	-- crash-while-reporting-a-crash used to vanish with no trace.
	local ok, perr = pcall(function()
		local report = crash_reporter.report(err, ctx)
		crash_reporter.prompt_user(report)
	end)
	if not ok then
		Logger.error(LOG, "Crash reporter itself failed: %s.", tostring(perr))
	end
end





-- ===================================
-- ====================================
-- ======= 1/ Module Pre-start =======
-- ====================================
-- ===================================

-- Pre-start modules so they are active before menu.lua reads saved prefs
-- Menu.lua will honor saved state and stop/start them as needed
Logger.debug(LOG, "Starting gestures module…")
gestures.start()
Logger.debug(LOG, "Starting shortcuts module…")
shortcuts.start()
Logger.info(LOG, "Main modules initialized successfully.")
Boot.mark("Gestures + shortcuts pre-start")

-- Fast-path LLM check: if LLM is explicitly disabled in hs.settings, skip the
-- synchronous MLX cleanup (lsof + curl) — its sole consumer is the warmup retry
-- loop which is also gated on LLM being enabled. When the setting is nil (user
-- has never set it), be conservative and run the cleanup so stale servers are
-- evicted regardless. This is a deliberately separate, quick gate; the full
-- boot_llm_enabled computation (including the saved-prefs / DEFAULT_STATE
-- fallback) runs later in Section 3. Named distinctly so the two never shadow
-- each other and the intent of each is unambiguous.
local mlx_cleanup_enabled = hs.settings.get("llm.enabled") ~= false

-- Hammerspoon does not always reap children on quit/reload, so a fresh boot can
-- find leftover mlx_lm.server processes from previous sessions. When SEVERAL still
-- listen on the same port, the kernel load-balances /v1/models between them via
-- SO_REUSEPORT, returns a different model ID each call, and breaks endpoint
-- discovery permanently — those MUST be nuked. But a SINGLE healthy survivor is
-- gold: its weights are already resident in GPU memory, so sparing it lets
-- start_server's cross-session adoption reuse it and the backend is ready in
-- seconds instead of a 45-90 s cold reload. Killing it unconditionally (the old
-- behaviour) is exactly what made every boot/reload pay a cold start.
--
-- The MLX port is the single source of truth from api_mlx (_shared/modules/llm/mlx_server.json).
-- Decision is spare-all-or-nuke-all: under SO_REUSEPORT the listening PID is
-- unreliable to single out (bash wrapper vs Python child — see api_mlx.lua), so we
-- never pick individual PIDs. Synchronous on purpose: the port state must settle
-- before the warmup retry loop fires its first probe.
if mlx_cleanup_enabled then
	require("modules.llm.boot_cleanup").run_selective_cleanup()
end -- if mlx_cleanup_enabled
Boot.mark("MLX server cleanup")

-- Background deps check for the active LLM backend. The detector picks
-- MLX on Apple Silicon (≥ macOS 13) and Ollama everywhere else; a
-- previously user-saved preference always wins. Both checkers are async
-- and silent on the fast path, so a normal reload stays invisible.





-- =======================================
-- ==========================================
-- ======= 3/ Config Loading & Setup =======
-- ==========================================
-- =======================================

-- Show the onboarding wizard on first launch (config.toml absent) and bail early —
-- the wizard writes the file and calls hs.reload(), so normal init must not proceed
do
	local ok_ob, onboarding_mod = pcall(require, "ui.onboarding")
	if ok_ob and type(onboarding_mod) == "table" then
		local cfg_path = menu_paths.get("ConfigTomlPath")
		if onboarding_mod.should_run(cfg_path) then
			onboarding_mod.run(cfg_path)
			return
		end
	end
end

-- Apply optional user overrides from hammerspoon/config.toml on top of
-- hs.settings. The [script] and [features] sections are an optional "expert"
-- layer the user can edit by hand to override anything the menu exposes
-- (LogLevel, individual feature flags). All overrides live in the
-- driver-specific config — no separate cross-driver config.toml.
local config_overrides = require("lib.config_overrides")
config_overrides.apply(menu_paths.get("ConfigTomlPath"))

local Preferences = require("ui.menu.preferences")
local ok_core_llm, core_llm = pcall(require, "modules.llm")
local boot_saved_prefs = Preferences.load(menu_paths.get("ConfigTomlPath"))
local boot_llm_enabled = hs.settings.get("llm.enabled")
if boot_llm_enabled == nil then
	if type(boot_saved_prefs.llm_enabled) == "boolean" then
		boot_llm_enabled = boot_saved_prefs.llm_enabled
	elseif ok_core_llm and type(core_llm) == "table"
		and type(core_llm.DEFAULT_STATE) == "table" then
		boot_llm_enabled = (core_llm.DEFAULT_STATE.llm_enabled == true)
	else
		boot_llm_enabled = false
	end
end

if boot_llm_enabled then
	local active_backend = backend_detector.effective_backend()
	Logger.info(LOG, "Bootstrapping default LLM backend: %s", active_backend)
	-- Defer the dependency check off the critical boot path. Its synchronous setup
	-- (resolving the script, writing the PTY wrapper, chmod via os.execute, and
	-- hs.task creation) costs hundreds of ms, and nothing on the boot path needs the
	-- venv to be ready synchronously — the backend server start is itself lazy. A
	-- doAfter(0) tick runs it right after boot completes, the same pattern
	-- start_background_network_bootstrap already uses.
	hs.timer.doAfter(0, function()
		if active_backend == backend_detector.BACKEND_MLX then
			pcall(mlx_deps_checker.check_and_install_deps)
		else
			pcall(ollama_deps_checker.check_and_install_deps)
		end
	end)
	if ok_core_llm and type(core_llm.start_background_network_bootstrap) == "function" then
		core_llm.start_background_network_bootstrap()
	end
else
	Logger.info(LOG, "LLM boot disabled at startup — skipping backend bootstrap.")
end

Boot.mark("LLM backend bootstrap")

local configured_hotstrings_dir = menu_paths.get("HotstringsDirPath")
local bundled_hotstrings_dir    = base_dir .. "../_shared/modules/hotstrings/"
local hotstrings_dir            = configured_hotstrings_dir

local HOTSTRINGS_EXCLUDED_STEMS = {
	hotstrings_config = true,
	personal_hotstrings = true,
	personal_info = true,
	config = true,
	paths = true,
}

-- Blessed hs.fs.dir wrapper (throw- and state-safe) now lives in lib/fs_dir so
-- the contract is honoured in exactly one place across the driver; see
-- init-fsdir-drops-state. Aliased locally so every call site below is unchanged.
local safe_dir_entries = require("lib.fs_dir").entries

local function has_common_hotstring_groups(dir)
	if type(dir) ~= "string" or dir == "" then return false end
	local ok_attr, attr = pcall(hs.fs.attributes, dir)
	if not ok_attr or type(attr) ~= "table" or attr.mode ~= "directory" then
		return false
	end
	for _, fname in ipairs(safe_dir_entries(dir)) do
		if fname:match("%.toml$") and not fname:match("^_") then
			local stem = fname:match("^(.-)%.toml$")
			if stem and not HOTSTRINGS_EXCLUDED_STEMS[stem] then
				return true
			end
		end
	end
	return false
end

if not has_common_hotstring_groups(configured_hotstrings_dir) and has_common_hotstring_groups(bundled_hotstrings_dir) then
	hotstrings_dir = bundled_hotstrings_dir
	Logger.warn(LOG, "No shared hotstring groups in '%s' — using bundled directory '%s'.",
		configured_hotstrings_dir, hotstrings_dir)
end

-- Initialise the hotstrings_config module so per-group delays and tooltip
-- colors can be resolved from the TOML metadata + the shared user override
-- file. The resolver routes the personal category through the (possibly
-- relocated) personal_hotstrings.toml; everything else lives in `hotstrings_dir`.
do
	local hotstrings_config = require("modules.hotstrings.hotstrings_config")
	local override_path = menu_paths.get_config_dir()
	if not override_path:match("[/\\]$") then override_path = override_path .. "/" end
	override_path = override_path .. "hotstrings_config.toml"
	hotstrings_config.init({
		override_path = override_path,
		toml_resolver = function(category)
			if category == "personal" then
				return menu_paths.get("PersonalTomlPath")
			end
			-- Extension personal TOML groups: personal_ext_<stem> → hotstrings/<stem>.toml
			local ext_stem = category:match("^personal_ext_(.+)$")
			if ext_stem then
				return menu_paths.get("PersonalHotstringsDir") .. ext_stem:gsub("__", "/") .. ".toml"
			end
			return hotstrings_dir .. category .. ".toml"
		end,
	})

	-- Wire the config window so it can discover personal + extension files.
	local ok_cw, cw = pcall(require, "ui.hotstrings_config_window")
	if ok_cw and cw and type(cw.setup) == "function" then
		local extensions_dir = base_dir .. "../../extensions"
		cw.setup({
			personal_dir   = menu_paths.get("PersonalHotstringsDir"),
			extensions_dir = extensions_dir,
		})
	end
end





-- =================================
-- ==================================
-- ======= 3/ Config Priming =======
-- ==================================
-- =================================

-- Magic key (the hotstring trigger character) defaults here; a user's custom
-- value and per-section enabled states are restored from config.toml by
-- menu_state during menu start (the v2 config is TOML, not the legacy config.json).
local magic_key = "★"

-- Pass the trigger char to keymap before loading files so magic-key hotstrings
-- register against the right character.
if keymap.set_trigger_char then
	keymap.set_trigger_char(magic_key)
end





-- ===========================================
-- ============================================
-- ======= 4/ TOML Discovery & Loading =======
-- ============================================
-- ===========================================

local ordered_names   = nil
local module_sections = nil

do
	-- Use the shared toml_codec instead of a hand-rolled parser so _index.toml
	-- gains full TOML support (multi-line strings, nested inline tables, etc.)
	-- without maintaining a second parser that can drift from the codec.
	local TomlCodec = require("toml_codec.codec")

	local fh = io.open(hotstrings_dir .. "_index.toml", "r")
	if fh then
		local raw = fh:read("*a")
		fh:close()
		local ok, data = pcall(TomlCodec.decode, raw)
		if ok and type(data) == "table" then
			local menu = data.menu
			if type(menu) == "table" and type(menu.categories_order) == "table" then
				ordered_names = menu.categories_order
			end
			if type(data.modules) == "table" then
				module_sections = data.modules
			end
		end
	end
end

local toml_set = {}
for _, fname in ipairs(safe_dir_entries(hotstrings_dir)) do
	-- Skip manifest/index files (prefixed with _) — they are metadata, not hotstring groups
	if fname:match("%.toml$") and not fname:match("^_") then
		local stem = fname:match("^(.-)%.toml$")
		if stem and not HOTSTRINGS_EXCLUDED_STEMS[stem] then
			toml_set[stem] = fname
		end
	end
end

local toml_fnames = {}



-- =====================================
-- ===== 4.1) Private Files First =====
-- =====================================

local PRIVATE_STEMS  = { personal = true }
local private_fnames = {}
for stem, fname in pairs(toml_set) do
	if PRIVATE_STEMS[stem] then table.insert(private_fnames, fname) end
end
table.sort(private_fnames)
for _, fname in ipairs(private_fnames) do
	toml_set[fname:match("^(.-)%.toml$")] = nil
	table.insert(toml_fnames, fname)
end



-- =====================================
-- ===== 4.2) Index-Ordered Files =====
-- =====================================

if ordered_names then
	for _, name in ipairs(ordered_names) do
		if toml_set[name] then
			table.insert(toml_fnames, toml_set[name])
			toml_set[name] = nil
		end
	end
end



-- ================================================
-- ===== 4.3) Remaining Files Alphabetically =====
-- ================================================

local remaining = {}
for _, fname in pairs(toml_set) do table.insert(remaining, fname) end
table.sort(remaining)
for _, fname in ipairs(remaining) do table.insert(toml_fnames, fname) end

local hotfiles = {}
local hotfile_paths = {}
-- Defer sorting for the entire startup load: personal, dynamic, and TOML files all
-- feed into the same mappings list. A single flush_sort() at the end collapses
-- what used to be 8+ full O(N log N) passes into one.
-- Loading order determines group_order (asc = higher priority), so personal
-- hotstrings must be registered FIRST to beat same-length common hotstrings.
keymap.defer_sort()
Boot.mark("TOML discovery + ordering")





-- ==================================
-- ===================================
-- ======= 5/ Post-load Hooks =======
-- ===================================
-- ==================================



-- ===================================
-- ===== 5.1) Custom Hotstrings =====
-- ===================================

-- Loaded FIRST so their group_order is lowest (= highest priority).
-- Priority order: personal > personal_ext_* > dynamic > common TOMLs > repeat.
-- personal_hotstrings.toml lives in <config_dir>/hotstrings/ (configurable via
-- the paths editor). Additional *.toml files placed in the same folder are loaded
-- automatically as extra personal extension groups in alphabetical order by stem.
do
	local personal_path = menu_paths.get("PersonalTomlPath")
	-- Personal source-default priority, read from the shared single source
	-- (_shared/modules/hotstrings/priority.json, copied into the bundle) so the editor
	-- shows it as the priority field placeholder without hardcoding it. Falls back
	-- to the engine value (kept identical to that file by the parity gate).
	local personal_default_priority = keymap.source_priority and keymap.source_priority("personal") or nil
	do
		local fh = io.open(bundled_hotstrings_dir .. "priority.json", "r")
		if fh then
			local raw = fh:read("*a")
			fh:close()
			local ok, parsed = pcall(hs.json.decode, raw)
			if ok and type(parsed) == "table" and type(parsed.personal) == "number" then
				personal_default_priority = parsed.personal
			end
		end
	end
	hotstring_editor.init(personal_path, keymap, nil, personal_default_priority)
	keymap.load_toml("personal", personal_path)
	table.insert(hotfiles, "personal")
	hotfile_paths["personal"] = personal_path

	-- Recursively scan for extra TOML files in the hotstrings folder
	local hs_dir = menu_paths.get("PersonalHotstringsDir")
	local function scan_recursive(dir, prefix)
		local ok_attr, attr = pcall(hs.fs.attributes, dir)
		if not (ok_attr and type(attr) == "table" and attr.mode == "directory") then return end

		local items = {}
		for _, fname in ipairs(safe_dir_entries(dir)) do
			if fname ~= "." and fname ~= ".." and not fname:match("^_") then
				local fpath = dir .. "/" .. fname
				local ok_a, a = pcall(hs.fs.attributes, fpath)
				if ok_a and type(a) == "table" then
					if a.mode == "directory" then
						table.insert(items, { type = "dir", name = fname, path = fpath })
					elseif a.mode == "file" and fname:match("%.toml$") and (prefix ~= "" or fname ~= "personal_hotstrings.toml") then
						local stem = fname:match("^(.-)%.toml$")
						if stem and stem ~= "" then
							table.insert(items, { type = "file", name = fname, stem = stem, path = fpath })
						end
					end
				end
			end
		end

		table.sort(items, function(a, b) return a.name < b.name end)

		for _, item in ipairs(items) do
			if item.type == "file" then
				local new_prefix = (prefix == "") and item.stem or (prefix .. "__" .. item.stem)
				local group_name = "personal_ext_" .. new_prefix
				keymap.load_toml(group_name, item.path)
				table.insert(hotfiles, group_name)
				hotfile_paths[group_name] = item.path
				Logger.info(LOG, "Loaded extra personal hotstrings group '%s' from '%s'.", group_name, item.path)
			else
				-- Recurse into subdirectory
				local new_prefix = (prefix == "") and item.name or (prefix .. "__" .. item.name)
				scan_recursive(item.path, new_prefix)
			end
		end
	end

	scan_recursive(hs_dir:gsub("[/\\]+$", ""), "")
end

-- Dynamic hotstrings (personal info, date triggers, etc.) — after personal,
-- before common TOMLs, so dynamic rules beat same-length common hotstrings.
Logger.debug(LOG, "Starting dynamic hotstrings module…")
local personal_info_toml_path = menu_paths.get("PersonalInfoTomlPath")
dynamic_hotstrings.start(base_dir, keymap, personal_info_toml_path)
table.insert(hotfiles, "dynamichotstrings")

-- Common TOML hotstring files — lowest priority among user-visible groups.
Logger.debug(LOG, "Loading common TOML hotstring files…")
local _toml_load_t0 = hs.timer.secondsSinceEpoch()
for _, fname in ipairs(toml_fnames) do
	local name = fname:match("^(.-)%.toml$")
	Logger.debug(LOG, string.format("Loading TOML file: %s…", name))
	keymap.load_toml(name, hotstrings_dir .. fname)
	table.insert(hotfiles, name)
	hotfile_paths[name] = hotstrings_dir .. fname
end
Logger.info(LOG, string.format("Loaded %d TOML hotstring file(s) in %.1fms.",
	#toml_fnames, (hs.timer.secondsSinceEpoch() - _toml_load_t0) * 1000))
-- Surface the snapshot-cache hit rate at INFO so the boot log shows whether the
-- hotstring load took the fast (cached) path. A miss-heavy boot (e.g. right after
-- an edit, or a stale cache dir) explains a slower "Hotstring groups registered".
do
	local ok_cache, toml_cache = pcall(require, "adapters.toml_cache")
	if ok_cache and type(toml_cache) == "table" and type(toml_cache.stats) == "function" then
		local s = toml_cache.stats()
		Logger.info(LOG, string.format("TOML snapshot cache: %d hit(s), %d miss(es), %d write(s) (enabled=%s).",
			s.hits or 0, s.misses or 0, s.writes or 0, tostring(s.enabled)))
	end
end
Boot.mark("Hotstring groups registered (personal + dynamic + common)")

-- Single final sort covering personal + dynamic + common TOML groups.
local _sort_t0 = hs.timer.secondsSinceEpoch()
keymap.flush_sort()
Logger.info(LOG, string.format("Final mapping sort completed in %.1fms.",
	(hs.timer.secondsSinceEpoch() - _sort_t0) * 1000))
Boot.mark("Final mapping sort + tail-index rebuild")

-- Start the keymap eventtap engine after all TOML groups are loaded and sorted.
-- This call was previously auto-invoked at the end of modules/keymap/init.lua
-- (M-13 fix), which started the taps before Karabiner and hotstrings were ready.
keymap.start()
Boot.mark("Keymap engine started")





-- =============================
-- ==============================
-- ======= 6/ UI Startup =======
-- ==============================
-- =============================

-- Initialize the Karabiner bridge (starts trackpad watcher + loads feature flags)
-- The FileSystem adapter is injected so KE config path resolution goes through
-- the port boundary (hs.fs.pathToAbsolute) instead of raw os.getenv("HOME").
karabiner.init(file_system)
Boot.mark("UI: karabiner.init")

Logger.debug(LOG, "Starting user interface components…")
menu.start(
	base_dir, hotfiles, gestures,
	keymap, dynamic_hotstrings, module_sections,
	karabiner, hotfile_paths
)
Boot.mark("UI: menu.start (menubar + state sync + engines + LLM handler)")

-- Script control is now managed through the shortcuts module
Logger.debug(LOG, "Starting script control engine…")
shortcuts.start_script_control(keymap, shortcuts, gestures, karabiner)

Logger.info(LOG, "User interface initialized successfully.")
Boot.mark("UI: script control start")



-- ========================================
-- ===== 6.1) Post-reload UI Restore =====
-- ========================================

-- Reopen any UIs that were open before the last file-watcher-triggered reload
ui_restore.restore()





-- ================================
-- =================================
-- ======= 7/ File Watchers =======
-- =================================
-- ================================

-- Global variables to prevent the Garbage Collector from destroying the watchers
_G.script_watchers = {}

do
	local reload_timer = nil

	local function schedule_reload(msg)
		if reload_timer then reload_timer:stop() end
		reload_timer = hs.timer.doAfter(0.5, function()
			ui_restore.defer_reload(function()
				-- snapshot() is a safety net for any UI still open at reload time;
				-- under normal deferral they are already closed so it saves nothing
				ui_restore.snapshot()
				pcall(notifications.notify, i18n.get("init.reload_title"), msg or i18n.get("init.reload_files"), "info")
				hs.reload()
			end)
		end)
	end



	-- ========================================
	-- ===== 7.1) Directory-Level Watcher =====
	-- ========================================

	-- Catches file creation, deletion, and renames in the hotstrings directory
	local dir_watcher = hs.pathwatcher.new(hotstrings_dir, function(paths)
		for _, p in ipairs(paths) do
			if p:match("%.toml$") or p:match("_index%.json$") or p:match("%.local_ahk_path$") then
				schedule_reload(i18n.get("init.reload_hotstrings"))
				return
			end
		end
	end)
	dir_watcher:start()
	table.insert(_G.script_watchers, dir_watcher)

	local function watch_personal_hotstrings_dir(dir)
		local ok_attr, attr = pcall(hs.fs.attributes, dir)
		if not (ok_attr and type(attr) == "table" and attr.mode == "directory") then return end

		local w = hs.pathwatcher.new(dir, function(paths)
			for _, p in ipairs(paths) do
				if not p:match("^/tmp/") then
					schedule_reload(i18n.get("init.reload_hotstrings"))
					return
				end
			end
		end)
		w:start()
		table.insert(_G.script_watchers, w)

		for _, fname in ipairs(safe_dir_entries(dir)) do
			if fname ~= "." and fname ~= ".." then
				local path = dir .. "/" .. fname
				local ok_a, a = pcall(hs.fs.attributes, path)
				if ok_a and type(a) == "table" then
					if a.mode == "directory" then
						watch_personal_hotstrings_dir(path)
					elseif a.mode == "file" and fname:match("%.toml$") then
						local fw = hs.pathwatcher.new(path, function()
							schedule_reload(i18n.get("init.reload_hotstrings"))
						end)
						fw:start()
						table.insert(_G.script_watchers, fw)
					end
				end
			end
		end
	end

	watch_personal_hotstrings_dir((menu_paths.get("PersonalHotstringsDir") or ""):gsub("[/\\]+$", ""))

	-- HTML/CSS/JS are webview assets loaded at open-time — only .lua changes
	-- drive Hammerspoon runtime behavior and warrant a reload
	Logger.debug(LOG, "Configuring file watchers for auto-reloading…")
	local project_watcher = hs.pathwatcher.new(base_dir, function(paths)
		for _, p in ipairs(paths) do
			-- Ignore temporary files (tokens, etc.)
			if p:find("^/tmp/") or p:find("hs_hf_token_") or p:find("hs_hf_login_") then
				return
			end
			if p:match("%.lua$") then
				Logger.debug(LOG, "Lua file change detected: %s", p)
				schedule_reload(i18n.get("init.reload_script"))
				return
			end
		end
	end)
	project_watcher:start()
	table.insert(_G.script_watchers, project_watcher)



	-- ==================================
	-- ===== 7.2) Per-File Watchers =====
	-- ==================================

	-- Safety net for in-place edits that directory watchers may miss
	for _, fname in ipairs(safe_dir_entries(hotstrings_dir)) do
		if fname:match("%.toml$") or fname:match("_index%.json$") then
			local w = hs.pathwatcher.new(hotstrings_dir .. fname, function()
				schedule_reload(i18n.get("init.reload_hotstrings"))
			end)
			w:start()
			table.insert(_G.script_watchers, w)
		end
	end
end





-- ====================================
-- =====================================
-- ======= 8/ Shutdown Callback =======
-- =====================================
-- ====================================

Boot.mark("File watchers armed")

hs.shutdownCallback = function()
	pcall(function() hs.settings.set(HS_BOOT_READY_SETTING_KEY, false) end)
	Logger.info(LOG, "Hammerspoon is shutting down — cleaning up resources…")

	-- 1. Stop core modules (releases eventtaps, timers, watchers)
	pcall(function() if keymap and type(keymap.stop) == "function" then keymap.stop() end end)
	pcall(function() if gestures and type(gestures.stop) == "function" then gestures.stop() end end)
	pcall(function() if shortcuts and type(shortcuts.stop) == "function" then shortcuts.stop() end end)

	-- 2. Restore system overrides
	if type(gestures) == "table" and type(gestures.restore_all_overrides) == "function" then
		pcall(gestures.restore_all_overrides)
	end

	-- 3. Tear down the Karabiner-Elements bridge — but ONLY on a genuine quit.
	-- Skip it entirely on a reload: the root grabber reapplies karabiner.json via
	-- FSEvents, so killing the user-level bridge here would needlessly drop
	-- remapping and, on some KE versions, cascade the grabber down — surfacing the
	-- native "install Karabiner" prompt on the next boot. Only a genuine quit (no
	-- reload sentinel) should stop remapping.
	if reload_guard.is_reloading() then
		Logger.info(LOG, "Reload in progress — leaving KE bridge alive (FSEvents will reapply the config).")
	else
		-- Genuine quit: use karabiner.kill(), which runs the launchctl BOOTOUT
		-- (KILL_CMD) synchronously. A bare pkill (KILL_FAST_CMD) is respawned within
		-- milliseconds by launchd's KeepAlive plist, so the keyboard would stay
		-- remapped after HS has exited. kill() also gates on is_hs_owned_bridge,
		-- leaving a user-managed KE setup untouched (a bare pkill killed it blindly).
		pcall(function()
			if karabiner and type(karabiner.kill) == "function" then
				karabiner.kill()
				Logger.info(LOG, "Shutdown KE bridge torn down via bootout (genuine quit).")
			end
		end)
	end

	-- 4. Flush the keylogger buffer so in-memory keystrokes are not lost on reload
	pcall(function()
		local ok_kl, kl = pcall(require, "modules.keylogger")
		if ok_kl and kl and type(kl.stop) == "function" then
			kl.stop()
		end
	end)

	-- 5. Terminate any running MLX server process
	pcall(function() require("ui.menu.menu_llm").stop_mlx_server() end)

	-- 6. Kill orphan child processes — shared with the script_quit action via
	-- menu_llm.terminate_helper_processes() so the os.exit quit path performs the
	-- identical teardown and the two paths can never drift.
	pcall(function() require("ui.menu.menu_llm").terminate_helper_processes() end)
	-- Kill any orphan mlx_lm.server on genuine quit only — not on reload.
	-- Boot logic deliberately spares a healthy server across sessions; killing it
	-- on every reload makes the cold-restart avoidance dead code.
	if not reload_guard.is_reloading() then
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
	-- Stop all path-watchers that were pinned at module scope to survive GC.
	-- Explicit :stop() prevents stray file-system callbacks from firing during
	-- the Lua state teardown window.
	if type(_G.script_watchers) == "table" then
		for _, w in ipairs(_G.script_watchers) do
			pcall(function() w:stop() end)
		end
	end
	Logger.info(LOG, "Hammerspoon arrêté")
end

-- Warm up macOS WebKit in the background so the first dashboard open is
-- not penalised by the framework load (~1-2 s).  Deferred so it never
-- blocks the boot critical path.
hs.timer.doAfter(2, function()
	pcall(function() require("ui.ui_builder").warmup_webkit() end)
end)

Boot.mark("Boot complete (post-init deferrals scheduled)")
Logger.info(LOG, "════════════════════════════════════════════════════════════")
Logger.info(LOG, "✅ Hammerspoon boot SUCCESSFUL.")
Logger.info(LOG, "════════════════════════════════════════════════════════════")
pcall(function() hs.settings.set(HS_BOOT_READY_SETTING_KEY, true) end)
-- Trigger the first Karabiner deploy HERE, after init.lua fully completes.
-- hs.timer callbacks scheduled during module init do not fire reliably;
-- calling regenerate() from this top-level context guarantees the event loop
-- is active and subsequent async timers in prime_ke_for_session will fire.
pcall(function()
	if type(karabiner) == "table"
		and type(karabiner.get_enabled) == "function"
		and karabiner.get_enabled()
		and type(karabiner.regenerate) == "function" then
		Logger.info(LOG, "Boot complete — triggering Karabiner async deploy…")
		karabiner.regenerate()
	end
end)
pcall(function()
	local ok_l, kl = pcall(require, "modules.karabiner.ke_lifecycle")
	if ok_l and kl and type(kl.flush_pending_ready_notification) == "function" then
		kl.flush_pending_ready_notification()
	end
end)
