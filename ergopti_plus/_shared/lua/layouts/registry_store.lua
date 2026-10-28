--- _shared/lua/layouts/registry_store.lua

--- ==============================================================================
--- MODULE: Layout Registry Store (Shared)
--- DESCRIPTION:
--- The state and the local-file steps of the layout manager that the macOS and
--- Linux clients (modules/keymap/layout_registry.lua) run identically: the last
--- catalogue outcome, the index shipped with the package, the installed-layouts
--- record, the cached index with its ETag, and the refresh that ties them to
--- the shared catalogue decisions (catalogue.lua).
---
--- FEATURES & RATIONALE:
--- 1. A factory: each driver builds its own store with its logger, the log
---    namespace, and the one platform step it owns (creating the parent folder
---    of a file), so no module-level state is shared between drivers or tests.
--- 2. Every collaborator reaches the store through `deps` (read, write, delete,
---    exists, encode_json, ...), the table the driver's tests already inject.
--- 3. A driver with a restartable lifetime (Linux) passes a freshness probe to
---    `refresh`; a result that arrives after the lifetime ended neither writes
---    the cache nor replaces the catalogue.
--- ==============================================================================

local Catalogue = require("layouts.catalogue")
local Outdated = require("config_outdated")
local Json = require("json")

local M = {}

local STOPPED = "layout registry stopped"




-- =============================================
-- =============================================
-- ======= 1/ Public API =======================
-- =============================================
-- =============================================

--- Builds one driver's store.
--- @param ports table {
---   logger = table with start, warn, error and success,
---   log = string log namespace,
---   shipped_noun = string what ships the registry folder ("app", "driver"),
---   prepare_parent = function(deps, path) -> boolean, string|nil: creates the
---     folder of a file about to be written, with the error text on failure,
---   missing_bundle_notice = string|nil: warned once when the driver ships no
---     registry folder; nil stays silent. }
--- @return table store
function M.new(ports)
	assert(type(ports) == "table" and type(ports.logger) == "table", "a registry store needs a logger")
	assert(type(ports.log) == "string" and type(ports.shipped_noun) == "string"
		and type(ports.prepare_parent) == "function",
		"a registry store needs a log namespace, a shipped noun and a prepare_parent step")
	local Logger, LOG = ports.logger, ports.log
	local store = {}

	local catalogue = { index = nil, source = Catalogue.SOURCE_NONE, error = nil }
	local bundled = nil
	local bundled_read = false

	--- The last refresh outcome: { index, source, error }.
	--- @return table
	function store.catalogue() return catalogue end

	--- Forgets the catalogue and the shipped index (test seam of the drivers).
	function store.reset()
		catalogue = { index = nil, source = Catalogue.SOURCE_NONE, error = nil }
		bundled = nil
		bundled_read = false
	end

	--- Writes one file, creating its folder first.
	--- @param deps table
	--- @param path string
	--- @param content string
	--- @return boolean ok
	--- @return string|nil error
	function store.write_file(deps, path, content)
		local prepared, prepare_err = ports.prepare_parent(deps, path)
		if not prepared then return false, prepare_err end
		local written, write_err = deps.write(path, content)
		if not written then return false, "cannot write " .. path .. ": " .. tostring(write_err) end
		return true, nil
	end

	--- The shipped index, reread for source checkouts so Refresh sees local edits.
	--- @param deps table
	--- @return table|nil
	function store.bundled_index(deps)
		if deps.bundled_index ~= nil then return deps.bundled_index or nil end
		if bundled_read and not deps.local_source then return bundled end
		bundled_read = true
		if type(deps.bundled_dir) ~= "string" then
			if ports.missing_bundle_notice then Logger.warn(LOG, ports.missing_bundle_notice) end
			return nil
		end
		local text = deps.read(deps.bundled_dir .. deps.settings.index_file)
		local index, _, detail = Catalogue.decode_index(text, deps.decode_json, deps.settings.max_file_bytes)
		if not index then
			Logger.error(LOG, "The layout index shipped with the %s is unusable: %s.", ports.shipped_noun, tostring(detail))
		end
		bundled = index
		return index
	end

	--- Reads the installed-layouts record. An entry this build cannot use is
	--- warned once and left out; the other layouts stay installed.
	--- @param deps table
	--- @return table|nil record
	--- @return string|nil error
	function store.read_installed(deps)
		local path = deps.local_dir .. deps.settings.installed_file
		local decode = deps.decode_installed_json or Json.decode_lossless
		if not deps.exists(path) then return Catalogue.decode_installed(nil, decode) end
		local text = deps.read(path)
		if type(text) ~= "string" then return nil, "cannot read " .. path end
		local record, err = Catalogue.decode_installed(text, decode)
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
	function store.write_installed(deps, record)
		return store.write_file(deps, deps.local_dir .. deps.settings.installed_file, deps.encode_json(record))
	end

	--- Refreshes the catalogue from the registry (a conditional request) and
	--- keeps the outcome. on_done(outcome) is called once; see
	--- Catalogue.resolve_index.
	--- @param deps table Resolved collaborators.
	--- @param is_current function|nil Freshness probe; false drops the result.
	--- @param on_done function|nil
	function store.refresh(deps, is_current, on_done)
		local function current() return is_current == nil or is_current() end
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
				if not current() then return false, STOPPED end
				local ok, err = store.write_file(deps, deps.local_dir .. deps.settings.index_file, text)
				if not ok then return false, err end
				local etag_path = deps.local_dir .. deps.settings.etag_file
				if type(etag) == "string" then return store.write_file(deps, etag_path, etag) end
				if not deps.delete(etag_path) then return false, "cannot remove " .. etag_path end
				return true, nil
			end,
			bundled_index = store.bundled_index(deps),
			decode_json = deps.decode_json,
			transport = deps.transport,
		}, function(outcome)
			if not current() then return end
			catalogue = { index = outcome.index, source = outcome.source, error = outcome.error }
			if outcome.cache_warning then Logger.warn(LOG, "%s; refreshed without it.", outcome.cache_warning) end
			if outcome.error then
				Logger.warn(LOG, "The layout catalogue shows the %s index: %s (%s).", outcome.source,
					outcome.error.code, tostring(outcome.error.detail))
			end
			if outcome.cache_error then Logger.error(LOG, "%s.", outcome.cache_error) end
			Logger.success(LOG, "Layout catalogue refreshed from the %s index.", outcome.source)
			if on_done then on_done(outcome) end
		end)
	end

	return store
end

return M
