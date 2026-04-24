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





-- ===============================
-- ===============================
-- ======= 0/ Logger Setup =======
-- ===============================
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

-- Set our logger level. Uncomment one to enable:
Logger.set_level("DEBUG")  -- Show all logs (DEBUG, INFO, WARNING, ERROR)
-- Logger.set_level("INFO")   -- Show INFO, WARNING, ERROR only
-- Default: WARNING (production mode)

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

local menu_paths         = require("ui.menu.menu_paths")
local gestures           = require("modules.gestures")
local keymap             = require("modules.keymap")
-- Expose keymap in the global table so the Hammerspoon console can call
-- keymap.perf_report_all() / perf_enable() / perf_reset() without
-- having to type out require("modules.keymap") each time.
_G.keymap = keymap
local shortcuts          = require("modules.shortcuts")
local dynamic_hotstrings = require("modules.dynamic_hotstrings")
local karabiner          = require("modules.karabiner")
local menu               = require("ui.menu")
local hotstring_editor   = require("ui.hotstring_editor")
local mlx_deps_checker   = require("lib.mlx_deps_checker")
local notifications      = require("lib.notifications")
local ui_restore         = require("lib.ui_restore")

-- Wire Logger.error → system notification so every ERROR surfaces to the user
-- without any module needing to call notifications.notify() directly.
-- Registered here (after notifications is loaded) to keep logger dependency-free.
Logger.set_error_notification_handler(function(module_name, message)
	pcall(notifications.notify, "⚠️ Erreur — " .. tostring(module_name), message)
end)





-- ===================================
-- ===================================
-- ======= 1/ Module Pre-start =======
-- ===================================
-- ===================================

-- Pre-start modules so they are active before menu.lua reads saved prefs
-- Menu.lua will honor saved state and stop/start them as needed
Logger.debug(LOG, "Starting gestures module…")
gestures.start()
Logger.debug(LOG, "Starting shortcuts module…")
shortcuts.start()
Logger.info(LOG, "Main modules initialized successfully.")

-- Background check: verify Python MLX dependencies are installed
-- This runs asynchronously once per session, non-blocking
mlx_deps_checker.check_and_install_deps()





-- ==================================
-- ==================================
-- ======= 2/ Path Resolution =======
-- ==================================
-- ==================================

local script_path = debug.getinfo(1, "S").source
if script_path:sub(1, 1) == "@" then script_path = script_path:sub(2) end

local base_dir = script_path:match("^(.*[/\\])") or "./"
if not base_dir:match("[/\\]$") then base_dir = base_dir .. "/" end

-- Initialize the paths module early so every subsequent path lookup goes
-- through it — the user may have relocated files via the paths editor.
menu_paths.init(base_dir, function() hs.timer.doAfter(0.25, function() pcall(hs.reload) end) end)

local hotstrings_dir = menu_paths.get("HotstringsDirPath")
local config_file    = menu_paths.get("ConfigJsonPath")





-- =================================
-- =================================
-- ======= 3/ Config Priming =======
-- =================================
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
			if type(cfg.section_states) == "table" then
				for grp, secs in pairs(cfg.section_states) do
					if type(secs) == "table" then
						for sec_name, enabled in pairs(secs) do
							local key = "hotstrings_section_" .. grp .. "_" .. sec_name
							hs.settings.set(key, enabled ~= false and nil or false)
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
-- ===========================================
-- ======= 4/ TOML Discovery & Loading =======
-- ===========================================
-- ===========================================

local ordered_names   = nil
local module_sections = nil

do
	-- Minimal TOML parser for _index.toml: handles the flat structure produced
	-- by this file (string arrays, [section.sub.key] headers, key = "value").
	-- A full TOML library is not available in Hammerspoon, so we parse only
	-- the constructs actually present in the index manifest.
	local function parse_index_toml(raw)
		local result = {}
		local current_path = {}   -- active dotted-section path as a list

		local function set_nested(tbl, path, key, val)
			local node = tbl
			for _, p in ipairs(path) do
				if type(node[p]) ~= "table" then node[p] = {} end
				node = node[p]
			end
			node[key] = val
		end

		for line in raw:gmatch("[^\n]+") do
			-- Strip comments and trim
			local stripped = line:gsub("%s*#.*$", ""):match("^%s*(.-)%s*$")
			if stripped == "" then goto continue end

			-- Section header: [a.b.c]
			local header = stripped:match("^%[([^%]]+)%]$")
			if header then
				current_path = {}
				for part in header:gmatch("[^%.]+") do
					current_path[#current_path + 1] = part
				end
				-- Ensure the section table exists
				set_nested(result, {}, table.concat(current_path, "."), nil)
				local node = result
				for _, p in ipairs(current_path) do
					if type(node[p]) ~= "table" then node[p] = {} end
					node = node[p]
				end
				goto continue
			end

			-- key = ["a", "b", ...] — inline string array
			local arr_key, arr_body = stripped:match('^([%w_]+)%s*=%s*%[(.-)%]$')
			if arr_key and arr_body then
				local arr = {}
				for item in arr_body:gmatch('"([^"]*)"') do
					arr[#arr + 1] = item
				end
				set_nested(result, current_path, arr_key, arr)
				goto continue
			end

			-- key = "value"
			local str_key, str_val = stripped:match('^([%w_]+)%s*=%s*"([^"]*)"$')
			if str_key then
				set_nested(result, current_path, str_key, str_val)
				goto continue
			end

			::continue::
		end
		return result
	end

	local fh = io.open(hotstrings_dir .. "_index.toml", "r")
	if fh then
		local raw = fh:read("*a")
		fh:close()
		local ok, data = pcall(parse_index_toml, raw)
		if ok and type(data) == "table" then
			local menu = data.menu
			if type(menu) == "table" and type(menu.categories_order) == "table" then
				ordered_names = menu.categories_order
			end
			if type(data.module_sections) == "table" then
				module_sections = data.module_sections
			end
		end
	end
end

local toml_set = {}
for fname in hs.fs.dir(hotstrings_dir) do
	if fname:match("%.toml$") then
		toml_set[fname:match("^(.-)%.toml$")] = fname
	end
end

local toml_fnames = {}



-- ====================================
-- ===== 4.1) Private Files First =====
-- ====================================

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



-- ====================================
-- ===== 4.2) Index-Ordered Files =====
-- ====================================

if ordered_names then
	for _, name in ipairs(ordered_names) do
		if toml_set[name] then
			table.insert(toml_fnames, toml_set[name])
			toml_set[name] = nil
		end
	end
end



-- ===============================================
-- ===== 4.3) Remaining Files Alphabetically =====
-- ===============================================

local remaining = {}
for _, fname in pairs(toml_set) do table.insert(remaining, fname) end
table.sort(remaining)
for _, fname in ipairs(remaining) do table.insert(toml_fnames, fname) end

local hotfiles = {}
-- Defer sorting for the entire startup load: TOML files, dynamic hotstrings, and the
-- custom group all feed into the same mappings list. A single flush_sort() at the end
-- of section 5 collapses what used to be 8+ full O(N log N) passes into one.
keymap.defer_sort()
local _toml_load_t0 = hs.timer.secondsSinceEpoch()
for _, fname in ipairs(toml_fnames) do
	local name = fname:match("^(.-)%.toml$")
	Logger.debug(LOG, string.format("Loading TOML file: %s…", name))
	keymap.load_toml(name, hotstrings_dir .. fname)
	table.insert(hotfiles, name)
end
-- Visible at INFO so anyone watching the console can correlate launch time
-- with TOML volume without having to enable perf sampling explicitly.
Logger.info(LOG, string.format("Loaded %d TOML hotstring file(s) in %.1fms.",
	#toml_fnames, (hs.timer.secondsSinceEpoch() - _toml_load_t0) * 1000))





-- ==================================
-- ==================================
-- ======= 5/ Post-load Hooks =======
-- ==================================
-- ==================================

-- Start the dynamic hotstrings module which handles personal info internally
Logger.debug(LOG, "Starting dynamic hotstrings module…")
dynamic_hotstrings.start(base_dir, keymap)
table.insert(hotfiles, "dynamichotstrings")

Logger.debug(LOG, "Initializing custom hotstrings…")



-- ==================================
-- ===== 5.1) Custom Hotstrings =====
-- ==================================

-- Personal hotstrings are stored in personal.toml (path configurable via the
-- paths editor — defaults to hotstrings/personal.toml next to the driver).
do
	local personal_path = menu_paths.get("PersonalTomlPath")
	hotstring_editor.init(personal_path, keymap)
	keymap.load_toml("personal", personal_path)
	table.insert(hotfiles, "personal")
end

-- Single final sort covering TOML + dynamic + custom groups.
local _sort_t0 = hs.timer.secondsSinceEpoch()
keymap.flush_sort()
Logger.info(LOG, string.format("Final mapping sort completed in %.1fms.",
	(hs.timer.secondsSinceEpoch() - _sort_t0) * 1000))





-- =============================
-- =============================
-- ======= 6/ UI Startup =======
-- =============================
-- =============================

-- Initialize the Karabiner bridge (starts trackpad watcher + loads feature flags)
-- The module self-resolves its directory at load time — no path argument needed
karabiner.init()

Logger.debug(LOG, "Starting user interface components…")
menu.start(
	base_dir, hotfiles, gestures,
	keymap, dynamic_hotstrings, module_sections,
	karabiner
)

-- Script control is now managed through the shortcuts module
Logger.debug(LOG, "Starting script control engine…")
shortcuts.start_script_control(keymap, shortcuts, gestures, karabiner)

Logger.info(LOG, "User interface initialized successfully.")



-- =======================================
-- ===== 6.1) Post-reload UI Restore =====
-- =======================================

-- Reopen any UIs that were open before the last file-watcher-triggered reload
ui_restore.restore()





-- ================================
-- ================================
-- ======= 7/ File Watchers =======
-- ================================
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
				pcall(notifications.notify, "Hammerspoon", msg or "Fichiers modifiés — rechargement…")
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
				schedule_reload("Hotstrings modifiés — rechargement…")
				return
			end
		end
	end)
	dir_watcher:start()
	table.insert(_G.script_watchers, dir_watcher)

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
				schedule_reload("Script modifié — rechargement…")
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
				schedule_reload("Hotstrings modifiés — rechargement…")
			end)
			w:start()
			table.insert(_G.script_watchers, w)
		end
	end
end





-- ====================================
-- ====================================
-- ======= 8/ Shutdown Callback =======
-- ====================================
-- ====================================

hs.shutdownCallback = function()
	Logger.info(LOG, "Arrêt système — restauration des overrides")
	if type(gestures) == "table" and type(gestures.restore_all_overrides) == "function" then
		pcall(gestures.restore_all_overrides)
	else
		Logger.warn(LOG, "restore_all_overrides indisponible — arrêt sans restauration")
	end
	-- Terminate any running MLX server process so no orphaned Python process lingers
	-- after Hammerspoon exits. The require is cached, so this has no startup overhead.
	pcall(function() require("ui.menu.menu_llm").stop_mlx_server() end)
	Logger.info(LOG, "Hammerspoon arrêté")
end

Logger.info(LOG, "════════════════════════════════════════════════════════════")
Logger.info(LOG, "✅ Hammerspoon boot SUCCESSFUL.")
Logger.info(LOG, "════════════════════════════════════════════════════════════")
