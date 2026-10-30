--- adapters/field_probe_ports.lua

--- ==============================================================================
--- MODULE: Field Run Probe Ports (Hammerspoon)
--- DESCRIPTION:
--- The real Mac side of infra/field_check_probes.lua: the system facts the
--- field run's own checks read. adapters/field_check_ports.lua merges them
--- into the ports every field check receives.
---
--- FEATURES & RATIONALE:
--- 1. Read-only: each port reads a state the driver or macOS already holds; no
---    port prompts, grants, writes a setting or starts a feature.
--- 2. Paths stay here: a port may hand a path to a bounded command, and the
---    check reports only what the command answered.
--- ==============================================================================

local M = {}





-- ==============================
-- ==============================
-- ======= 1/ Permissions =======
-- ==============================
-- ==============================

--- Calls a native query that may be missing from this Hammerspoon build.
--- @param fn any The native function.
--- @param ... any Its arguments.
--- @return boolean|nil answer nil when absent or when it raised.
local function optional_query(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, answer = pcall(fn, ...)
	if not ok or type(answer) ~= "boolean" then return nil end
	return answer
end

--- The privacy grants of this process, read without prompting.
--- @return table facts { accessibility, screen_recording, input_monitoring, secure_input, bundle_id }
local function permission_facts()
	local eventtap = type(hs.eventtap) == "table" and hs.eventtap or {}
	return {
		accessibility = (require("adapters.accessibility_permission").is_trusted()),
		screen_recording = (require("adapters.screen_capture").permission_state()),
		-- Only some Hammerspoon builds can ask without prompting; nil otherwise
		input_monitoring = optional_query(eventtap.checkKeyboardEventAccess, false),
		secure_input = optional_query(eventtap.isSecureInputEnabled),
		bundle_id = (require("adapters.accessibility_permission").bundle_id()),
	}
end

--- The running application bundle, the one macOS files the grants under.
--- @return string|nil path
local function running_bundle_path()
	return (require("adapters.accessibility_permission").bundle_path())
end





-- ======================================
-- ======================================
-- ======= 2/ Event taps and loop =======
-- ======================================
-- ======================================

--- The keymap's tap states, or nil before the keymap is loaded.
--- @return table|nil states
local function tap_states()
	local keymap = package.loaded["modules.keymap"]
	if type(keymap) ~= "table" or type(keymap.tap_states) ~= "function" then return nil end
	return keymap.tap_states()
end

--- The main-thread holds counted since the last phase summary.
--- @return table counts { over_250ms, over_1000ms }
local function hold_counts()
	local PhaseStats = require("infra.phase_stats")
	return {
		over_250ms = PhaseStats.counter("runtime.timer_hold_over_250ms"),
		over_1000ms = PhaseStats.counter("runtime.timer_hold_over_1000ms"),
	}
end





-- ================================
-- ================================
-- ======= 3/ Input sources =======
-- ================================
-- ================================

-- The folders macOS reads keyboard layouts from, the user's first.
local LAYOUT_DIRS = { "/Library/Keyboard Layouts" }

--- The selected source and the enabled ones, as the text-input system holds them.
--- @return table facts { current = id|nil, enabled_ids = { id }|nil }
local function input_source_facts()
	local Probe = require("adapters.keyboard_source_probe")
	local layouts = Probe.enabled_layouts()
	return { current = Probe.current_source_id(), enabled_ids = layouts and layouts.ids or nil }
end

--- The Ergopti layout files installed for this user and for every user.
--- @return table files { keylayouts = { path }, plists = { path } }
local function layout_files()
	local FsDir = require("infra.fs_dir")
	local files = { keylayouts = {}, plists = {} }
	local dirs = {}
	local home = os.getenv("HOME")
	if home then dirs[#dirs + 1] = home .. "/Library/Keyboard Layouts" end
	for _, dir in ipairs(LAYOUT_DIRS) do dirs[#dirs + 1] = dir end
	for _, dir in ipairs(dirs) do
		for _, name in ipairs(FsDir.entries(dir)) do
			if name:lower():find("ergopti", 1, true) then
				local path = dir .. "/" .. name
				if name:match("%.keylayout$") then
					files.keylayouts[#files.keylayouts + 1] = path
				elseif name:match("%.bundle$") then
					files.plists[#files.plists + 1] = path .. "/Contents/Info.plist"
					local resources = path .. "/Contents/Resources"
					for _, inner in ipairs(FsDir.entries(resources)) do
						if inner:match("%.keylayout$") then files.keylayouts[#files.keylayouts + 1] = resources .. "/" .. inner end
					end
				end
			end
		end
	end
	table.sort(files.keylayouts)
	table.sort(files.plists)
	return files
end





-- ==========================
-- ==========================
-- ======= 4/ Storage =======
-- ==========================
-- ==========================

-- The configuration files the storage step parses, by config_paths key.
local CONFIG_FILES = {
	{ name = "config_toml", key = "ConfigTomlPath" },
	{ name = "karabiner_toml", key = "KarabinerConfigPath" },
	{ name = "personal_toml", key = "PersonalTomlPath" },
	{ name = "personal_info_toml", key = "PersonalInfoTomlPath" },
}

--- The configuration files, with whether each one exists.
--- @return table files { { name, path, present } }
local function config_files()
	local ConfigPaths = require("infra.config_paths")
	local FileSystem = require("adapters.file_system")
	local files = {}
	for _, entry in ipairs(CONFIG_FILES) do
		local path = ConfigPaths.get(entry.key)
		local present = type(path) == "string" and path ~= "" and FileSystem.exists(path) == true
		files[#files + 1] = { name = entry.name, path = path, present = present }
	end
	return files
end

--- Parses one TOML file with the driver's reader, writing nothing.
--- @param path string Absolute path.
--- @return boolean parsed
local function parse_toml(path)
	local ok, document = pcall(require("infra.toml.reader").parse, path)
	if not ok then
		require("infra.logger").warn("adapters.field_probe_ports", "A configuration file did not parse: %s.",
			tostring(document))
	end
	return ok and type(document) == "table"
end

--- The logs folder: today's log, a probe write, and the files it holds.
--- @return table facts { today_present, writable, files, bytes }
local function log_facts()
	local Logger = require("infra.logger")
	local FileSystem = require("adapters.file_system")
	local dir = Logger.logs_dir()
	local facts = { today_present = FileSystem.exists(Logger.today_log_path()) == true, writable = false,
		files = 0, bytes = 0 }
	if type(dir) ~= "string" or dir == "" then return facts end
	dir = dir:gsub("/+$", "")
	local probe = dir .. "/.ergopti-field-probe"
	facts.writable = FileSystem.write(probe, "field run\n") == true and FileSystem.delete(probe) == true
	for _, name in ipairs(require("infra.fs_dir").entries(dir)) do
		local size = hs.fs.attributes(dir .. "/" .. name, "size")
		if type(size) == "number" then
			facts.files = facts.files + 1
			facts.bytes = facts.bytes + size
		end
	end
	return facts
end

--- How many file watcher owners the boot published.
--- @return integer owners
local function watcher_owners()
	local roots = rawget(_G, "script_watchers")
	return type(roots) == "table" and #roots or 0
end

--- The keystats database, when the keystats module resolved it.
--- @return table database { path|nil, present }
local function keystats_database()
	local manager = package.loaded["modules.keystats.log_manager"]
	local path = type(manager) == "table" and type(manager.get_sqlite_path) == "function"
		and manager.get_sqlite_path() or nil
	if type(path) ~= "string" or path == "" then return { path = nil, present = false } end
	return { path = path, present = require("adapters.file_system").exists(path) == true }
end





-- ==========================
-- ==========================
-- ======= 5/ Factory =======
-- ==========================
-- ==========================

--- The probe ports, merged into adapters/field_check_ports.lua's table.
--- @return table ports
function M.new()
	return {
		permission_facts = permission_facts,
		running_bundle_path = running_bundle_path,
		tap_states = tap_states,
		hold_counts = hold_counts,
		lua_heap_kb = function() return collectgarbage("count") end,
		input_source_facts = input_source_facts,
		layout_files = layout_files,
		config_files = config_files,
		parse_toml = parse_toml,
		log_facts = log_facts,
		watcher_owners = watcher_owners,
		keystats_database = keystats_database,
	}
end

return M
