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
--- 1. The catalogue decisions are shared with Linux (_shared/layouts/engine/
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

local Logger       = require("core.logger.engine.logger")
local Paths        = require("core.fs.engine.paths")
local ConfigPaths  = require("infra.config_paths")
local FileSystem   = require("core.fs.adapters.file_system")
local HttpClient   = require("adapters.http_client")
local Crypto       = require("core.crypto.crypto")
local Json         = require("core.text.engine.json")
local TomlCodec    = require("core.text.engine.toml_codec")
local Registry     = require("layouts.engine.registry.registry_core")
local Catalogue    = require("layouts.engine.composer.catalogue")
local Extension    = require("layouts.engine.composer.extension")
local Composer     = require("layouts.engine.composer.composer")
local SourceStore  = require("layouts.engine.composer.source_store")
local RegistryStore = require("layouts.engine.registry.store")

local M = {}

local LOG = "layout_registry"

-- Folder macOS reads the current user's keyboard layouts from.
local USER_LAYOUTS_DIR = "~/Library/Keyboard Layouts"

-- The git a clone run asks for its registry changes. /usr/bin/git is on every
-- macOS (the Xcode command line tools shim); a clone was made with a git.
local GIT = "/usr/bin/git"

-- Stable failure codes the layout manager translates.
M.FAILURE_BUSY = "busy"
M.FAILURE_UNKNOWN_LAYOUT = "unknown_layout"
M.FAILURE_NOT_INSTALLED = "not_installed"
M.FAILURE_PROVIDED_BY_BUNDLE = "provided_by_bundle"
M.FAILURE_BUNDLE_SCAN = "bundle_scan_failed"
M.FAILURE_FOREIGN_FILE = "foreign_file"
M.FAILURE_UNSUPPORTED = "unsupported_platform"
M.FAILURE_DOWNLOAD = "download_failed"
M.FAILURE_WRITE = "write_failed"
M.FAILURE_RECORD = "record_failed"
M.FAILURE_SELECT = "select_failed"
M.FAILURE_INVALID = Composer.FAILURE_INVALID

-- The closed reason of a layout the enabled-sources preference lists but macOS
-- turns on only at the next login (logged as not_enabled:<reason>).
M.REASON_REQUIRES_LOGOUT = "macos_requires_logout"

-- The platform name registry entries list when macOS can install them.
local PLATFORM = "macos"





-- ===========================
-- ===========================
-- ======= 1/ State ==========
-- ===========================
-- ===========================

-- The one operation in flight ({ id, action }), nil when idle: an installation
-- and an uninstallation of the same layout must never interleave their writes.
local _busy = nil
local _file_cleanup = {}

local function settle_file_cleanup()
	while #_file_cleanup > 0 do
		local called, settled = pcall(_file_cleanup[1])
		if not called or settled ~= true then return false end
		table.remove(_file_cleanup, 1)
	end
	return true
end

local function retain_file_cleanup(retry)
	if type(retry) == "function" then _file_cleanup[#_file_cleanup + 1] = retry end
end

-- Catalogue, shipped index, installed record and refresh, shared with Linux.
local Store = RegistryStore.new({
	logger = Logger,
	log = LOG,
	shipped_noun = "app",
	prepare_parent = function(deps, path)
		local prepared, prepare_err = deps.prepare_parent(path)
		if prepared then return true, nil end
		return false, "cannot create the folder of " .. path .. ": " .. tostring(prepare_err)
	end,
})
local write_file, bundled_index = Store.write_file, Store.bundled_index
local read_installed, write_installed = Store.read_installed, Store.write_installed




-- ================================
-- ================================
-- ======= 2/ Settings ============
-- ================================
-- ================================

-- The last decode of each shared JSON file, with the exact text it came from:
-- the settings are resolved for every registry call (twice per keyboard-layout
-- menu rebuild), and identical bytes decode to the identical, read-only value.
local _shared_json = {}

--- Reads and decodes one shared JSON file.
--- @param rel string Path under _shared/.
--- @return table|nil value
--- @return string|nil error
local function read_shared_json(rel)
	local path = Paths.shared(rel)
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	if type(raw) ~= "string" then return nil, "_shared/" .. rel .. " is unreadable" end
	local known = _shared_json[path]
	if known ~= nil and known.raw == raw then return known.decoded, nil end
	-- The shared core/text/engine/json.lua answers nil to invalid JSON rather than raising.
	local ok, decoded = pcall(Json.decode, raw)
	if not ok or type(decoded) ~= "table" then return nil, "_shared/" .. rel .. " is not valid JSON" end
	_shared_json[path] = { raw = raw, decoded = decoded }
	return decoded, nil
end

--- The registry settings, resolved from the shared defaults.
--- @return table|nil settings
--- @return string|nil error
function M.settings()
	local layouts, layouts_err = read_shared_json("layouts/data/defaults.json")
	if not layouts then return nil, layouts_err end
	local updater, updater_err = read_shared_json("updater/data/defaults.json")
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
		-- An asynchronous task (ShellRunner.run), never a blocking shell call: the refresh
		-- runs on the main thread that also delivers the keys.
		registry_changes = function(dir, callback)
			require("adapters.shell_runner").run(GIT, Catalogue.registry_changes_args(dir), function(ok, out, stderr)
				if ok then
					callback(out or "", nil)
				else
					local detail = type(stderr) == "string" and stderr:gsub("%s+$", "") or ""
					callback(nil, detail ~= "" and detail or "git did not run")
				end
			end)
		end,
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
		read_bounded = FileSystem.read_bounded,
		write = FileSystem.write,
		create = FileSystem.create_if_absent,
		inspect_file = FileSystem.classify_no_follow,
		read_status = FileSystem.read_with_status,
		digest = Crypto.sha256_bytes,
		replace_exact = FileSystem.write_if_unchanged,
		remove_exact = FileSystem.remove_if_unchanged,
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
		confirm_source = InputSources.confirm_enabled_async,
		pending = require("modules.keymap.pending_layout_activation"),
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

--- Keyboard names the installed Ergopti bundles already provide.
--- @param deps table
--- @return table|nil Set { [name] = true }, or nil on listing failure.
local function bundle_names(deps)
	local ok, names = pcall(deps.bundle_names)
	if not ok or type(names) ~= "table" then
		Logger.warn(LOG, "The installed Ergopti bundles could not be listed: %s.", tostring(names))
		return nil
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
	Store.refresh(deps, nil, on_done)
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

--- Registers an exact declared input-source name, retaining collision evidence.
--- @param names table
--- @param name string|nil
--- @param id string
local function add_source_name(names, name, id)
	if type(name) ~= "string" or name == "" then return end
	if names[name] == nil then names[name] = id
	elseif names[name] ~= id then names[name] = false end
end

--- Finds an active owner without choosing an arbitrary display-name collision.
--- Raw identifiers have precedence over localized aliases. The latter come
--- only from declared catalogue names and the existing input-source formatter.
--- @param source table
--- @param names table Exact internal identifiers.
--- @param aliases table Declared localized names.
--- @return string|boolean|nil owner False means ambiguous ownership.
local function active_source_owner(source, names, aliases)
	if names[source.id] ~= nil then return names[source.id] end
	if names[source.name] ~= nil then return names[source.name] end
	local id_owner, name_owner = aliases[source.id], aliases[source.name]
	if id_owner ~= nil and name_owner ~= nil and id_owner ~= name_owner then return false end
	if id_owner ~= nil then return id_owner end
	return name_owner
end

--- What the layout manager shows: the last catalogue, the installed layouts,
--- the ones an Ergopti bundle provides, the operation in flight and the
--- layout of the current input source.
--- @param deps table|nil
--- @return table { index, source, error, installed, provided, busy, active, active_error, record_error }
function M.snapshot(deps)
	local resolved = resolve_deps(deps)
	local snapshot = {
		index = Store.catalogue().index,
		source = Store.catalogue().source,
		error = Store.catalogue().error,
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
	local provided = bundle_names(deps) or {}
	local names, aliases = {}, {}
	local InputSources = require("modules.keymap.input_sources")
	--- Registers metadata aliases before the nonblocking TIS cache is populated.
	--- @param entry table
	local function register_source(entry)
		add_source_name(names, entry.keyboard_name, entry.id)
		add_source_name(aliases, entry.name, entry.id)
		add_source_name(aliases, InputSources.format_ergopti_display(entry.keyboard_name), entry.id)
	end
	for _, entry in ipairs(type(snapshot.index) == "table" and snapshot.index.layouts or {}) do
		register_source(entry)
		if provided[entry.keyboard_name] then snapshot.provided[entry.id] = "bundle" end
	end
	for _, entry in pairs(snapshot.installed) do register_source(entry) end
	local ok, records = pcall(deps.active_sources)
	for _, source in ipairs(ok and type(records) == "table" and records or {}) do
		if source.selected then
			local owner = active_source_owner(source, names, aliases)
			if owner == false or (owner ~= nil and snapshot.active ~= "" and snapshot.active ~= owner) then
				snapshot.active_error = "ambiguous_input_source"
			elseif owner ~= nil then snapshot.active = owner end
		end
	end
	if snapshot.active_error then snapshot.active = "" end
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
	local owner = { id = id, action = action }
	_busy = owner
	if not settle_file_cleanup() then
		if _busy == owner then _busy = nil end
		on_done(false, M.FAILURE_WRITE, "a previous layout file cleanup remains pending")
		return false
	end
	return true
end

--- Capture both registered copies before a mutation. The digest proves only
--- their bytes, not who owns the inode; the native conditional operations
--- recheck those bytes under the cooperative writer lock.
local function capture_registered_files(deps, entry, verified_candidate)
	if type(deps.inspect_file) ~= "function" or type(deps.read_status) ~= "function"
		or type(deps.digest) ~= "function" then
		return nil, "classified layout verification is unavailable"
	end
	local checksum_valid = type(entry.sha256) == "string" and entry.sha256:match("^%x+$") ~= nil and #entry.sha256 == 64
	local copies = {}
	for _, path in ipairs({ deps.local_dir .. entry.id .. ".keylayout", deps.layouts_dir .. entry.id .. ".keylayout" }) do
		local attrs, status = deps.inspect_file(path)
		if status == "absent" then
			copies[path] = { status = "absent" }
		elseif status == "ok" and type(attrs) == "table" and attrs.mode == "file" then
			local content, read_status = deps.read_status(path)
			local is_candidate = type(verified_candidate) == "string" and content == verified_candidate
			if not checksum_valid and not is_candidate then return nil, "the installed layout has no usable checksum" end
			local digest = not is_candidate and type(content) == "string" and deps.digest(content) or nil
			if read_status ~= "ok" or (not is_candidate and (type(digest) ~= "string" or digest:lower() ~= entry.sha256:lower())) then
				return nil, "the installed layout was changed or cannot be read: " .. path
			end
			copies[path] = { status = "ok", content = content }
		else
			return nil, "the installed layout is not an inspectable regular file: " .. path
		end
	end
	return copies
end

--- What an installed layout's enable came to, read from a fresh process. The
--- macOS 26 field probe (v5) showed that writing the enabled-sources
--- preference turns a layout on at once, but only a process started after the
--- write sees it: Hammerspoon's own list stays stale. A layout the fresh process
--- does not see on is the fallback: pending until the next login. An
--- update re-registers the rewritten file and, when it is selected, selects
--- another layout and back, so the new content applies.
--- @param deps table
--- @param id string Layout id.
--- @param entry table Record entry (keyboard_name).
--- @param path string Installed .keylayout path.
--- @param listed boolean Whether the enable wrote the preference.
--- @param reason string|nil The enable's failure reason.
--- @param update boolean Whether this replaced an installed copy.
--- @param callback function fn(state): { enabled, pending_activation, consent, reason }.
local function settle_enable(deps, id, entry, path, listed, reason, update, callback)
	if not listed then
		-- The layout is installed; only the enabled list could not be updated.
		-- System Settings can still add it by hand.
		Logger.warn(LOG, "The '%s' layout is installed but not enabled: %s.", id, tostring(reason))
		callback({ enabled = false, pending_activation = false, consent = false, reason = reason })
		return
	end
	local dispatched = deps.confirm_source(entry.keyboard_name, { register_path = path, refresh = update },
		function(read, state, read_reason)
			if not read then
				Logger.error(LOG, "The '%s' layout is listed in the enabled sources, but whether macOS turned it on cannot be read: %s.",
					id, tostring(read_reason))
				callback({ enabled = false, pending_activation = false, consent = false, reason = read_reason })
				return
			end
			if state.enabled == true then
				deps.pending.forget(id)
				Logger.info(LOG, "macOS turned the '%s' layout on (%s).", id, tostring(state.id))
				-- macOS asks the user to allow a keyboard it has not seen before.
				callback({ enabled = true, pending_activation = false, consent = not update })
				return
			end
			if deps.pending.record(id, entry.keyboard_name) ~= true then
				Logger.error(LOG, "The '%s' layout is installed but its pending activation could not be confirmed.", id)
				callback({ enabled = false, pending_activation = false, consent = false, reason = "pending_record_failed" })
				return
			end
			Logger.warn(LOG, "The '%s' layout is installed and listed in the enabled sources, but a fresh process does not see it on (listed=%s); macOS turns it on at the next login (reason=not_enabled:%s).",
				id, tostring(state.listed), M.REASON_REQUIRES_LOGOUT)
			callback({ enabled = false, pending_activation = true, consent = false, reason = M.REASON_REQUIRES_LOGOUT })
		end)
	if dispatched ~= true then
		Logger.warn(LOG, "The state of the '%s' layout was not read: the fresh-process read did not start.", id)
	end
end

--- Publishes a verified layout: the local copy, the installed file, the record.
--- @param deps table
--- @param entry table
--- @param text string
--- @param previous table|nil Previously registered entry for this id.
--- @return string|nil installed_path
--- @return string|nil failure_code
--- @return string|nil detail
local function publish_update(deps, entry, text, previous)
	if type(deps.replace_exact) ~= "function" or type(deps.remove_exact) ~= "function"
		or type(deps.inspect_file) ~= "function" or type(deps.read_status) ~= "function" then
		return nil, M.FAILURE_WRITE, "conditional layout publication is unavailable"
	end
	local record_path = deps.local_dir .. deps.settings.installed_file
	local attrs, record_status = deps.inspect_file(record_path)
	if record_status ~= "ok" or type(attrs) ~= "table" or attrs.mode ~= "file" then
		return nil, M.FAILURE_RECORD, "the installed layout record is not a regular file"
	end
	local raw, read_status = deps.read_status(record_path)
	if read_status ~= "ok" or type(raw) ~= "string" then
		return nil, M.FAILURE_RECORD, "the installed layout record cannot be read"
	end
	local current, record_err = Catalogue.decode_installed(raw, deps.decode_installed_json or Json.decode_lossless)
	local registered = current and current.layouts[entry.id]
	if not registered or registered.sha256 ~= previous.sha256 or registered.version ~= previous.version then
		return nil, M.FAILURE_RECORD, record_err or "the installed layout record changed"
	end
	local copies, capture_err = capture_registered_files(deps, registered, text)
	if not copies then return nil, M.FAILURE_FOREIGN_FILE, capture_err end
	local local_path = deps.local_dir .. entry.id .. ".keylayout"
	local installed_path = deps.layouts_dir .. entry.id .. ".keylayout"
	local encoded_ok, encoded = pcall(function() return deps.encode_json(Catalogue.with_installed(current, entry)) end)
	if not encoded_ok or type(encoded) ~= "string" then return nil, M.FAILURE_RECORD, "cannot encode the installed layout record" end
	local loaded, inverse_module = pcall(require, "settings.engine.migration.file_inverse")
	local factory = loaded and type(inverse_module) == "table" and inverse_module.for_current_writer or nil
	if type(factory) ~= "function" then return nil, M.FAILURE_WRITE, "layout compensation owner is unavailable" end
	local built, inverse, writer = pcall(factory)
	if not built or type(inverse) ~= "table" or type(writer) ~= "table"
		or type(inverse.restore) ~= "function" or type(inverse.settle_publication) ~= "function"
		or type(writer.publish_if_unchanged) ~= "function" or type(writer.read_classified) ~= "function"
		or type(writer.remove_if_unchanged) ~= "function" or type(writer.retry_publication_cleanup) ~= "function" then
		return nil, M.FAILURE_WRITE, "layout compensation owner is unavailable"
	end
	local publish_exact, read_classified = writer.publish_if_unchanged, writer.read_classified
	local remove_conditional, settle_publication = writer.remove_if_unchanged, writer.retry_publication_cleanup
	local restore, settle_inverse = inverse.restore, inverse.settle_publication
	local inspect, read, replace, remove = deps.inspect_file, deps.read_status, deps.replace_exact, deps.remove_exact
	local files = { read_with_status = read, remove_if_unchanged = remove }
	files.write_if_unchanged = function(path, content, expected, on_error)
		local observed, status = inspect(path)
		if expected.status == "absent" then
			if status ~= "absent" then return false, "layout path is no longer absent" end
		elseif status ~= "ok" or type(observed) ~= "table" or observed.mode ~= "file" then
			return false, "layout path is no longer a regular file"
		end
		return replace(path, content, expected, on_error)
	end
	local function current_owner()
		return rawequal(package.loaded["settings.engine.migration.file_inverse"], inverse_module)
			and rawequal(inverse_module.for_current_writer, factory)
			and rawequal(package.loaded["core.text.engine.toml_codec.writer"], writer)
			and rawequal(writer.publish_if_unchanged, publish_exact)
			and rawequal(writer.read_classified, read_classified)
			and rawequal(writer.remove_if_unchanged, remove_conditional)
			and rawequal(writer.retry_publication_cleanup, settle_publication)
			and rawequal(inverse.restore, restore)
			and rawequal(inverse.settle_publication, settle_inverse)
			and rawequal(deps.inspect_file, inspect) and rawequal(deps.read_status, read)
			and rawequal(deps.replace_exact, replace) and rawequal(deps.remove_exact, remove)
	end
	local effects = {}
	local function rollback()
		if not current_owner() then return false end
		for index = #effects, 1, -1 do
			if not current_owner() or restore(effects[index], files) ~= true then return false end
			table.remove(effects, index)
		end
		return true
	end
	local function retry_rollback()
		local called, settled = pcall(rollback)
		return called and settled == true
	end
	local function fail(code, detail)
		if #effects == 0 then return nil, code, detail end
		if not retry_rollback() then
			retain_file_cleanup(retry_rollback)
			return nil, code, tostring(detail) .. "; conditional rollback remains pending"
		end
		return nil, code, detail
	end
	for _, step in ipairs({ { local_path, text, copies[local_path], M.FAILURE_WRITE },
		{ installed_path, text, copies[installed_path], M.FAILURE_WRITE },
		{ record_path, encoded, { status = "ok", content = raw }, M.FAILURE_RECORD } }) do
		local source = { status = step[3].status, content = step[3].content }
		local effect = { path = step[1], source = source, candidate = step[2] }
		if not current_owner() then return fail(step[4], "layout publication owner changed") end
		local called, written, detail, receipt = pcall(publish_exact, step[1], step[2], files, source)
		if not called then detail, written, receipt = tostring(written), false, nil end
		if written ~= true then
			if type(receipt) == "function" then
				effect.publication_cleanup = receipt
				effects[#effects + 1] = effect
			else
				-- Without a receipt, only an unchanged source proves this step had
				-- no visible effect. Preserve earlier candidates when the outcome
				-- is unknown, so a retry of the same verified candidate can join it.
				local checked, unchanged = pcall(function()
					local observed, status = inspect(step[1])
					if source.status == "absent" then return status == "absent" end
					if status ~= "ok" or type(observed) ~= "table" or observed.mode ~= "file" then return false end
					local bytes, read_status = read(step[1])
					return read_status == "ok" and bytes == source.content
				end)
				if not checked or not unchanged then
					return nil, step[4], tostring(detail) .. "; publication was not confirmed at " .. step[1]
						.. "; inspect retained layout copies at " .. local_path .. " and " .. installed_path
				end
			end
			return fail(step[4], detail)
		end
		effects[#effects + 1] = effect
	end
	return installed_path, nil, nil
end

local function publish(deps, entry, text, previous)
	if previous ~= nil then return publish_update(deps, entry, text, previous) end
	local installed_path = deps.layouts_dir .. entry.id .. ".keylayout"
	local created_paths = {}
	local function retained(detail)
		if #created_paths == 0 then return tostring(detail) end
		return tostring(detail) .. "; created copies retained at " .. table.concat(created_paths, ", ")
	end
	if previous == nil and type(deps.create) ~= "function" then
		return nil, M.FAILURE_WRITE, "exclusive layout creation is unavailable"
	end
	for _, step in ipairs({
		{ deps.local_dir .. entry.id .. ".keylayout", text },
		{ installed_path, text },
	}) do
		if previous == nil then
			local prepared, prepare_err = deps.prepare_parent(step[1])
			if not prepared then return nil, M.FAILURE_WRITE, retained(prepare_err) end
			local created, status, detail = deps.create(step[1], step[2])
			if created ~= true then
				local code = status == "exists" and M.FAILURE_FOREIGN_FILE or M.FAILURE_WRITE
				return nil, code, retained("cannot create " .. step[1] .. ": " .. tostring(detail or status))
			end
			created_paths[#created_paths + 1] = step[1]
		else
			local ok, err = write_file(deps, step[1], step[2])
			if not ok then return nil, M.FAILURE_WRITE, err end
		end
	end
	local record, record_err = read_installed(deps)
	if not record then return nil, M.FAILURE_RECORD, retained(record_err) end
	local ok, err = write_installed(deps, Catalogue.with_installed(record, entry))
	if not ok then return nil, M.FAILURE_RECORD, retained(err) end
	return installed_path, nil, nil
end

--- Installs (or updates) one registry layout and adds it to the input sources.
--- on_done(true, { entry, path, source, enabled, pending_activation, consent }) or
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
		local provided = bundle_names(deps)
		if not provided then
			finish(false, M.FAILURE_BUNDLE_SCAN, "installed keyboard bundles could not be listed")
			return
		end
		if type(entry.keyboard_name) == "string" and provided[entry.keyboard_name] then
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
			if record.layouts[id] then
				local copies, capture_err = capture_registered_files(deps, record.layouts[id], detail.text)
				if not copies then finish(false, M.FAILURE_FOREIGN_FILE, capture_err); return end
			end
			if entry.extension ~= nil then
				local staged, stage_err = Extension.stage(deps.local_dir, entry, detail.content, {
					read = deps.read, write = function(path, text) return write_file(deps, path, text) end,
				})
				if not staged then finish(false, M.FAILURE_WRITE, stage_err) return end
			end
			local path, code, publish_err = publish(deps, entry, detail.text, record.layouts[id])
			if not path then
				finish(false, code, publish_err)
				return
			end
			deps.enable_source(path, entry.name, function(listed, _output, reason)
				settle_enable(deps, id, entry, path, listed == true, reason, record.layouts[id] ~= nil, function(state)
					finish(true, { entry = entry, path = path, source = detail.source, enabled = state.enabled,
						pending_activation = state.pending_activation, consent = state.consent, reason = state.reason })
				end)
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
	if not acquire_slot(id, "uninstall", on_done) then return false end
	local record, record_err = read_installed(deps)
	if not record then
		_busy = nil
		on_done(false, M.FAILURE_RECORD, record_err)
		return false
	end
	local entry = Registry.is_valid_id(id) and record.layouts[id] or nil
	if not entry then
		_busy = nil
		on_done(false, M.FAILURE_NOT_INSTALLED, "the layout '" .. tostring(id) .. "' was not installed here")
		return false
	end
	local copies, capture_err = capture_registered_files(deps, entry)
	if not copies then
		_busy = nil
		on_done(false, M.FAILURE_FOREIGN_FILE, capture_err)
		return false
	end
	if type(deps.remove_exact) ~= "function" then
		_busy = nil
		on_done(false, M.FAILURE_WRITE, "conditional layout removal is unavailable")
		return false
	end
	Logger.start(LOG, "Uninstalling the '%s' layout…", id)
	deps.disable_source(entry.keyboard_name, entry.name, function(disabled, _output, reason)
		if not disabled then
			-- Removing the file still takes the layout away; a stale enabled
			-- entry only lingers until macOS rereads its input sources.
			Logger.warn(LOG, "The '%s' layout could not be removed from the input sources: %s.", id,
				tostring(reason))
		end
		for path, expected in pairs(copies) do
			if expected.status == "absent" then
				local _, status = deps.inspect_file(path)
				if status ~= "absent" then
					_busy = nil
					on_done(false, M.FAILURE_FOREIGN_FILE, "a previously absent layout path is no longer absent: " .. path)
					return
				end
			end
		end
		for _, path in ipairs({ deps.layouts_dir .. id .. ".keylayout", deps.local_dir .. id .. ".keylayout" }) do
			local expected = copies[path]
			local removed, remove_err, _, retry = true, nil, nil, nil
			if expected.status == "ok" then removed, remove_err, _, retry = deps.remove_exact(path, expected) end
			if removed ~= true then
				retain_file_cleanup(retry)
				_busy = nil
				Logger.error(LOG, "The '%s' layout was not uninstalled: cannot delete %s.", id, path)
				on_done(false, M.FAILURE_WRITE, "removal not confirmed for " .. path .. "; the file may have been removed: "
					.. tostring(remove_err))
				return
			end
		end
		for path in pairs(copies) do
			local _, status = deps.inspect_file(path)
			if status ~= "absent" then
				_busy = nil
				on_done(false, M.FAILURE_FOREIGN_FILE, "layout removal could not be confirmed at " .. path)
				return
			end
		end
		deps.pending.forget(id)
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




-- ====================================
-- ====================================
-- ======= 6/ Composed layout =========
-- ====================================
-- ====================================

--- Installs the layout the user composed (docs/design/layout-composer.md): no catalogue
--- and no download, the caller built the entry from the compiled file. The copy
--- is published and enabled exactly like a registry layout's.
--- on_done(true, { entry, path, source, enabled, pending_activation, consent }) or
--- on_done(false, failure_code, detail) is called exactly once.
--- @param entry table Record entry of the composition.
--- @param text string The compiled .keylayout.
--- @param on_done function
--- @param deps table|nil
--- @return boolean dispatched
function M.install_local(entry, text, on_done, deps)
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then
		on_done(false, M.FAILURE_WRITE, deps_err)
		return false
	end
	deps = resolved
	local id = type(entry) == "table" and entry.id or nil
	if not Registry.is_valid_id(id) then
		on_done(false, M.FAILURE_UNKNOWN_LAYOUT, "'" .. tostring(id) .. "' is not a layout id")
		return false
	end
	if not acquire_slot(id, "install", on_done) then return false end
	local function finish(ok, code_or_detail, detail)
		_busy = nil
		if ok then
			Logger.success(LOG, "Installed the composed '%s' layout.", id)
		else
			Logger.error(LOG, "The composed '%s' layout was not installed (%s): %s.", id, tostring(code_or_detail),
				tostring(detail))
		end
		on_done(ok, code_or_detail, detail)
	end
	Logger.start(LOG, "Installing the composed '%s' layout…", id)
	local record, record_err = read_installed(deps)
	if not record then
		finish(false, M.FAILURE_RECORD, record_err)
		return false
	end
	if deps.exists(deps.layouts_dir .. id .. ".keylayout") and not record.layouts[id] then
		finish(false, M.FAILURE_FOREIGN_FILE, deps.layouts_dir .. id .. ".keylayout was not installed by ErgoptiPlus")
		return false
	end
	local provided = bundle_names(deps)
	if not provided then
		finish(false, M.FAILURE_BUNDLE_SCAN, "installed keyboard bundles could not be listed")
		return false
	end
	if type(entry.keyboard_name) == "string" and provided[entry.keyboard_name] then
		finish(false, M.FAILURE_PROVIDED_BY_BUNDLE, "an installed Ergopti bundle already provides "
			.. entry.keyboard_name)
		return false
	end
	deps.transport.sha256(text, function(digest, digest_err)
		local verified, reason = Registry.verify(entry, text, digest)
		if not verified then
			finish(false, M.FAILURE_INVALID, reason or digest_err)
			return
		end
		local path, code, publish_err = publish(deps, entry, text, record.layouts[id])
		if not path then
			finish(false, code, publish_err)
			return
		end
		deps.enable_source(path, entry.name, function(listed, _output, enable_reason)
			settle_enable(deps, id, entry, path, listed == true, enable_reason, record.layouts[id] ~= nil, function(state)
				finish(true, { entry = entry, path = path, source = "composer", enabled = state.enabled,
					pending_activation = state.pending_activation, consent = state.consent, reason = state.reason })
			end)
		end)
	end)
	return true
end

--- The composer's ports over this module (see layouts/engine/composer/composer.lua).
--- @param deps table
--- @return table|nil operations
--- @return string|nil error
local function composer_operations(deps)
	local layout_defaults, defaults_err = read_shared_json("layouts/data/defaults.json")
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
		shortcuts = "full",
		config_dir = deps.config_dir or ConfigPaths.get_config_dir(),
		decode_json = deps.decode_json,
		-- The page may save an Ergopti layout source in place of a composition.
		decode_toml = TomlCodec.decode,
		read = deps.read,
		exists = deps.exists,
		delete = deps.delete,
		write = function(path, content) return write_file(deps, path, content) end,
		sha256 = deps.transport.sha256,
		installed = installed,
		active_id = function() return M.snapshot(deps).active end,
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
		select_after_login = function(id) return deps.pending.request_select(id) end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	})
end

--- The composer's own settings (the reserved id, its folder and bounds).
--- @return table|nil settings
--- @return string|nil error
function M.composer_settings()
	local layout_defaults, defaults_err = read_shared_json("layouts/data/defaults.json")
	if not layout_defaults then return nil, defaults_err end
	return Composer.settings(layout_defaults)
end

--- The emulation table stored with the composed layout's source, for the layout
--- emulation; nil when the composed layout has none.
--- @param deps table|nil
--- @return table|nil table_
--- @return string|nil error
function M.composer_emulation(deps)
	local settings, settings_err = M.composer_settings()
	if not settings then return nil, settings_err end
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then return nil, deps_err end
	return Composer.read_emulation(settings, resolved.config_dir or ConfigPaths.get_config_dir(), resolved)
end

--- The composed layout stored for the emulation alone (composer_emulate), for
--- the layout emulation while the composed layout is not installed.
--- @param deps table|nil
--- @return table|nil composed { text, convention } nil when none is stored.
--- @return string|nil error
function M.composer_copy(deps)
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then return nil, deps_err end
	return Composer.registry_copy((M.composer_settings()), resolved.config_dir or ConfigPaths.get_config_dir(), resolved, TomlCodec.decode)
end

--- The text of an installed layout's copy, for the Debug check of the composer.
--- @param id string Layout id.
--- @param deps table|nil
--- @return string|nil text
--- @return string|nil error
function M.read_local_copy(id, deps)
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then return nil, deps_err end
	local text = resolved.read(resolved.layouts_dir .. id .. ".keylayout")
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
	local resolved, deps_err = resolve_deps(deps)
	local operations, operations_err
	if resolved then operations, operations_err = composer_operations(resolved) end
	if not operations then
		Logger.error(LOG, "The layout composer is unusable: %s.", tostring(deps_err or operations_err))
		return false
	end
	operations.open(on_done)
	return true
end

--- Stores a composition and installs its layout.
--- @param payload table { declaration, keylayout, use }
--- @param on_done function on_done(ok, code, detail, used)
--- @param deps table|nil
--- @return boolean dispatched
function M.composer_save(payload, on_done, deps)
	local resolved, deps_err = resolve_deps(deps)
	local operations, operations_err
	if resolved then operations, operations_err = composer_operations(resolved) end
	if not operations then
		on_done(false, M.FAILURE_WRITE, deps_err or operations_err, false)
		return false
	end
	operations.save(payload, on_done)
	return true
end

--- Stores a layout source for the layout emulation alone: nothing is installed
--- in the system (layouts/engine/composer/composer.lua store).
--- @param payload table { source, keylayout [, emulation] }
--- @param on_done function on_done(ok, code, detail, id)
--- @param deps table|nil
--- @return boolean dispatched
function M.composer_emulate(payload, on_done, deps)
	local resolved, deps_err = resolve_deps(deps)
	local operations, operations_err
	if resolved then operations, operations_err = composer_operations(resolved) end
	if not operations then
		on_done(false, M.FAILURE_WRITE, deps_err or operations_err)
		return false
	end
	operations.store(payload, on_done)
	return true
end

--- Removes the composition.
--- @param on_done function on_done(ok, code, detail)
--- @param deps table|nil
--- @return boolean dispatched
function M.composer_remove(on_done, deps)
	local resolved, deps_err = resolve_deps(deps)
	local operations, operations_err
	if resolved then operations, operations_err = composer_operations(resolved) end
	if not operations then
		on_done(false, M.FAILURE_WRITE, deps_err or operations_err)
		return false
	end
	operations.remove(on_done)
	return true
end

--- The layout editor's file store over this module (see layouts/engine/composer/source_store.lua).
--- @param deps table Resolved collaborators.
--- @return table|nil operations
--- @return string|nil error
local function source_operations(deps)
	local layout_defaults, defaults_err = read_shared_json("layouts/data/defaults.json")
	if not layout_defaults then return nil, defaults_err end
	local settings, settings_err = SourceStore.settings(layout_defaults)
	if not settings then return nil, settings_err end
	return SourceStore.new({
		settings = settings,
		config_dir = deps.config_dir or ConfigPaths.get_config_dir(),
		read = deps.read,
		read_bounded = deps.read_bounded,
		exists = deps.exists,
		write = function(path, content) return write_file(deps, path, content) end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	})
end

--- Runs a layout editor file operation, or refuses it when the store is unusable.
--- @param deps table|nil
--- @param run function run(operations)
--- @param refuse function refuse(detail)
--- @return boolean dispatched
local function with_source(deps, run, refuse)
	local resolved, deps_err = resolve_deps(deps)
	local operations, operations_err
	if resolved then operations, operations_err = source_operations(resolved) end
	if not operations then
		Logger.error(LOG, "The layout editor store is unusable: %s.", tostring(deps_err or operations_err))
		refuse(deps_err or operations_err)
		return false
	end
	run(operations)
	return true
end

--- Sends the layout editor the last source it saved.
--- @param on_done function on_done({ text, filename, folder })
--- @param deps table|nil
--- @return boolean dispatched
function M.source_open(on_done, deps)
	return with_source(deps, function(operations) operations.open(on_done) end,
		function() on_done({}) end)
end

--- Stores one file of the layout editor (its source or an export).
--- @param payload table { filename, text }
--- @param on_done function on_done(ok, code, detail, filename)
--- @param deps table|nil
--- @return boolean dispatched
function M.source_save(payload, on_done, deps)
	return with_source(deps, function(operations) operations.save(payload, on_done) end,
		function(detail) on_done(false, M.FAILURE_WRITE, detail, nil) end)
end

--- The text and index entry of a layout the app ships (the field run's source of
--- the number-row build), read from the shipped registry the offline install uses.
--- @param id string Registry id.
--- @param deps table|nil
--- @return table|nil shipped { entry, text }
--- @return string|nil error
function M.shipped_layout(id, deps)
	local resolved, deps_err = resolve_deps(deps)
	if not resolved then return nil, deps_err end
	local index = bundled_index(resolved)
	for _, entry in ipairs(type(index) == "table" and index.layouts or {}) do
		if entry.id == id then
			local text = type(resolved.bundled_dir) == "string" and resolved.read(resolved.bundled_dir .. entry.file) or nil
			if type(text) ~= "string" then return nil, "the shipped " .. id .. " layout is unreadable" end
			return { entry = entry, text = text }, nil
		end
	end
	return nil, "the app ships no " .. tostring(id) .. " layout"
end

--- Test seam: forgets the catalogue, the operation slot and the shipped index.
function M._reset()
	Store.reset()
	_busy = nil
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
