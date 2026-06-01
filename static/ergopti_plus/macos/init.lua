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

-- Inject the shared/lua root into package.path so that lib/ shims for
-- toml_codec, toml_reader, and toml_writer can resolve their shared modules.
-- This must run before any require() that pulls in those libs.
do
	local _src = debug.getinfo(1, "S").source:gsub("^@", "")
	-- Resolve absolute path when source is relative (Hammerspoon always provides abs)
	local _abs = _src:match("^[/\\]") and _src or (hs.fs and hs.fs.currentDir and hs.fs.currentDir() .. "/" .. _src or _src)
	-- Strip "init.lua" to get the HS driver root
	local _hs_root = _abs:match("^(.*)[/\\][^/\\]+$") or _abs
	-- shared/ lives one level up from the HS driver root (in ergopti_plus/)
	local _ergopti_plus = _hs_root:match("^(.*)[/\\][^/\\]+$") or _hs_root
	local _shared       = _ergopti_plus .. "/shared/lua"
	if not package.path:find(_shared, 1, true) then
		package.path = _shared .. "/?.lua;" .. _shared .. "/?/init.lua;" .. package.path
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

local i18n               = require("lib.i18n")
local locale_mod         = require("lib.locale")
local crash_reporter     = require("lib.crash_reporter")

-- Wire i18n → locale so set_locale() updates the JSON loader's active locale.
-- Must run before any menu builder calls i18n.get() or locale_mod.get().
i18n.set_locale_injector(function(code) locale_mod.set_locale(code) end)
i18n.init()

local menu_paths         = require("ui.menu.menu_paths")
local gestures           = require("modules.gestures")
local keymap             = require("modules.keymap")
-- Expose keymap in the global table so the Hammerspoon console can call
-- keymap.perf_report_all() / perf_enable() / perf_reset() without
-- having to type out require("modules.keymap") each time.
_G.keymap = keymap
local shortcuts          = require("modules.shortcuts")
local dynamic_hotstrings = require("modules.dynamic_hotstrings")

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

-- Re-point the logger to <config_dir>/logs/ErgoptiPlus_YYYY-MM-DD.log now that
-- the user config dir is known. Earlier boot lines went to the fallback file.
Logger.init_log_path(menu_paths.get_config_dir(), 14)

-- Now safe to load modules that depend on config_dir
local file_system        = require("adapters.file_system")
local karabiner          = require("modules.karabiner")
local menu               = require("ui.menu")
local hotstring_editor   = require("ui.hotstring_editor")
local mlx_deps_checker    = require("lib.mlx_deps_checker")
local ollama_deps_checker = require("lib.ollama_deps_checker")
local backend_detector    = require("modules.llm.backend_detector")
local notifications       = require("lib.notifications")
local ui_restore         = require("lib.ui_restore")

-- Wire Logger.error → system notification so every ERROR surfaces to the user
-- without any module needing to call notifications.notify() directly.
-- Registered here (after notifications is loaded) to keep logger dependency-free.
Logger.set_error_notification_handler(function(module_name, message)
	pcall(notifications.notify, i18n.get("common.error_prefix") .. tostring(module_name), message, "error")
end)

-- Global uncaught-error handler: offer the user an opt-in crash report.
-- Hammerspoon surfaces unhandled errors via hs.crash.crashLog, but there is no
-- official OnError hook; we register a message watcher on the HS console to
-- catch errors bubbled up from coroutines and timers.
-- The simplest cross-version approach is to wrap the protected-call pattern in
-- every timer/callback, but we also expose a direct entry point here so any
-- module can call it after a pcall failure it cannot recover from.
_G.ergopti_report_crash = function(err, ctx)
	pcall(function()
		local report = crash_reporter.report(err, ctx)
		crash_reporter.prompt_user(report)
	end)
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

-- Hammerspoon does not always reap children on quit/reload (a SIGKILL on
-- the parent leaves orphans bound to port 49317), so a fresh boot can find
-- multiple zombie mlx_lm.server processes from previous sessions still
-- listening on the same port. The kernel then load-balances /v1/models
-- requests between them with SO_REUSEPORT, returning a different model ID
-- each time and breaking endpoint discovery permanently. Nuke them ALL
-- before any LLM code touches port 49317. Synchronous on purpose: we want
-- the port free before the warmup retry loop fires its first probe.
do
	local kill_cmd =
		-- Kill ALL mlx_lm processes regardless of port (catches old spawns
		-- on legacy ports 8080 and 8765 that previous sessions left behind).
		"PIDS=$(pgrep -f 'mlx_lm' 2>/dev/null); " ..
		"if [ -n \"$PIDS\" ]; then echo \"[BOOT] killing leftover mlx_lm processes: $PIDS\"; echo \"$PIDS\" | xargs kill -9 2>/dev/null; fi; " ..
		-- Kill anything still bound to the legacy ports + new port (paranoia).
		"for P in 8080 8765 49317; do " ..
		"  PIDS=$(lsof -tiTCP:$P -sTCP:LISTEN 2>/dev/null); " ..
		"  if [ -n \"$PIDS\" ]; then echo \"[BOOT] port $P listeners: $PIDS — leaving alone (might be LM Studio etc.)\"; fi; " ..
		"done; " ..
		"sleep 0.3; " ..
		-- Diagnostic: dump current state of port 49317 so we know if anything
		-- foreign is squatting it BEFORE we try to spawn.
		"echo \"[BOOT-DIAG] port 49317 current state:\"; lsof -i :49317 -P -n 2>/dev/null || echo \"  (port 49317 is FREE)\"; " ..
		"echo \"[BOOT-DIAG] any python on box:\"; pgrep -af python 2>/dev/null | head -10 || echo \"  (none)\""
	local out, ok = hs.execute(kill_cmd, true)
	Logger.info(LOG, "[BOOT-NUKE] mlx_lm cleanup ok=%s output=%s",
		tostring(ok), (out or ""):gsub("\n", " | "))
end

-- Background deps check for the active LLM backend. The detector picks
-- MLX on Apple Silicon (≥ macOS 13) and Ollama everywhere else; a
-- previously user-saved preference always wins. Both checkers are async
-- and silent on the fast path, so a normal reload stays invisible.
do
	local active_backend = backend_detector.effective_backend()
	Logger.info(LOG, "Bootstrapping default LLM backend: %s", active_backend)
	if active_backend == backend_detector.BACKEND_MLX then
		mlx_deps_checker.check_and_install_deps()
	else
		ollama_deps_checker.check_and_install_deps()
	end
end




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

local configured_hotstrings_dir = menu_paths.get("HotstringsDirPath")
local bundled_hotstrings_dir    = base_dir .. "../shared/hotstrings/"
local hotstrings_dir            = configured_hotstrings_dir
local config_file               = menu_paths.get("ConfigTomlPath")

local HOTSTRINGS_EXCLUDED_STEMS = {
	hotstrings_config = true,
	personal_hotstrings = true,
	personal_info = true,
	config = true,
	paths = true,
}

local function has_common_hotstring_groups(dir)
	if type(dir) ~= "string" or dir == "" then return false end
	local ok_attr, attr = pcall(hs.fs.attributes, dir)
	if not ok_attr or type(attr) ~= "table" or attr.mode ~= "directory" then
		return false
	end
	for fname in hs.fs.dir(dir) do
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
	Logger.warn(LOG, "No shared hotstring groups in '{1}' — using bundled directory '{2}'.",
		configured_hotstrings_dir, hotstrings_dir)
end

-- Initialise the hotstrings_config module so per-group delays and tooltip
-- colors can be resolved from the TOML metadata + the shared user override
-- file. The resolver routes the personal category through the (possibly
-- relocated) personal_hotstrings.toml; everything else lives in `hotstrings_dir`.
do
	local hotstrings_config = require("modules.hotstrings_config")
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

-- Restore section-enabled states and global trigger char from config.json BEFORE any TOML is parsed
local magic_key = "★"

do
	local fh = io.open(config_file, "r")
	if fh then
		local raw = fh:read("*a")
		fh:close()
		local ok, cfg = pcall(hs.json.decode, raw)
		if ok and type(cfg) == "table" then
			
			-- Read the global trigger character
			if type(cfg.trigger_char) == "string" then
				magic_key = cfg.trigger_char
			end

			-- Restore section states
			-- WHY explicit if/else: in Lua, both `false` and `nil` are falsy, so
			-- the idiom `cond and X or Y` cannot return `false` reliably and was
			-- silently writing `false` (disabling every section) at each restart
			if type(cfg.section_states) == "table" then
				for grp, secs in pairs(cfg.section_states) do
					if type(secs) == "table" then
						for sec_name, enabled in pairs(secs) do
							local key = "hotstrings_section_" .. grp .. "_" .. sec_name
							if enabled == false then
								hs.settings.set(key, false)
							else
								hs.settings.set(key, nil)
							end
						end
					end
				end
			end
		end
	end
end

-- Pass the loaded trigger char to keymap before loading files
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
for fname in hs.fs.dir(hotstrings_dir) do
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
	hotstring_editor.init(personal_path, keymap)
	keymap.load_toml("personal", personal_path)
	table.insert(hotfiles, "personal")
	hotfile_paths["personal"] = personal_path

	-- Recursively scan for extra TOML files in the hotstrings folder
	local hs_dir = menu_paths.get("PersonalHotstringsDir")
	local function scan_recursive(dir, prefix)
		local ok_attr, attr = pcall(hs.fs.attributes, dir)
		if not (ok_attr and type(attr) == "table" and attr.mode == "directory") then return end

		local items = {}
		for fname in hs.fs.dir(dir) do
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

-- Single final sort covering personal + dynamic + common TOML groups.
local _sort_t0 = hs.timer.secondsSinceEpoch()
keymap.flush_sort()
Logger.info(LOG, string.format("Final mapping sort completed in %.1fms.",
	(hs.timer.secondsSinceEpoch() - _sort_t0) * 1000))





-- =============================
-- ==============================
-- ======= 6/ UI Startup =======
-- ==============================
-- =============================

-- Initialize the Karabiner bridge (starts trackpad watcher + loads feature flags)
-- The FileSystem adapter is injected so KE config path resolution goes through
-- the port boundary (hs.fs.pathToAbsolute) instead of raw os.getenv("HOME").
karabiner.init(file_system)

Logger.debug(LOG, "Starting user interface components…")
menu.start(
	base_dir, hotfiles, gestures,
	keymap, dynamic_hotstrings, module_sections,
	karabiner, hotfile_paths
)

-- Script control is now managed through the shortcuts module
Logger.debug(LOG, "Starting script control engine…")
shortcuts.start_script_control(keymap, shortcuts, gestures, karabiner)

Logger.info(LOG, "User interface initialized successfully.")

-- App Cloner builds its own icon at first launch (see Contents/MacOS/AppCloner).
-- Encryptor still uses make_icon.sh on Hammerspoon startup since it doesn't
-- have a Python launcher to do lazy generation; keep its hook only.
hs.timer.doAfter(2, function()
	local encryptor_make = hs.configdir .. "/apps/Encryptor.app/Contents/Resources/make_icon.sh"
	local encryptor_icns = hs.configdir .. "/apps/Encryptor.app/Contents/Resources/AppIcon.icns"
	local needs_gen  = hs.execute(string.format("test -f %q && echo yes || echo no", encryptor_icns)):find("no")
	local has_script = hs.execute(string.format("test -f %q && echo yes || echo no", encryptor_make)):find("yes")
	if needs_gen and has_script then
		Logger.info(LOG, "Generating AppIcon.icns for Encryptor…")
		pcall(hs.execute, string.format("zsh %q &", encryptor_make))
	end
end)



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

		for fname in hs.fs.dir(dir) do
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
	for fname in hs.fs.dir(hotstrings_dir) do
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

hs.shutdownCallback = function()
	pcall(function() hs.settings.set(HS_BOOT_READY_SETTING_KEY, false) end)
	Logger.info(LOG, "Shutdown — restoring overrides.")
	if type(gestures) == "table" and type(gestures.restore_all_overrides) == "function" then
		pcall(gestures.restore_all_overrides)
	else
		Logger.warn(LOG, "restore_all_overrides unavailable — shutdown without restore.")
	end
	-- Stop Karabiner-Elements user-level helpers we spawned during priming.
	-- IMPORTANT: use KILL_FAST_CMD (synchronous plain pkill, ~50 ms) — NOT the
	-- async total-reset script. run_total_reset_async() spawns a detached 5-second
	-- kill loop that survives hs.reload(): the new session launches the bridge,
	-- but the zombie kill script from the old session immediately terminates it,
	-- causing 30 consecutive poll failures. KILL_FAST_CMD completes before HS
	-- reloads so there is no race with the newly spawned bridge.
	pcall(function()
		local ok_l, kl = pcall(require, "modules.karabiner.ke_lifecycle")
		if ok_l and kl and kl.KILL_FAST_CMD then
			hs.execute(kl.KILL_FAST_CMD)
			Logger.info(LOG, "Shutdown KE fast kill done.")
		end
	end)
	-- Terminate any running MLX server process so no orphaned Python process lingers
	-- after Hammerspoon exits. The require is cached, so this has no startup overhead.
	pcall(function() require("ui.menu.menu_llm").stop_mlx_server() end)
	-- Belt-and-braces: hs.task does not always reap its children when the
	-- parent dies abruptly. Kill any mlx_lm.server still bound to port 49317
	-- so the next reload starts from a clean slate.
	pcall(hs.execute,
		"pgrep -f 'mlx_lm.*server' | xargs kill -9 2>/dev/null; " ..
		"lsof -tiTCP:49317 -sTCP:LISTEN | xargs kill -9 2>/dev/null", true)
	Logger.info(LOG, "Hammerspoon arrêté")
end

-- Warm up macOS WebKit in the background so the first dashboard open is
-- not penalised by the framework load (~1-2 s).  Deferred so it never
-- blocks the boot critical path.
hs.timer.doAfter(2, function()
	pcall(function() require("ui.ui_builder").warmup_webkit() end)
end)

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
