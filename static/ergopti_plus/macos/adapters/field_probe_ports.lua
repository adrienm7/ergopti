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
	-- A plain write and remove: the file system adapter's atomic write keeps a
	-- lock file beside its target, which would stay in the user's logs folder.
	local probe = dir .. "/.ergopti-field-probe"
	local handle = io.open(probe, "wb")
	if handle then
		local written = handle:write("field run\n") ~= nil
		local closed = handle:close() == true
		facts.writable = written and closed and os.remove(probe) == true
	end
	for _, name in ipairs(require("infra.fs_dir").entries(dir)) do
		local attributes = hs.fs.attributes(dir .. "/" .. name)
		local size = type(attributes) == "table" and attributes.mode == "file" and attributes.size or nil
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





-- =================================
-- =================================
-- ======= 5/ Launcher roles =======
-- =================================
-- =================================

-- Ports the loopback server tries, from the dynamic range, before giving up.
local LOOPBACK_PORT_ATTEMPTS = 5
local LOOPBACK_PORT_MIN, LOOPBACK_PORT_MAX = 49152, 65535

--- The launcher this runtime resolves, with the environment it is run with.
--- @return string|nil launcher, table|nil environment
local function launcher()
	local path, _, environment = require("platform.remap.lease_helper").resolve()
	return path, environment
end

--- Runs one executable with exact stdin bytes and settles once.
--- @param executable string Absolute path.
--- @param args table Argument array.
--- @param input string Bytes written to stdin, then closed.
--- @param timeout_s number Seconds before the child is terminated.
--- @param callback function fn(exit_code|nil, stdout, stderr).
--- @param environment table|nil Explicit child environment.
local function exec_input(executable, args, input, timeout_s, callback, environment)
	local ShellRunner = require("adapters.shell_runner")
	local Timer = require("adapters.timer_scheduler")
	local settled, timer = false, nil
	local function settle(code, stdout, stderr)
		if settled then return end
		settled = true
		if timer then Timer.cancel(timer) end
		callback(code, stdout or "", stderr or "")
	end
	local handle = ShellRunner.spawn(executable, args, function(code, stdout, stderr)
		settle(code, stdout, stderr)
	end, nil, environment)
	if handle.isSettled() or not handle.start() then return settle(nil, "") end
	timer = Timer.after(timeout_s, function()
		timer = nil
		pcall(handle.terminate)
		settle(nil, "")
	end)
	if not handle.set_input(input) or not handle.close_input() then
		pcall(handle.terminate)
		settle(nil, "")
	end
end

--- Opens a loopback HTTP server that answers one path with 204 and counts the
--- requests it received; the caller stops it.
--- @param path string The path it answers.
--- @param callback function fn({ port, hits(), stop() } | nil).
local function loopback_server(path, callback)
	local hits = 0
	for _ = 1, LOOPBACK_PORT_ATTEMPTS do
		local port = math.random(LOOPBACK_PORT_MIN, LOOPBACK_PORT_MAX)
		local ok, server = pcall(function()
			local candidate = hs.httpserver.new(false, false)
			candidate:setInterface("loopback")
			candidate:setPort(port)
			candidate:setCallback(function(_, requested)
				if requested == path then hits = hits + 1 end
				return "", requested == path and 204 or 404, {}
			end)
			if candidate:start() ~= candidate or candidate:getPort() ~= port then
				pcall(function() candidate:stop() end)
				return nil
			end
			return candidate
		end)
		if ok and server then
			return callback({
				port = port,
				hits = function() return hits end,
				stop = function() pcall(function() server:stop() end) end,
			})
		end
	end
	require("infra.logger").warn("adapters.field_probe_ports", "No loopback port could be bound for the HTTP worker check.")
	callback(nil)
end





-- =============================
-- =============================
-- ======= 6/ App health =======
-- =============================
-- =============================

-- Seconds a crash report stays "recent", and the names that are this app's:
-- the app, its embedded Hammerspoon and the Ollama it runs. A python3 or uv
-- report could be any other program's, so those are left to the collector.
local CRASH_WINDOW_SECONDS = 24 * 3600
local CRASH_NAME_PATTERNS = { "^ergoptiplus", "^hammerspoon", "^ollama" }

--- Counts the files of a folder modified within the window whose lowercase
--- name matches one of the patterns (every file when patterns is nil).
--- @param dir string Absolute folder.
--- @param patterns table|nil Lua patterns.
--- @return integer count
local function recent_files(dir, patterns)
	local now, count = os.time(), 0
	for _, name in ipairs(require("infra.fs_dir").entries(dir)) do
		local lower, wanted = name:lower(), patterns == nil
		for _, pattern in ipairs(patterns or {}) do
			if lower:match(pattern) then wanted = true end
		end
		local attributes = wanted and hs.fs.attributes(dir .. "/" .. name) or nil
		local modified = type(attributes) == "table" and attributes.mode == "file" and attributes.modification or nil
		if type(modified) == "number" and now - modified <= CRASH_WINDOW_SECONDS then count = count + 1 end
	end
	return count
end

--- The crash reports of the last day: the driver's own, and macOS's for this app.
--- @return table counts { driver, system }
local function crash_counts()
	local home = os.getenv("HOME")
	local driver_dir = require("infra.logger").crash_reports_dir():gsub("/+$", "")
	return {
		driver = recent_files(driver_dir, nil),
		system = home and recent_files(home .. "/Library/Logs/DiagnosticReports", CRASH_NAME_PATTERNS) or 0,
	}
end





-- ===========================
-- ===========================
-- ======= 7/ Local AI =======
-- ===========================
-- ===========================

-- Seconds the one-token prediction may take, a cold model load included.
local PREDICTION_TIMEOUT_SECONDS = 60

--- The catalogue's models for one backend, smallest download first.
--- @param backend string "ollama" or "mlx".
--- @return table models { { name, runtime_name, download_gb } }
local function catalogue_models(backend)
	local path = require("infra.paths").shared_llm_path("models.json")
	local text = path and require("adapters.file_system").read(path) or nil
	if type(text) ~= "string" then return {} end
	local ModelCatalogue = require("llm.model_catalogue")
	local models = {}
	for _, provider in ipairs(require("json").decode(text)) do
		for _, family in ipairs(type(provider.families) == "table" and provider.families or {}) do
			for _, model in ipairs(type(family.models) == "table" and family.models or {}) do
				local runtime = ModelCatalogue.runtime_name(model, backend)
				local sizes = type(model.hardware_requirements) == "table" and model.hardware_requirements[backend] or nil
				local size = type(sizes) == "table" and tonumber(sizes.download_gb) or nil
				if runtime and size and type(model.name) == "string" then
					models[#models + 1] = { name = model.name, runtime_name = runtime, download_gb = size }
				end
			end
		end
	end
	table.sort(models, function(a, b) return a.download_gb < b.download_gb end)
	return models
end

--- The AI menu's models manager, or nil before the menu exists.
local function models_manager()
	local menu = package.loaded["ui.menu.menu_llm"]
	return type(menu) == "table" and type(menu.active_models_manager) == "function"
		and menu.active_models_manager() or nil
end

--- The local AI facts read without starting anything.
--- @return table facts { ollama_path|nil, mlx_runtime|nil, mlx_installed|nil }
local function ai_facts()
	local facts = {}
	facts.ollama_path = (require("modules.llm.ollama_binary").resolve())
	local ok, installed = pcall(function() return require("modules.llm.mlx_deps_checker").runtime_installed() end)
	if ok then facts.mlx_runtime = installed == true end
	local manager = models_manager()
	if manager and type(manager.mlx_model_installed) == "function" then
		local count = 0
		for _, model in ipairs(catalogue_models("mlx")) do
			if manager.mlx_model_installed(model.name) == true then count = count + 1 end
		end
		facts.mlx_installed = count
	end
	return facts
end

--- Lists the models of a running Ollama server, without starting it.
--- @param callback function fn(listed).
local function ollama_refresh(callback)
	local Api = require("modules.llm.api_ollama")
	Api.forget_local_models()
	Api.refresh_local_models(function(listed) callback(listed == true) end)
end

--- The smallest catalogue model the last listing holds.
--- @return string|nil runtime_name
local function ollama_installed_model()
	local Api = require("modules.llm.api_ollama")
	for _, model in ipairs(catalogue_models("ollama")) do
		if Api.local_model_installed(model.runtime_name) == true then return model.runtime_name end
	end
	return nil
end

--- Predicts one token through the driver's own Ollama request path.
--- @param model string Installed model.
--- @param text string The check's own text.
--- @param callback function fn(answered, failure_token|nil, elapsed_ms).
local function ollama_predict(model, text, callback)
	local Timer = require("adapters.timer_scheduler")
	local started, settled, timer = hs.timer.absoluteTime(), false, nil
	local function settle(answered, token)
		if settled then return end
		settled = true
		if timer then Timer.cancel(timer) end
		callback(answered, token, (hs.timer.absoluteTime() - started) / 1e6)
	end
	timer = Timer.after(PREDICTION_TIMEOUT_SECONDS, function()
		timer = nil
		settle(false, "timeout")
	end)
	require("modules.llm.api_ollama").request_raw(model, "", text, "", 0, 1,
		function() settle(true) end, function() settle(false, "request_failed") end)
end





-- ==========================
-- ==========================
-- ======= 8/ Factory =======
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
		launcher = launcher,
		exec_input = exec_input,
		loopback_server = loopback_server,
		crash_counts = crash_counts,
		pid = function() return hs.processInfo.processID end,
		ai_facts = ai_facts,
		ollama_refresh = ollama_refresh,
		ollama_installed_model = ollama_installed_model,
		ollama_predict = ollama_predict,
	}
end

return M
