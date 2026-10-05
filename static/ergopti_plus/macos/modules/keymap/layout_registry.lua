--- modules/keymap/layout_registry.lua

--- ==============================================================================
--- MODULE: Layout Registry (macOS client)
--- DESCRIPTION:
--- The macOS side of the layout manager: refreshes the registry catalogue,
--- installs, updates and uninstalls registry layouts, and selects one as the
--- current input source. A registry layout is its .keylayout, which macOS reads
--- natively: installing it writes the verified file, unchanged, to
--- ~/Library/Keyboard Layouts and adds it to the enabled input sources.
---
--- FEATURES & RATIONALE:
--- 1. The catalogue decisions are shared with Linux (_shared/lua/layouts/
---    catalogue.lua): conditional refresh with the cached ETag, cache and
---    shipped-index fallbacks with the exact error, the installed record, and
---    the offline installation of a layout shipped with the app.
--- 2. Nothing is written before the layout matches its index. The installed
---    record is written last, so an interrupted installation never claims a
---    layout the system does not have.
--- 3. An Ergopti layout already provided by an installed Ergopti bundle is not
---    installed a second time: two input sources would carry the same name.
--- 4. Every collaborator is injectable, so tests replay installations without
---    network, Hammerspoon or a real home folder. Nothing here runs on the
---    typing path: every entry point is a menu or window action.
--- ==============================================================================

local Logger       = require("infra.logger")
local Paths        = require("infra.paths")
local ConfigPaths  = require("infra.config_paths")
local FileSystem   = require("adapters.file_system")
local HttpClient   = require("adapters.http_client")
local Crypto       = require("adapters.crypto")
local Json         = require("json")
local Registry     = require("layouts.registry")
local Catalogue    = require("layouts.catalogue")
local Outdated     = require("config_outdated")
local Extension    = require("layouts.extension")

local M = {}

local LOG = "layout_registry"

-- Folder macOS reads the current user's keyboard layouts from.
local USER_LAYOUTS_DIR = "~/Library/Keyboard Layouts"

-- Stable failure codes the layout manager translates.
M.FAILURE_BUSY = "busy"
M.FAILURE_UNKNOWN_LAYOUT = "unknown_layout"
M.FAILURE_NOT_INSTALLED = "not_installed"
M.FAILURE_PROVIDED_BY_BUNDLE = "provided_by_bundle"
M.FAILURE_FOREIGN_FILE = "foreign_file"
M.FAILURE_UNSUPPORTED = "unsupported_platform"
M.FAILURE_DOWNLOAD = "download_failed"
M.FAILURE_WRITE = "write_failed"
M.FAILURE_RECORD = "record_failed"
M.FAILURE_SELECT = "select_failed"

-- The platform name registry entries list when macOS can install them.
local PLATFORM = "macos"





-- ===========================
-- ===========================
-- ======= 1/ State ==========
-- ===========================
-- ===========================

-- Last refresh outcome: { index, source, error } (see Catalogue.resolve_index).
local _catalogue = { index = nil, source = Catalogue.SOURCE_NONE, error = nil }
-- The one operation in flight ({ id, action }), nil when idle: an installation
-- and an uninstallation of the same layout must never interleave their writes.
local _busy = nil
-- Decoded index shipped with the app, read once.
local _bundled_index = nil
local _bundled_index_read = false





-- ================================
-- ================================
-- ======= 2/ Settings ============
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
	return Registry.resolve(layouts, updater, require("modules.updater").installed_channel())
end

--- The registry folder shipped with the app: the repository folder in a
--- checkout, its mirror under Contents/Resources in the packaged app (which
--- keeps the repository layout, tools/build/build_macos_app.sh).
--- @param settings table
--- @return string|nil Folder with a trailing slash, nil when the shared tree is unreachable.
local function bundled_dir(settings)
	local shared = Paths.shared_root()
	if type(shared) ~= "string" then return nil end
	return shared .. "/../../../" .. settings.folder .. "/"
end

--- The production collaborators.
--- @param settings table Result of M.settings().
--- @return table
local function default_deps(settings)
	local client = HttpClient.new({ timeout_ms = settings.timeout_ms })
	local InputSources = require("modules.keymap.input_sources")
	local Install = require("modules.keymap.layout_install")
	return {
		settings = settings,
		local_source = require("modules.updater").is_local_source(),
		transport = {
			get = function(url, headers, _timeout_ms, callback)
				client.get(url, headers, function(result)
					callback(result.status, result.body, result.error, result.headers)
				end)
			end,
			sha256 = function(text, callback)
				local digest = Crypto.sha256_bytes(text)
				if digest == "" then
					callback(nil, "the SHA-256 digest is unavailable")
				else
					callback(digest, nil)
				end
			end,
		},
		decode_json = Json.decode,
		encode_json = Json.encode,
		read = FileSystem.read,
		write = FileSystem.write,
		delete = FileSystem.delete,
		exists = FileSystem.exists,
		prepare_parent = FileSystem.prepare_parent_for_create,
		local_dir = ConfigPaths.get_config_dir() .. settings.local_folder .. "/",
		layouts_dir = FileSystem.expand_path(USER_LAYOUTS_DIR) .. "/",
		bundled_dir = bundled_dir(settings),
		enable_source = InputSources.enable_keylayout_source_async,
		disable_source = InputSources.disable_keylayout_source_async,
		select_source = InputSources.set_input_source_async,
		active_sources = InputSources.list_active_keyboard_layouts,
		bundle_names = Install.bundle_keylayout_names,
	}
end

--- Resolves the collaborators, the production ones by default.
--- @param deps table|nil
--- @return table|nil deps
--- @return string|nil error
local function resolve_deps(deps)
	if deps ~= nil then return deps, nil end
	local settings, settings_err = M.settings()
	if not settings then return nil, settings_err end
	return default_deps(settings), nil
end





-- ==============================
-- ==============================
-- ======= 3/ Local files =======
-- ==============================
-- ==============================

--- Writes one file, creating its folder first.
--- @param deps table
--- @param path string
--- @param content string
--- @return boolean ok
--- @return string|nil error
local function write_file(deps, path, content)
	local prepared, prepare_err = deps.prepare_parent(path)
	if not prepared then return false, "cannot create the folder of " .. path .. ": " .. tostring(prepare_err) end
	local written, write_err = deps.write(path, content)
	if not written then return false, "cannot write " .. path .. ": " .. tostring(write_err) end
	return true, nil
end

--- The shipped index, reread for source checkouts so Refresh sees local edits.
--- @param deps table
--- @return table|nil
local function bundled_index(deps)
	if deps.bundled_index ~= nil then return deps.bundled_index or nil end
	if _bundled_index_read and not deps.local_source then return _bundled_index end
	_bundled_index_read = true
	if type(deps.bundled_dir) ~= "string" then return nil end
	local text = deps.read(deps.bundled_dir .. deps.settings.index_file)
	local index, _, detail = Catalogue.decode_index(text, deps.decode_json, deps.settings.max_file_bytes)
	if not index then
		Logger.error(LOG, "The layout index shipped with the app is unusable: %s.", tostring(detail))
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
	local text = deps.exists(path) and deps.read(path) or nil
	if deps.exists(path) and type(text) ~= "string" then return nil, "cannot read " .. path end
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

--- Keyboard names the installed Ergopti bundles already provide.
--- @param deps table
--- @return table Set { [name] = true }.
local function bundle_names(deps)
	local ok, names = pcall(deps.bundle_names)
	if not ok or type(names) ~= "table" then
		Logger.warn(LOG, "The installed Ergopti bundles could not be listed: %s.", tostring(names))
		return {}
	end
	return names
end





-- ================================
-- ================================
-- ======= 4/ Catalogue ===========
-- ================================
-- ================================

--- Refreshes the catalogue from the registry (a conditional request).
--- on_done(outcome) is called exactly once; see Catalogue.resolve_index.
--- @param on_done function|nil
--- @param deps table|nil
--- @return boolean dispatched
function M.refresh(on_done, deps)
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

--- What the menu's layout picker shows: the installed layouts, sorted by
--- name, and the one of the current input source. It reads the record and the
--- cached input-source list only, so opening the menu starts no subprocess.
--- @param deps table|nil
--- @return table { layouts, active }
function M.picker(deps)
	local picker = { layouts = {}, active = "" }
	local resolved = resolve_deps(deps)
	if not resolved then return picker end
	deps = resolved
	local record, record_err = read_installed(deps)
	if not record then
		Logger.error(LOG, "The installed-layouts record is unusable: %s.", tostring(record_err))
		return picker
	end
	local names = {}
	for _, entry in ipairs(Catalogue.installed_list(record)) do
		if deps.exists(deps.layouts_dir .. entry.id .. ".keylayout") then
			picker.layouts[#picker.layouts + 1] = entry
			if type(entry.keyboard_name) == "string" then names[entry.keyboard_name] = entry.id end
		end
	end
	table.sort(picker.layouts, function(a, b) return tostring(a.name) < tostring(b.name) end)
	local ok, records = pcall(deps.active_sources)
	for _, source in ipairs(ok and type(records) == "table" and records or {}) do
		if source.selected and names[source.id] then picker.active = names[source.id] end
	end
	return picker
end

--- What the layout manager shows: the last catalogue, the installed layouts,
--- the ones an Ergopti bundle provides, the operation in flight and the
--- layout of the current input source.
--- @param deps table|nil
--- @return table { index, source, error, installed, provided, busy, active, record_error }
function M.snapshot(deps)
	local resolved = resolve_deps(deps)
	local snapshot = {
		index = _catalogue.index,
		source = _catalogue.source,
		error = _catalogue.error,
		installed = {},
		provided = {},
		busy = _busy,
		active = "",
		platform = PLATFORM,
	}
	if not resolved then return snapshot end
	deps = resolved
	if snapshot.index == nil then
		-- Before the first refresh the page lists the index shipped with the
		-- app, and says so rather than "no catalogue".
		snapshot.index = bundled_index(deps)
		if snapshot.index ~= nil then snapshot.source = Catalogue.SOURCE_BUNDLED end
	end
	local record, record_err = read_installed(deps)
	if not record then
		snapshot.record_error = record_err
		Logger.error(LOG, "The installed-layouts record is unusable: %s.", tostring(record_err))
		record = Catalogue.empty_installed()
	end
	for _, entry in ipairs(Catalogue.installed_list(record)) do
		if deps.exists(deps.layouts_dir .. entry.id .. ".keylayout") then
			snapshot.installed[entry.id] = entry
		end
	end
	local provided = bundle_names(deps)
	local names = {}
	for _, entry in ipairs(type(snapshot.index) == "table" and snapshot.index.layouts or {}) do
		if type(entry.keyboard_name) == "string" then
			names[entry.keyboard_name] = entry.id
			if provided[entry.keyboard_name] then snapshot.provided[entry.id] = "bundle" end
		end
	end
	for _, entry in pairs(snapshot.installed) do
		if type(entry.keyboard_name) == "string" then names[entry.keyboard_name] = entry.id end
	end
	local ok, records = pcall(deps.active_sources)
	for _, source in ipairs(ok and type(records) == "table" and records or {}) do
		if source.selected and names[source.id] then snapshot.active = names[source.id] end
	end
	return snapshot
end





-- ======================================
-- ======================================
-- ======= 5/ Install / uninstall =======
-- ======================================
-- ======================================

--- Takes the one operation slot, or refuses.
--- @param id string
--- @param action string
--- @param on_done function
--- @return boolean acquired
local function acquire_slot(id, action, on_done)
	if _busy then
		Logger.warn(LOG, "Refused to %s '%s': '%s' is still being %sed.", action, id, _busy.id, _busy.action)
		on_done(false, M.FAILURE_BUSY, "another layout operation is still running")
		return false
	end
	_busy = { id = id, action = action }
	return true
end

--- Publishes a verified layout: the local copy, the installed file, the record.
--- @param deps table
--- @param entry table
--- @param text string
--- @return string|nil installed_path
--- @return string|nil failure_code
--- @return string|nil detail
local function publish(deps, entry, text)
	local installed_path = deps.layouts_dir .. entry.id .. ".keylayout"
	for _, step in ipairs({
		{ deps.local_dir .. entry.id .. ".keylayout", text },
		{ installed_path, text },
	}) do
		local ok, err = write_file(deps, step[1], step[2])
		if not ok then return nil, M.FAILURE_WRITE, err end
	end
	local record, record_err = read_installed(deps)
	if not record then return nil, M.FAILURE_RECORD, record_err end
	local ok, err = write_installed(deps, Catalogue.with_installed(record, entry))
	if not ok then return nil, M.FAILURE_RECORD, err end
	return installed_path, nil, nil
end

--- Installs (or updates) one registry layout and adds it to the input sources.
--- on_done(true, { entry, path, source, enabled }) or
--- on_done(false, failure_code, detail) is called exactly once.
--- @param id string Registry id.
--- @param on_done function
--- @param deps table|nil
--- @return boolean dispatched
function M.install(id, on_done, deps)
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then
		Logger.error(LOG, "The layout registry is unusable: %s.", tostring(deps_err))
		on_done(false, M.FAILURE_DOWNLOAD, deps_err)
		return false
	end
	deps = resolved
	if not Registry.is_valid_id(id) then
		on_done(false, M.FAILURE_UNKNOWN_LAYOUT, "'" .. tostring(id) .. "' is not a registry layout id")
		return false
	end
	if not acquire_slot(id, "install", on_done) then return false end
	local function finish(ok, code_or_detail, detail)
		_busy = nil
		if ok then
			Logger.success(LOG, "Installed the '%s' layout, version %s, from the %s copy.", id,
				tostring(code_or_detail.entry.version), code_or_detail.source)
		else
			Logger.error(LOG, "The '%s' layout was not installed (%s): %s.", id, tostring(code_or_detail),
				tostring(detail))
		end
		on_done(ok, code_or_detail, detail)
	end
	Logger.start(LOG, "Installing the '%s' layout…", id)
	-- The record is read before anything is written: a layout it cannot record
	-- would stay in the layouts folder as a file ErgoptiPlus refuses as foreign.
	local record, record_err = read_installed(deps)
	if not record then
		finish(false, M.FAILURE_RECORD, record_err)
		return false
	end
	M.refresh(function(outcome)
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
			finish(false, M.FAILURE_UNSUPPORTED, "the layout '" .. id .. "' is not published for macOS")
			return
		end
		-- A file of that name the user put there is theirs: never overwritten.
		if deps.exists(deps.layouts_dir .. id .. ".keylayout") and not record.layouts[id] then
			finish(false, M.FAILURE_FOREIGN_FILE, deps.layouts_dir .. id .. ".keylayout was not installed by ErgoptiPlus")
			return
		end
		if type(entry.keyboard_name) == "string" and bundle_names(deps)[entry.keyboard_name] then
			finish(false, M.FAILURE_PROVIDED_BY_BUNDLE, "an installed Ergopti bundle already provides "
				.. entry.keyboard_name)
			return
		end
		Catalogue.acquire(deps.settings, entry, {
			bundled_index = bundled_index(deps),
			read_bundled = function(rel)
				return type(deps.bundled_dir) == "string" and deps.read(deps.bundled_dir .. rel) or nil
			end,
			transport = deps.transport,
		}, function(ok, detail)
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
			local path, code, publish_err = publish(deps, entry, detail.text)
			if not path then
				finish(false, code, publish_err)
				return
			end
			deps.enable_source(path, entry.name, function(enabled, _output, reason)
				if not enabled then
					-- The layout is installed; only the enabled list could not be
					-- updated. System Settings can still add it by hand.
					Logger.warn(LOG, "The '%s' layout is installed but not enabled: %s.", id, tostring(reason))
				end
				finish(true, { entry = entry, path = path, source = detail.source, enabled = enabled == true })
			end)
		end)
	end, deps)
	return true
end

--- Uninstalls one registry layout: removes it from the enabled input sources,
--- then deletes the installed file, the local copy and its record.
--- on_done(true, { id, disabled }) or on_done(false, failure_code, detail) is
--- called exactly once.
--- @param id string
--- @param on_done function
--- @param deps table|nil
--- @return boolean dispatched
function M.uninstall(id, on_done, deps)
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then
		on_done(false, M.FAILURE_RECORD, deps_err)
		return false
	end
	deps = resolved
	local record, record_err = read_installed(deps)
	if not record then
		on_done(false, M.FAILURE_RECORD, record_err)
		return false
	end
	local entry = Registry.is_valid_id(id) and record.layouts[id] or nil
	if not entry then
		on_done(false, M.FAILURE_NOT_INSTALLED, "the layout '" .. tostring(id) .. "' was not installed here")
		return false
	end
	if not acquire_slot(id, "uninstall", on_done) then return false end
	Logger.start(LOG, "Uninstalling the '%s' layout…", id)
	deps.disable_source(entry.keyboard_name, entry.name, function(disabled, _output, reason)
		if not disabled then
			-- Removing the file still takes the layout away; a stale enabled
			-- entry only lingers until macOS rereads its input sources.
			Logger.warn(LOG, "The '%s' layout could not be removed from the input sources: %s.", id,
				tostring(reason))
		end
		for _, path in ipairs({ deps.layouts_dir .. id .. ".keylayout", deps.local_dir .. id .. ".keylayout" }) do
			if not deps.delete(path) then
				_busy = nil
				Logger.error(LOG, "The '%s' layout was not uninstalled: cannot delete %s.", id, path)
				on_done(false, M.FAILURE_WRITE, "cannot delete " .. path)
				return
			end
		end
		local current, current_err = read_installed(deps)
		local ok, err = false, current_err
		if current then ok, err = write_installed(deps, Catalogue.without_installed(current, id)) end
		_busy = nil
		if not ok then
			Logger.error(LOG, "The '%s' layout files are removed but its record is not: %s.", id, tostring(err))
			on_done(false, M.FAILURE_RECORD, err)
			return
		end
		Logger.success(LOG, "Uninstalled the '%s' layout.", id)
		on_done(true, { id = id, disabled = disabled == true })
	end)
	return true
end

--- Makes one installed registry layout the current input source.
--- on_done(true, { id }) or on_done(false, failure_code, detail) is called
--- exactly once.
--- @param id string
--- @param on_done function
--- @param deps table|nil
--- @return boolean dispatched
function M.select(id, on_done, deps)
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then
		on_done(false, M.FAILURE_SELECT, deps_err)
		return false
	end
	deps = resolved
	local record, record_err = read_installed(deps)
	local entry = record and Registry.is_valid_id(id) and record.layouts[id] or nil
	if not entry then
		on_done(false, M.FAILURE_NOT_INSTALLED, record_err or ("the layout '" .. tostring(id) .. "' is not installed"))
		return false
	end
	Logger.start(LOG, "Selecting the '%s' layout…", id)
	return deps.select_source(entry.keyboard_name, entry.keyboard_name, function(ok, _output, reason)
		if not ok then
			Logger.error(LOG, "The '%s' layout could not be selected: %s.", id, tostring(reason))
			on_done(false, M.FAILURE_SELECT, tostring(reason))
			return
		end
		Logger.success(LOG, "Selected the '%s' layout.", id)
		on_done(true, { id = id })
	end)
end

--- Test seam: forgets the catalogue, the operation slot and the shipped index.
function M._reset()
	_catalogue = { index = nil, source = Catalogue.SOURCE_NONE, error = nil }
	_busy = nil
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

--- The extension root of the Ergopti family the app ships, installed by shipping.
--- @param deps table|nil Optional filesystem collaborators.
--- @return table|nil { pack = dir } scanner root; nil when the registry is not shipped.
function M.shipped_extension_root(deps)
	local resolved, reason = resolve_deps(deps)
	if not resolved then error(reason, 0) end
	local root = Extension.shipped_root(resolved.bundled_dir, resolved.settings, resolved.exists)
	if root == nil then
		Logger.warn(LOG, "No shipped Ergopti extension: the app ships no layout registry.")
	end
	return root
end

return M
