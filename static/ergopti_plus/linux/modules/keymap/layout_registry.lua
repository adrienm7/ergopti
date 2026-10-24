--- modules/keymap/layout_registry.lua

--- ==============================================================================
--- MODULE: Layout Registry (Linux client)
--- DESCRIPTION:
--- The Linux side of the layout manager: refreshes the registry catalogue,
--- installs, updates and uninstalls registry layouts, and makes one the
--- session's input source. A registry layout reaches Linux as its .keylayout
--- only: it is converted on this machine to XKB symbols, types and an XCompose
--- file (keylayout_to_xkb.py), then installed in the user XKB tree that
--- libxkbcommon reads first (user_layout_installer.py), without sudo.
---
--- FEATURES & RATIONALE:
--- 1. The catalogue decisions are shared with macOS (_shared/lua/layouts/
---    catalogue.lua): conditional refresh with the cached ETag, cache and
---    shipped-index fallbacks with the exact error, the installed record, and
---    the offline installation of a layout shipped with the package.
--- 2. Python 3.8 or newer runs the converter and the installer: every Linux
---    layout installer of this project already requires it, and a Lua port
---    would be a second source of truth for every layout. A missing or older
---    python3 fails with a translated explanation.
--- 3. Every child runs asynchronously (adapters/process_runner): the daemon
---    owns the keyboard and never waits on a conversion or an installation.
--- 4. The installed record is written last, so an interrupted installation
---    never claims a layout the session does not have. Every collaborator is
---    injectable, so tests replay operations without network, luv or python3.
--- ==============================================================================

local Logger        = require("logger.shim")
local Paths         = require("infra.paths")
local ConfigPaths   = require("infra.config_paths")
local I18n          = require("infra.i18n")
local FileSystem    = require("adapters.file_system")
local HttpClient    = require("adapters.http_client")
local FileDigest    = require("adapters.file_digest")
local ShellRunner   = require("adapters.shell_runner")
local ProcessRunner = require("adapters.process_runner")
local Json          = require("json")
local ShutdownHelpers, HelpersSettled = ProcessRunner.shutdown, ProcessRunner.is_settled
local CancelHttp, CancelDigest = HttpClient.cancel, FileDigest.cancel
local Registry      = require("layouts.registry")
local Catalogue     = require("layouts.catalogue")
local Outdated      = require("config_outdated")
local Extension     = require("layouts.extension")
local Composer      = require("layouts.composer")

local M = {}
local TextUtils = require("text_utils")

local LOG = "layout_registry"
local REQUEST_OWNER = "layout_registry"





-- ================================
-- ================================
-- ======= 1/ Constants ===========
-- ================================
-- ================================

-- Interpreter of the converter and the installer, looked up in PATH like the
-- installers do.
local PYTHON = "python3"

-- Oldest Python the converter supports (the installers' floor).
local MIN_PYTHON = { 3, 8 }

-- Exit code of the version probe when the interpreter is too old.
local PYTHON_TOO_OLD_EXIT = 3

-- The converter and the user installer, relative to the driver root: where the
-- package ships them, then where they live in a source checkout.
local CONVERTER_CANDIDATES = {
	"xkb_generation/keylayout_to_xkb.py",
	"../../ergopti/linux/xkb_generation/keylayout_to_xkb.py",
}
local INSTALLER_CANDIDATES = {
	"xkb_installation/user_layout_installer.py",
	"../../ergopti/linux/xkb_installation/user_layout_installer.py",
}

-- A conversion or an installation reads one layout; a second of work is
-- typical, a minute means it is stuck.
local CHILD_TIMEOUT_MS = 60000

-- The platform name registry entries list when Linux can install them.
local PLATFORM = "linux"

-- Stable failure codes the layout manager translates.
M.FAILURE_BUSY = "busy"
M.FAILURE_UNKNOWN_LAYOUT = "unknown_layout"
M.FAILURE_NOT_INSTALLED = "not_installed"
M.FAILURE_UNSUPPORTED = "unsupported_platform"
M.FAILURE_DOWNLOAD = "download_failed"
M.FAILURE_WRITE = "write_failed"
M.FAILURE_RECORD = "record_failed"
M.FAILURE_PYTHON = "python_missing"
M.FAILURE_CONVERSION = "conversion_failed"
M.FAILURE_INSTALLER = "installer_failed"
M.FAILURE_FOREIGN_FILE = "foreign_file"
M.FAILURE_XORG_SESSION = "xorg_session"
M.FAILURE_SELECT = "select_failed"
M.FAILURE_INVALID = "invalid"





-- ===========================
-- ===========================
-- ======= 2/ State ==========
-- ===========================
-- ===========================

-- Last refresh outcome: { index, source, error } (see Catalogue.resolve_index).
local _catalogue = { index = nil, source = Catalogue.SOURCE_NONE, error = nil }
-- The one operation in flight ({ id, action }), nil when idle.
local _busy = nil
-- The layout this session last made the input source, "" when none: the
-- desktop owns the real answer and offers no cheap way to ask it.
local _active = ""
-- Decoded index shipped with the package, read once.
local _bundled_index = nil
local _bundled_index_read = false
local _epoch = 0
local _stopping = false
local _checking_shutdown = false
local _transports_cancelled = false

--- Tests the original registry lifetime without borrowing a later request.
--- @param epoch number Captured lifetime generation.
--- @return boolean
local function current(epoch) return not _stopping and epoch == _epoch end

--- Fences async stages and disk mutations even for injected collaborators.
--- Read-only metadata remains available while native shutdown owns its debt.
--- @param source table Original collaborators.
--- @return table
local function scoped_deps(source)
	local epoch, scoped = _epoch, {}
	for key, value in pairs(source) do scoped[key] = value end
	for _, name in ipairs({ "write", "delete", "ensure_dir" }) do
		local operation = source[name]
		if type(operation) == "function" then
			scoped[name] = function(...)
				if not current(epoch) then return false, "layout registry stopped" end
				local ok, detail = operation(...)
				if not current(epoch) then return false, "layout registry stopped" end
				return ok, detail
			end
		end
	end
	if type(source.run) == "function" then
		scoped.run = function(program, args, options, callback)
			if not current(epoch) then return false end
			return source.run(program, args, options, function(...)
				if current(epoch) then return callback(...) end
			end)
		end
	end
	if type(source.transport) == "table" then
		scoped.transport = {}
		for key, value in pairs(source.transport) do scoped.transport[key] = value end
		local get, sha256 = source.transport.get, source.transport.sha256
		if type(get) == "function" then
			scoped.transport.get = function(url, headers, timeout_ms, callback)
				if not current(epoch) then return false end
				return get(url, headers, timeout_ms, function(...)
					if current(epoch) then return callback(...) end
				end)
			end
		end
		if type(sha256) == "function" then
			scoped.transport.sha256 = function(text, callback)
				if not current(epoch) then return false end
				return sha256(text, function(...)
					if current(epoch) then return callback(...) end
				end)
			end
		end
	end
	return scoped
end





-- ================================
-- ================================
-- ======= 3/ Settings ============
-- ================================
-- ================================

--- Reads and decodes one shared JSON file.
--- @param rel string Path under _shared/.
--- @return table|nil value
--- @return string|nil error
local function read_shared_json(rel)
	local path = Paths.shared(rel)
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	if type(raw) ~= "string" then return nil, "_shared/" .. rel .. " is unreadable" end
	-- The shared json.lua answers nil to invalid JSON rather than raising.
	local ok, decoded = pcall(Json.decode, raw)
	if not ok or type(decoded) ~= "table" then return nil, "_shared/" .. rel .. " is not valid JSON" end
	return decoded, nil
end

--- The registry settings, resolved from the shared defaults.
--- @return table|nil settings
--- @return string|nil error
function M.settings()
	local layouts, layouts_err = read_shared_json("modules/layouts/defaults.json")
	if not layouts then return nil, layouts_err end
	local updater, updater_err = read_shared_json("modules/updater/defaults.json")
	if not updater then return nil, updater_err end
	return Registry.resolve(layouts, updater, require("modules.updater.manager").installed_channel())
end

--- The first candidate path that exists under the driver root.
--- @param driver_root string Driver root, without a trailing slash.
--- @param candidates table Relative paths.
--- @param exists function exists(path) -> boolean
--- @return string|nil path
local function first_existing(driver_root, candidates, exists)
	for _, relative in ipairs(candidates) do
		local candidate = driver_root .. "/" .. relative
		if exists(candidate) then return candidate end
	end
	return nil
end

--- The converter shipped with this driver.
--- @param driver_root string Driver root, without a trailing slash.
--- @param exists function exists(path) -> boolean
--- @return string|nil path
function M.converter_path(driver_root, exists)
	return first_existing(driver_root, CONVERTER_CANDIDATES, exists)
end

--- The user XKB installer shipped with this driver.
--- @param driver_root string Driver root, without a trailing slash.
--- @param exists function exists(path) -> boolean
--- @return string|nil path
function M.installer_path(driver_root, exists)
	return first_existing(driver_root, INSTALLER_CANDIDATES, exists)
end

--- The registry folder shipped with the driver: under the driver root in the
--- package (tools/build/build-linux-driver.sh), at its repository path in a
--- checkout.
--- @param driver_root string
--- @param settings table
--- @param exists function
--- @return string|nil Folder with a trailing slash.
function M.bundled_dir(driver_root, settings, exists)
	for _, candidate in ipairs({
		driver_root .. "/" .. settings.folder,
		driver_root .. "/../../../" .. settings.folder,
	}) do
		if exists(candidate .. "/" .. settings.index_file) then return candidate .. "/" end
	end
	return nil
end

--- Creates a folder and its parents.
--- @param dir string
--- @return boolean
local function ensure_dir(dir)
	return ShellRunner.run("mkdir -p " .. ShellRunner.quote(dir) .. " 2>/dev/null")
end

--- Digests text through a temporary file (the digest runs in a child).
--- @param dir string Folder of the temporary file, created when missing.
--- @param timeout_ms number
--- @return function sha256(text, callback)
local function file_sha256(dir, timeout_ms)
	local path = dir .. ".digest.tmp"
	return function(text, callback)
		if not ensure_dir(dir) or not FileSystem.write(path, text) then
			callback(nil, "cannot stage " .. path)
			return
		end
		FileDigest.sha256(path, { timeout_ms = timeout_ms, owner = REQUEST_OWNER }, function(digest, err)
			FileSystem.delete(path)
			callback(digest, err)
		end)
	end
end

--- The production collaborators.
--- @param settings table Result of M.settings().
--- @return table
local function default_deps(settings)
	local local_dir = ConfigPaths.config(settings.local_folder) .. "/"
	local driver_root = Paths.driver_root()
	-- curl records the response ETag in this file (--etag-save); the transport
	-- reads it back so the shared refresh sees a header like on every driver.
	local etag_capture = local_dir .. ".index.etag.download"
	return {
		settings = settings,
		local_source = require("infra.installation").is_source_run(),
		transport = {
			get = function(url, headers, timeout_ms, callback)
				local is_index = url:sub(-#settings.index_file) == settings.index_file
				local options = {
					timeout_ms = timeout_ms,
					max_body_bytes = settings.max_file_bytes,
					owner = REQUEST_OWNER,
					https_only = true,
					follow_redirects = true,
				}
				if is_index and ensure_dir(local_dir) then options.etag_save = etag_capture end
				HttpClient.get(url, headers, options, function(result)
					local response_headers = {}
					if options.etag_save then
						local etag = FileSystem.read(etag_capture)
						if type(etag) == "string" and etag:match("%S") then
							response_headers.etag = TextUtils.trim(etag)
						end
						FileSystem.delete(etag_capture)
					end
					callback(result.status, result.body, result.error, response_headers)
				end)
			end,
			sha256 = file_sha256(local_dir, settings.timeout_ms),
		},
		decode_json = Json.decode,
		encode_json = Json.encode,
		read = FileSystem.read,
		write = FileSystem.write,
		delete = FileSystem.delete,
		exists = FileSystem.exists,
		ensure_dir = ensure_dir,
		run = ProcessRunner.run,
		local_dir = local_dir,
		bundled_dir = M.bundled_dir(driver_root, settings, FileSystem.exists),
		converter = M.converter_path(driver_root, FileSystem.exists),
		installer = M.installer_path(driver_root, FileSystem.exists),
		keycodes = Paths.shared("modules/layouts/mac_keycodes.json"),
		translate = I18n.get,
	}
end

--- Resolves the collaborators, the production ones by default.
--- @param deps table|nil
--- @return table|nil deps
--- @return string|nil error
local function resolve_deps(deps)
	if deps ~= nil then return scoped_deps(deps), nil end
	local settings, settings_err = M.settings()
	if not settings then return nil, settings_err end
	return scoped_deps(default_deps(settings)), nil
end





-- ==============================
-- ==============================
-- ======= 4/ Local files =======
-- ==============================
-- ==============================

--- Writes one file in the local folder, creating it first.
--- @param deps table
--- @param path string
--- @param content string
--- @return boolean ok
--- @return string|nil error
local function write_file(deps, path, content)
	local parent = assert(path:match("^(.*)/[^/]+$"), "layout write requires an absolute parent")
	if not deps.ensure_dir(parent) then return false, "cannot create " .. parent end
	local written, write_err = deps.write(path, content)
	if not written then return false, "cannot write " .. path .. ": " .. tostring(write_err) end
	return true, nil
end

--- The shipped index, reread for source checkouts so Refresh sees local edits.
--- @param deps table
--- @return table|nil
local function bundled_index(deps)
	if _bundled_index_read and not deps.local_source then return _bundled_index end
	_bundled_index_read = true
	if type(deps.bundled_dir) ~= "string" then
		Logger.warn(LOG, "No layout registry is shipped with this driver; offline installation is unavailable.")
		return nil
	end
	local text = deps.read(deps.bundled_dir .. deps.settings.index_file)
	local index, _, detail = Catalogue.decode_index(text, deps.decode_json, deps.settings.max_file_bytes)
	if not index then
		Logger.error(LOG, "The layout index shipped with the driver is unusable: %s.", tostring(detail))
	end
	_bundled_index = index
	return index
end

--- Reads the installed-layouts record. An entry this build cannot use is
--- warned once and left out; the other layouts stay installed.
--- @param deps table
--- @return table|nil record
--- @return string|nil error
local function read_installed(deps)
	local path = deps.local_dir .. deps.settings.installed_file
	if not deps.exists(path) then return Catalogue.decode_installed(nil, deps.decode_installed_json or Json.decode_lossless) end
	local text = deps.read(path)
	if type(text) ~= "string" then return nil, "cannot read " .. path end
	local record, err = Catalogue.decode_installed(text, deps.decode_installed_json or Json.decode_lossless)
	for id, item in pairs(record and record.outdated or {}) do
		Outdated.report_in_file(path, { "layouts", id }, item.detail)
	end
	return record, err
end

--- Writes the installed-layouts record.
--- @param deps table
--- @param record table
--- @return boolean ok
--- @return string|nil error
local function write_installed(deps, record)
	return write_file(deps, deps.local_dir .. deps.settings.installed_file, deps.encode_json(record))
end

--- The last JSON line a Python helper printed (its report), or nil.
--- @param stdout string|nil
--- @param decode function
--- @return table|nil
local function last_json_line(stdout, decode)
	local last = nil
	for line in tostring(stdout or ""):gmatch("[^\n]+") do
		if line:match("^%s*{") then last = line end
	end
	if not last then return nil end
	local ok, report = pcall(decode, last)
	return ok and type(report) == "table" and report or nil
end





-- ==================================
-- ==================================
-- ======= 5/ Python children =======
-- ==================================
-- ==================================

--- The version probe's argument vector.
--- @return table
local function version_probe_args()
	return {
		"-c",
		string.format("import sys; sys.exit(0 if sys.version_info >= (%d, %d) else %d)",
			MIN_PYTHON[1], MIN_PYTHON[2], PYTHON_TOO_OLD_EXIT),
	}
end

--- Runs a Python helper after checking the interpreter.
--- on_done(ok, result_or_code, detail) is called exactly once.
--- @param deps table
--- @param args table Argument vector after the interpreter.
--- @param on_done function
local function run_python(deps, args, on_done)
	deps.run(PYTHON, version_probe_args(), { timeout_ms = CHILD_TIMEOUT_MS }, function(probe)
		if probe.not_found or probe.exit_code == PYTHON_TOO_OLD_EXIT then
			on_done(false, M.FAILURE_PYTHON, "python3 3.8 or newer is required")
			return
		end
		if probe.error then
			on_done(false, M.FAILURE_PYTHON, "python3 does not run: " .. tostring(probe.error))
			return
		end
		deps.run(PYTHON, args, { timeout_ms = CHILD_TIMEOUT_MS }, function(result)
			on_done(true, result, nil)
		end)
	end)
end

--- Converts a verified layout to XKB files in <local folder>/<id>/.
--- @param deps table
--- @param entry table
--- @param layout_path string
--- @param index_path string Index carrying the layout's XKB hints.
--- @param on_done function on_done(ok, code, detail)
local function convert(deps, entry, layout_path, index_path, on_done)
	if not deps.converter then
		on_done(false, M.FAILURE_CONVERSION, "the .keylayout converter is not shipped with this driver")
		return
	end
	run_python(deps, {
		deps.converter,
		"--keylayout", layout_path,
		"--keycodes", deps.keycodes,
		"--convention", entry.keycode_convention,
		"--layout-id", entry.id,
		"--display-name", entry.name,
		"--index", index_path,
		"--out", deps.local_dir .. entry.id,
	}, function(started, result, detail)
		if not started then on_done(false, result, detail) return end
		if result.error then
			on_done(false, M.FAILURE_CONVERSION, result.stderr ~= "" and result.stderr or result.error)
			return
		end
		on_done(true, nil, nil)
	end)
end

--- Runs one command of the user XKB installer and reads its report.
--- @param deps table
--- @param args table Installer arguments.
--- @param on_done function on_done(ok, report_or_code, detail)
local function run_installer(deps, args, on_done)
	if not deps.installer then
		on_done(false, M.FAILURE_INSTALLER, "the user XKB installer is not shipped with this driver")
		return
	end
	local argv = { deps.installer }
	for _, arg in ipairs(args) do argv[#argv + 1] = arg end
	run_python(deps, argv, function(started, result, detail)
		if not started then on_done(false, result, detail) return end
		local report = last_json_line(result.stdout, deps.decode_json)
		if result.error or not report or report.ok ~= true then
			local reason = report and report.detail or result.stderr ~= "" and result.stderr or result.error
			-- A file the user owns in the XKB tree is theirs: say so, never overwrite.
			local code = report and report.code == "conflict" and M.FAILURE_FOREIGN_FILE or M.FAILURE_INSTALLER
			-- A pure Xorg session never reads the user XKB tree: nothing was written,
			-- and the user is told what to do instead of seeing a layout that types nothing.
			if report and report.code == "xorg_session" then code = M.FAILURE_XORG_SESSION end
			on_done(false, code, tostring(reason))
			return
		end
		on_done(true, report, nil)
	end)
end





-- ================================
-- ================================
-- ======= 6/ Catalogue ===========
-- ================================
-- ================================

--- Refreshes the catalogue from the registry (a conditional request).
--- on_done(outcome) runs once unless terminal shutdown cancels its delivery;
--- see Catalogue.resolve_index.
--- @param on_done function|nil
--- @param deps table|nil
--- @return boolean dispatched
function M.refresh(on_done, deps)
	if _stopping then return false end
	local epoch, receive = _epoch, on_done
	on_done = function(...) if current(epoch) and receive then return receive(...) end end
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then
		Logger.error(LOG, "The layout registry is unusable: %s.", tostring(deps_err))
		if on_done then on_done({ index = nil, source = Catalogue.SOURCE_NONE,
			error = { code = Catalogue.ERROR_INVALID_INDEX, detail = deps_err } }) end
		return false
	end
	deps = resolved
	Logger.start(LOG, "Refreshing the layout catalogue…")
	Catalogue.refresh(deps.settings, {
		local_source = deps.local_source,
		read_cache = function()
			local index_path = deps.local_dir .. deps.settings.index_file
			if not deps.exists(index_path) then return nil end
			local etag_path = deps.local_dir .. deps.settings.etag_file
			return { text = deps.read(index_path), etag = deps.exists(etag_path) and deps.read(etag_path) or nil }
		end,
		write_cache = function(text, etag)
			if not current(epoch) then return false, "layout registry stopped" end
			local ok, err = write_file(deps, deps.local_dir .. deps.settings.index_file, text)
			if not ok then return false, err end
			local etag_path = deps.local_dir .. deps.settings.etag_file
			if type(etag) == "string" then return write_file(deps, etag_path, etag) end
			if not deps.delete(etag_path) then return false, "cannot remove " .. etag_path end
			return true, nil
		end,
		bundled_index = bundled_index(deps),
		decode_json = deps.decode_json,
		transport = deps.transport,
	}, function(outcome)
		if not current(epoch) then return end
		_catalogue = { index = outcome.index, source = outcome.source, error = outcome.error }
		if outcome.cache_warning then Logger.warn(LOG, "%s; refreshed without it.", outcome.cache_warning) end
		if outcome.error then
			Logger.warn(LOG, "The layout catalogue shows the %s index: %s (%s).", outcome.source,
				outcome.error.code, tostring(outcome.error.detail))
		end
		if outcome.cache_error then Logger.error(LOG, "%s.", outcome.cache_error) end
		Logger.success(LOG, "Layout catalogue refreshed from the %s index.", outcome.source)
		if on_done then on_done(outcome) end
	end)
	return true
end

--- What the layout manager shows: the last catalogue, the installed layouts,
--- the operation in flight and the layout this session last activated.
--- @param deps table|nil
--- @return table { index, source, error, installed, busy, active, platform, record_error }
function M.snapshot(deps)
	local resolved = resolve_deps(deps)
	local snapshot = {
		index = _catalogue.index,
		source = _catalogue.source,
		error = _catalogue.error,
		installed = {},
		busy = _busy,
		active = _active,
		platform = PLATFORM,
	}
	if not resolved then return snapshot end
	deps = resolved
	if snapshot.index == nil then
		-- Before the first refresh the page lists the index shipped with the
		-- package, and says so rather than "no catalogue".
		snapshot.index = bundled_index(deps)
		if snapshot.index ~= nil then snapshot.source = Catalogue.SOURCE_BUNDLED end
	end
	local record, record_err = read_installed(deps)
	if not record then
		snapshot.record_error = record_err
		Logger.error(LOG, "The installed-layouts record is unusable: %s.", tostring(record_err))
		return snapshot
	end
	for _, entry in ipairs(Catalogue.installed_list(record)) do
		if deps.exists(deps.local_dir .. entry.id .. ".keylayout") then snapshot.installed[entry.id] = entry end
	end
	return snapshot
end





-- ======================================
-- ======================================
-- ======= 7/ Install / uninstall =======
-- ======================================
-- ======================================

--- Takes the one operation slot, or refuses.
--- @param id string
--- @param action string
--- @param on_done function
--- @return boolean acquired
local function acquire_slot(id, action, on_done)
	if _stopping then return false end
	if _busy then
		Logger.warn(LOG, "Refused to %s '%s': '%s' is still being %sed.", action, id, _busy.id, _busy.action)
		on_done(false, M.FAILURE_BUSY, "another layout operation is still running")
		return false
	end
	_busy = { id = id, action = action }
	return true
end

--- The failure's translated explanation when the user can act on its cause.
--- @param deps table
--- @param code string
--- @return string|nil
local function user_message(deps, code)
	if code == M.FAILURE_PYTHON then return deps.translate("layouts.linux_needs_python") end
	if code == M.FAILURE_XORG_SESSION then return deps.translate("layouts.linux_xorg_session") end
	return nil
end

--- Installs (or updates) one registry layout in the user XKB tree.
--- on_done(true, { entry, source, verified }) or
--- on_done(false, failure_code, detail, user_message) runs once unless terminal
--- shutdown cancels its delivery.
--- @param id string Registry id.
--- @param on_done function
--- @param deps table|nil
--- @return boolean dispatched
function M.install(id, on_done, deps)
	if _stopping then return false end
	local epoch, receive = _epoch, on_done
	on_done = function(...) if current(epoch) and receive then return receive(...) end end
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then
		Logger.error(LOG, "The layout registry is unusable: %s.", tostring(deps_err))
		on_done(false, M.FAILURE_DOWNLOAD, deps_err, nil)
		return false
	end
	deps = resolved
	if not Registry.is_valid_id(id) then
		on_done(false, M.FAILURE_UNKNOWN_LAYOUT, "'" .. tostring(id) .. "' is not a registry layout id", nil)
		return false
	end
	if not acquire_slot(id, "install", on_done) then return false end
	local function finish(ok, code_or_detail, detail)
		if not current(epoch) then return end
		_busy = nil
		if ok then
			Logger.success(LOG, "Installed the '%s' layout, version %s, from the %s copy (verified: %s).", id,
				tostring(code_or_detail.entry.version), code_or_detail.source, tostring(code_or_detail.verified))
			on_done(true, code_or_detail)
			return
		end
		Logger.error(LOG, "The '%s' layout was not installed (%s): %s.", id, tostring(code_or_detail), tostring(detail))
		on_done(false, code_or_detail, detail, user_message(deps, code_or_detail))
	end
	Logger.start(LOG, "Installing the '%s' layout…", id)
	-- The record is read before anything is written: a layout installed that
	-- it cannot record would be in the user XKB tree with nothing listing it.
	local _, record_problem = read_installed(deps)
	if record_problem ~= nil then
		finish(false, M.FAILURE_RECORD, record_problem)
		return false
	end
	M.refresh(function(outcome)
		if not current(epoch) then return end
		if not outcome.index then
			finish(false, M.FAILURE_DOWNLOAD, outcome.error and outcome.error.detail or "no registry index")
			return
		end
		local entry = Registry.find_entry(outcome.index, id)
		if not entry then
			finish(false, M.FAILURE_UNKNOWN_LAYOUT, "the layout '" .. id .. "' is not in the registry index")
			return
		end
		local supported = false
		for _, platform in ipairs(type(entry.platforms) == "table" and entry.platforms or {}) do
			if platform == PLATFORM then supported = true end
		end
		if not supported then
			finish(false, M.FAILURE_UNSUPPORTED, "the layout '" .. id .. "' is not published for Linux")
			return
		end
		Catalogue.acquire(deps.settings, entry, {
			bundled_index = bundled_index(deps),
			read_bundled = function(rel)
				return type(deps.bundled_dir) == "string" and deps.read(deps.bundled_dir .. rel) or nil
			end,
			transport = deps.transport,
		}, function(ok, detail)
			if not current(epoch) then return end
			if not ok then
				finish(false, M.FAILURE_DOWNLOAD, detail)
				return
			end
			if entry.extension ~= nil then
				local staged, stage_err = Extension.stage(deps.local_dir, entry, detail.content, {
					read = deps.read, write = function(path, text) return write_file(deps, path, text) end,
				})
				if not staged then finish(false, M.FAILURE_WRITE, stage_err) return end
			end
			local layout_path = deps.local_dir .. id .. ".keylayout"
			local written, write_err = write_file(deps, layout_path, detail.text)
			if not written then
				finish(false, M.FAILURE_WRITE, write_err)
				return
			end
			-- The converter reads the entry's XKB hints from an index; the one
			-- the entry came from is the cached copy, or the shipped one offline.
			local index_path = outcome.source == Catalogue.SOURCE_BUNDLED
				and deps.bundled_dir .. deps.settings.index_file
				or deps.local_dir .. deps.settings.index_file
			convert(deps, entry, layout_path, index_path, function(converted, code, convert_err)
				if not current(epoch) then return end
				if not converted then
					finish(false, code, convert_err)
					return
				end
				local args = {
					"install", "--layout-id", id, "--display-name", entry.name,
					"--source-dir", deps.local_dir .. id,
				}
				for _, language in ipairs(type(entry.languages) == "table" and entry.languages or {}) do
					args[#args + 1] = "--language"
					args[#args + 1] = language
				end
				run_installer(deps, args, function(installed, report, install_err)
					if not current(epoch) then return end
					if not installed then
						finish(false, report, install_err)
						return
					end
					local record, record_err = read_installed(deps)
					local saved, save_err = false, record_err
					if record then saved, save_err = write_installed(deps, Catalogue.with_installed(record, entry)) end
					if not saved then
						finish(false, M.FAILURE_RECORD, save_err)
						return
					end
					finish(true, { entry = entry, source = detail.source, verified = report.verified })
				end)
			end)
		end)
	end, deps)
	return true
end

--- Uninstalls one registry layout: removes it from the user XKB tree and the
--- desktop's input sources, then deletes the local copy and its record.
--- on_done(true, { id }) or on_done(false, failure_code, detail, user_message)
--- is called exactly once unless terminal shutdown cancels its delivery.
--- @param id string
--- @param on_done function
--- @param deps table|nil
--- @return boolean dispatched
function M.uninstall(id, on_done, deps)
	if _stopping then return false end
	local epoch, receive = _epoch, on_done
	on_done = function(...) if current(epoch) and receive then return receive(...) end end
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then
		on_done(false, M.FAILURE_RECORD, deps_err, nil)
		return false
	end
	deps = resolved
	local record, record_err = read_installed(deps)
	if not record then
		on_done(false, M.FAILURE_RECORD, record_err, nil)
		return false
	end
	if not (Registry.is_valid_id(id) and record.layouts[id]) then
		on_done(false, M.FAILURE_NOT_INSTALLED, "the layout '" .. tostring(id) .. "' was not installed here", nil)
		return false
	end
	if not acquire_slot(id, "uninstall", on_done) then return false end
	Logger.start(LOG, "Uninstalling the '%s' layout…", id)
	run_installer(deps, { "uninstall", "--layout-id", id }, function(removed, report, detail)
		if not current(epoch) then return end
		if not removed then
			_busy = nil
			Logger.error(LOG, "The '%s' layout was not uninstalled: %s.", id, tostring(detail))
			on_done(false, report, detail, user_message(deps, report))
			return
		end
		for _, path in ipairs({
			deps.local_dir .. id .. ".keylayout",
			deps.local_dir .. id .. "/" .. id .. ".xkb",
			deps.local_dir .. id .. "/" .. id .. ".XCompose",
			deps.local_dir .. id .. "/xkb_types.txt",
		}) do
			if not deps.delete(path) then Logger.warn(LOG, "Cannot delete %s.", path) end
		end
		local current, current_err = read_installed(deps)
		local ok, err = false, current_err
		if current then ok, err = write_installed(deps, Catalogue.without_installed(current, id)) end
		_busy = nil
		if not ok then
			Logger.error(LOG, "The '%s' layout is removed but its record is not: %s.", id, tostring(err))
			on_done(false, M.FAILURE_RECORD, err, nil)
			return
		end
		if _active == id then _active = "" end
		Logger.success(LOG, "Uninstalled the '%s' layout.", id)
		on_done(true, { id = id })
	end)
	return true
end

--- Makes one installed registry layout the session's first input source.
--- on_done(true, { id }) or on_done(false, failure_code, detail, user_message)
--- is called exactly once unless terminal shutdown cancels its delivery.
--- @param id string
--- @param on_done function
--- @param deps table|nil
--- @return boolean dispatched
function M.select(id, on_done, deps)
	if _stopping then return false end
	local epoch, receive = _epoch, on_done
	on_done = function(...) if current(epoch) and receive then return receive(...) end end
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then
		on_done(false, M.FAILURE_SELECT, deps_err, nil)
		return false
	end
	deps = resolved
	local record = read_installed(deps)
	if not (record and Registry.is_valid_id(id) and record.layouts[id]) then
		on_done(false, M.FAILURE_NOT_INSTALLED, "the layout '" .. tostring(id) .. "' is not installed", nil)
		return false
	end
	if not acquire_slot(id, "select", on_done) then return false end
	Logger.start(LOG, "Activating the '%s' layout…", id)
	run_installer(deps, { "activate", "--layout-id", id }, function(ok, report, detail)
		if not current(epoch) then return end
		_busy = nil
		if not ok then
			Logger.error(LOG, "The '%s' layout could not be activated: %s.", id, tostring(detail))
			on_done(false, M.FAILURE_SELECT, detail, user_message(deps, report))
			return
		end
		_active = id
		Logger.success(LOG, "Activated the '%s' layout.", id)
		on_done(true, { id = id })
	end)
	return true
end



-- ====================================
-- ====================================
-- ======= 8/ Composed layout =========
-- ====================================
-- ====================================

--- Installs the layout the user composed (docs/layout-composer.md) in the user
--- XKB tree: no catalogue and no download, the caller built the entry from the
--- compiled file. The converter reads the entry's hints from a one-layout
--- index written next to the copy.
--- on_done(true, { entry, source }) or on_done(false, failure_code, detail,
--- user_message) runs once unless terminal shutdown cancels its delivery.
--- @param entry table Record entry of the composition.
--- @param text string The compiled .keylayout.
--- @param on_done function
--- @param deps table|nil
--- @return boolean dispatched
function M.install_local(entry, text, on_done, deps)
	if _stopping then return false end
	local epoch, receive = _epoch, on_done
	on_done = function(...) if current(epoch) and receive then return receive(...) end end
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then
		on_done(false, M.FAILURE_WRITE, deps_err, nil)
		return false
	end
	deps = resolved
	local id = type(entry) == "table" and entry.id or nil
	if not Registry.is_valid_id(id) then
		on_done(false, M.FAILURE_UNKNOWN_LAYOUT, "'" .. tostring(id) .. "' is not a layout id", nil)
		return false
	end
	if not acquire_slot(id, "install", on_done) then return false end
	local function finish(ok, code_or_detail, detail)
		if not current(epoch) then return end
		_busy = nil
		if ok then
			Logger.success(LOG, "Installed the composed '%s' layout.", id)
			on_done(true, code_or_detail)
			return
		end
		Logger.error(LOG, "The composed '%s' layout was not installed (%s): %s.", id, tostring(code_or_detail),
			tostring(detail))
		on_done(false, code_or_detail, detail, user_message(deps, code_or_detail))
	end
	Logger.start(LOG, "Installing the composed '%s' layout…", id)
	local _, record_problem = read_installed(deps)
	if record_problem ~= nil then
		finish(false, M.FAILURE_RECORD, record_problem)
		return false
	end
	deps.transport.sha256(text, function(digest, digest_err)
		if not current(epoch) then return end
		local verified, reason = Registry.verify(entry, text, digest)
		if not verified then
			finish(false, M.FAILURE_INVALID, reason or digest_err)
			return
		end
		local layout_path = deps.local_dir .. id .. ".keylayout"
		local index_path = deps.local_dir .. id .. ".index.json"
		for _, step in ipairs({ { layout_path, text }, { index_path, deps.encode_json({ layouts = { entry } }) } }) do
			local written, write_err = write_file(deps, step[1], step[2])
			if not written then
				finish(false, M.FAILURE_WRITE, write_err)
				return
			end
		end
		convert(deps, entry, layout_path, index_path, function(converted, code, convert_err)
			if not current(epoch) then return end
			if not converted then
				finish(false, code, convert_err)
				return
			end
			run_installer(deps, { "install", "--layout-id", id, "--display-name", entry.name,
				"--source-dir", deps.local_dir .. id }, function(installed, report, install_err)
				if not current(epoch) then return end
				if not installed then
					finish(false, report, install_err)
					return
				end
				local record, record_err = read_installed(deps)
				local saved, save_err = false, record_err
				if record then saved, save_err = write_installed(deps, Catalogue.with_installed(record, entry)) end
				if not saved then
					finish(false, M.FAILURE_RECORD, save_err)
					return
				end
				finish(true, { entry = entry, source = "composer", verified = report.verified })
			end)
		end)
	end)
	return true
end

--- The composer's ports over this module (see layouts/composer.lua).
--- @param deps table Resolved collaborators.
--- @return table|nil operations
--- @return string|nil error
local function composer_operations(deps)
	local layout_defaults, defaults_err = read_shared_json("modules/layouts/defaults.json")
	if not layout_defaults then return nil, defaults_err end
	local settings, settings_err = Composer.settings(layout_defaults)
	if not settings then return nil, settings_err end
	local function installed()
		local record = read_installed(deps)
		return record and record.layouts or {}
	end
	return Composer.new({
		settings = settings,
		max_file_bytes = deps.settings.max_file_bytes,
		platform = PLATFORM,
		-- XKB has one level for every chord modifier: Ctrl, Alt and Win share it.
		shortcuts = "single",
		config_dir = deps.config_dir or (ConfigPaths.config("") .. "/"),
		decode_json = deps.decode_json,
		read = deps.read,
		exists = deps.exists,
		delete = deps.delete,
		write = function(path, content) return write_file(deps, path, content) end,
		sha256 = deps.transport.sha256,
		installed = installed,
		active_id = function() return _active end,
		sources_env = function()
			return {
				platform = PLATFORM,
				composer_id = settings.id,
				bundled_index = bundled_index(deps),
				bundled_dir = deps.bundled_dir,
				local_dir = deps.local_dir,
				installed = installed(),
				read = deps.read,
				sha256 = deps.transport.sha256,
				log = function(level, message, ...) Logger[level](LOG, message, ...) end,
			}
		end,
		install = function(entry, text, on_done) return M.install_local(entry, text, on_done, deps) end,
		uninstall = function(id, on_done) return M.uninstall(id, on_done, deps) end,
		select = function(id, on_done) return M.select(id, on_done, deps) end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	})
end

--- Runs one composer operation over the resolved collaborators.
--- @param deps table|nil
--- @param run function run(operations)
--- @param refuse function refuse(detail)
--- @return boolean dispatched
local function with_composer(deps, run, refuse)
	if _stopping then return false end
	local resolved, deps_err = resolve_deps(deps)
	local operations, operations_err
	if resolved then operations, operations_err = composer_operations(resolved) end
	if not operations then
		Logger.error(LOG, "The layout composer is unusable: %s.", tostring(deps_err or operations_err))
		refuse(deps_err or operations_err)
		return false
	end
	run(operations)
	return true
end

--- The composer's own settings (the reserved id, its folder and bounds).
--- @return table|nil settings
--- @return string|nil error
function M.composer_settings()
	local layout_defaults, defaults_err = read_shared_json("modules/layouts/defaults.json")
	if not layout_defaults then return nil, defaults_err end
	return Composer.settings(layout_defaults)
end

--- The text of an installed layout's copy, for the Debug check of the composer.
--- @param id string Layout id.
--- @param deps table|nil
--- @return string|nil text
--- @return string|nil error
function M.read_local_copy(id, deps)
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then return nil, deps_err end
	local text = resolved.read(resolved.local_dir .. id .. ".keylayout")
	if type(text) ~= "string" then return nil, "the installed copy of '" .. tostring(id) .. "' is unreadable" end
	return text, nil
end

--- The digest of a text, through the driver's own digest port (the Debug check of
--- the composer compares an installed copy with its record).
--- @param text string
--- @param on_done function on_done(digest|nil, error|nil)
--- @param deps table|nil
function M.sha256_text(text, on_done, deps)
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then
		on_done(nil, deps_err)
		return
	end
	resolved.transport.sha256(text, on_done)
end

--- Sends the composer page its sources and stored composition.
--- @param on_done function on_done(data)
--- @param deps table|nil
--- @return boolean dispatched
function M.composer_open(on_done, deps)
	return with_composer(deps, function(operations) operations.open(on_done) end, function() end)
end

--- Stores a composition and installs its layout.
--- @param payload table { declaration, keylayout, use }
--- @param on_done function on_done(ok, code, detail, used)
--- @param deps table|nil
--- @return boolean dispatched
function M.composer_save(payload, on_done, deps)
	return with_composer(deps, function(operations) operations.save(payload, on_done) end,
		function(detail) on_done(false, M.FAILURE_WRITE, detail, false) end)
end

--- Removes the composition.
--- @param on_done function on_done(ok, code, detail)
--- @param deps table|nil
--- @return boolean dispatched
function M.composer_remove(on_done, deps)
	return with_composer(deps, function(operations) operations.remove(on_done) end,
		function(detail) on_done(false, M.FAILURE_WRITE, detail) end)
end

--- Revokes every registry workflow before cancelling its external transports.
--- HTTP and digest cancellation fence delivery only; this ACK covers the native
--- install/activation helpers owned by ProcessRunner, not network retirement.
--- Cancelled workflows deliberately never invoke their business callbacks.
--- @return boolean acknowledged Every install/activation helper physically retired.
function M.shutdown()
	if not _stopping then _stopping = true; _epoch = _epoch + 1 end
	if _checking_shutdown then return false end
	_checking_shutdown = true
	if not _transports_cancelled then
		_transports_cancelled = true
		pcall(CancelHttp, REQUEST_OWNER)
		pcall(CancelDigest, REQUEST_OWNER)
	end
	local checked, settled = pcall(ShutdownHelpers)
	_checking_shutdown = false
	if checked and settled == true then _busy = nil; return true end
	return false
end

--- Test seam: forgets the catalogue, the operation slot and the shipped index.
function M._reset()
	if _stopping or HelpersSettled() ~= true then error("layout registry still owns terminal native lifetime", 2) end
	_epoch = _epoch + 1
	_catalogue = { index = nil, source = Catalogue.SOURCE_NONE, error = nil }
	_busy = nil
	_active = ""
	_bundled_index = nil
	_bundled_index_read = false
end

--- Roots of committed extension generations, without changing activation choices.
--- @param deps table|nil Optional filesystem collaborators.
--- @return table
function M.extension_roots(deps)
	local resolved, reason = resolve_deps(deps)
	if not resolved then error(reason, 0) end
	local record, err = read_installed(resolved)
	if not record then error(err, 0) end
	return Extension.roots(resolved.local_dir, record)
end

--- The extension root of the Ergopti family the driver ships, installed by shipping.
--- @param deps table|nil Optional filesystem collaborators.
--- @return table|nil { pack = dir } scanner root; nil when the registry is not shipped.
function M.shipped_extension_root(deps)
	local resolved = deps
	if resolved == nil then
		-- Offline shipped data belongs to the local registry. Its source path
		-- never needs the updater's initialized transport or installed channel.
		local layouts, layouts_error = read_shared_json("modules/layouts/defaults.json")
		if not layouts then error(layouts_error, 0) end
		local updater, updater_error = read_shared_json("modules/updater/defaults.json")
		if not updater then error(updater_error, 0) end
		local settings, settings_error = Registry.resolve(layouts, updater)
		if not settings then error(settings_error, 0) end
		resolved = { settings = settings, exists = FileSystem.exists,
			bundled_dir = M.bundled_dir(Paths.driver_root(), settings, FileSystem.exists) }
	end
	local root = Extension.shipped_root(resolved.bundled_dir, resolved.settings, resolved.exists)
	if root == nil then
		Logger.warn(LOG, "No shipped Ergopti extension: the driver ships no layout registry.")
	end
	return root
end

return M
