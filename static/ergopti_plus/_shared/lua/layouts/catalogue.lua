--- _shared/lua/layouts/catalogue.lua

--- ==============================================================================
--- MODULE: Layout Catalogue (Shared)
--- DESCRIPTION:
--- What the macOS and Linux layout managers decide the same way: which index
--- the catalogue shows after a refresh (fresh, cached, shipped with the app, or
--- none), how the local record of installed layouts is read and written, and
--- where a layout's verified bytes come from (the copy shipped with the app when
--- it is the very file the index describes, the registry otherwise). The
--- Windows driver applies the same rules in
--- modules/keymap/keylayout/layout_catalogue.ahk; both replay the shared
--- vectors of _shared/tests/corpus/layouts/catalogue_vectors.json.
---
--- FEATURES & RATIONALE:
--- 1. PURE Lua: no driver imports, no io/network/OS calls. Reading, writing,
---    the transport, the JSON codec and the digest are injected.
--- 2. Conditional refresh: the cached index's ETag rides along as If-None-Match,
---    so an unchanged registry costs one empty 304 response.
--- 3. Clear error states: a refresh always ends with an index to show when one
---    exists (network, cache, then the copy shipped with the app) AND the exact
---    reason the network one is missing, so an offline machine still lists the
---    layouts it can install while saying why it could not look further.
--- 4. Offline Ergopti: a layout whose shipped copy is the file the index
---    describes is taken from that copy, so installing Ergopti needs no network.
--- ==============================================================================

local Registry = require("layouts.registry")
local Extension = require("layouts.extension")
local Json = require("json")

local M = {}

-- Source-only fields and obsolete rows must not share the public runtime
-- classification table, whose name may itself occur in a future source.
local _installed_sources = setmetatable({}, { __mode = "k" })

--- Version of the installed-layouts record this module reads and writes.
M.INSTALLED_SCHEMA_VERSION = 1

--- Where the index shown by the catalogue comes from.
M.SOURCE_NETWORK = "network"
M.SOURCE_CACHE = "cache"
M.SOURCE_BUNDLED = "bundled"
M.SOURCE_NONE = "none"

--- Why the network index is missing. Stable codes: the pages translate them.
M.ERROR_OFFLINE = "offline"
M.ERROR_HTTP = "http"
M.ERROR_INVALID_INDEX = "invalid_index"
M.ERROR_TOO_LARGE = "too_large"
M.ERROR_NOT_MODIFIED_WITHOUT_CACHE = "not_modified_without_cache"

local HTTP_OK = 200
local HTTP_NOT_MODIFIED = 304





-- =============================
-- =============================
-- ======= 1/ Index ============
-- =============================
-- =============================

--- Whether a decoded value is a usable registry index: a layouts list whose
--- every entry names a valid id, its file, checksum, size and version.
--- @param index any
--- @return boolean ok
--- @return string|nil error
function M.validate_index(index)
	if type(index) ~= "table" or type(index.layouts) ~= "table" then
		return false, "the registry index has no layouts list"
	end
	local seen = {}
	for position, entry in ipairs(index.layouts) do
		if type(entry) ~= "table" or not Registry.is_valid_id(entry.id) then
			return false, "layout " .. position .. " of the registry index has no valid id"
		end
		if seen[entry.id] then return false, "the registry index lists '" .. entry.id .. "' twice" end
		seen[entry.id] = true
		if type(entry.file) ~= "string" or type(entry.sha256) ~= "string"
			or type(entry.size) ~= "number" or type(entry.version) ~= "string" then
			return false, "the registry entry of '" .. entry.id .. "' has no usable file, checksum, size or version"
		end
		if entry.extension ~= nil then
			local valid, reason = Extension.validate(entry)
			if not valid then return false, reason end
		end
	end
	return true, nil
end

--- Decodes and validates an index text.
--- @param text string
--- @param decode_json function decode(text) -> value; may raise or return nil.
--- @param max_bytes number Download bound of the registry.
--- @return table|nil index
--- @return string|nil error_code M.ERROR_TOO_LARGE or M.ERROR_INVALID_INDEX.
--- @return string|nil detail
function M.decode_index(text, decode_json, max_bytes)
	if type(text) ~= "string" then return nil, M.ERROR_INVALID_INDEX, "no index text" end
	if #text > max_bytes then return nil, M.ERROR_TOO_LARGE, "the registry index exceeds the download bound" end
	local decoded_ok, index = pcall(decode_json, text)
	if not decoded_ok or type(index) ~= "table" then
		return nil, M.ERROR_INVALID_INDEX, "the registry index is not valid JSON"
	end
	local valid, reason = M.validate_index(index)
	if not valid then return nil, M.ERROR_INVALID_INDEX, reason end
	return index, nil, nil
end

--- Case-insensitive lookup of one response header.
--- @param headers table|nil
--- @param name string
--- @return string|nil
function M.header(headers, name)
	if type(headers) ~= "table" then return nil end
	local wanted = name:lower()
	for key, value in pairs(headers) do
		if type(key) == "string" and key:lower() == wanted and type(value) == "string" and value ~= "" then
			return value
		end
	end
	return nil
end

--- Request headers of an index refresh.
--- @param etag string|nil ETag of the cached index.
--- @return table
function M.request_headers(etag)
	local headers = { ["User-Agent"] = Registry.USER_AGENT }
	if type(etag) == "string" and etag ~= "" then headers["If-None-Match"] = etag end
	return headers
end

--- Chooses the index the catalogue shows after one refresh response.
--- @param response table { status, body, err, headers } of the index request.
--- @param cached table|nil { index, etag } decoded from the local cache.
--- @param bundled table|nil Index shipped with the app, decoded.
--- @param decode_json function
--- @param max_bytes number
--- @return table outcome { index, source, etag, store, text, error = nil|{ code, detail } }
function M.resolve_index(response, cached, bundled, decode_json, max_bytes)
	local status = tonumber(response and response.status) or 0
	local failure
	if status == HTTP_OK then
		local index, code, detail = M.decode_index(response.body, decode_json, max_bytes)
		if index then
			return {
				index = index,
				source = M.SOURCE_NETWORK,
				etag = M.header(response.headers, "etag"),
				store = true,
				text = response.body,
				error = nil,
			}
		end
		failure = { code = code, detail = detail }
	elseif status == HTTP_NOT_MODIFIED then
		if cached and type(cached.index) == "table" then
			return { index = cached.index, source = M.SOURCE_CACHE, etag = cached.etag, store = false, error = nil }
		end
		failure = { code = M.ERROR_NOT_MODIFIED_WITHOUT_CACHE,
			detail = "the registry answered 304 although no index is cached" }
	elseif status == 0 then
		local reason = type(response and response.err) == "string" and response.err ~= "" and response.err
			or "no HTTP response (network, proxy or timeout)"
		failure = { code = M.ERROR_OFFLINE, detail = reason }
	else
		failure = { code = M.ERROR_HTTP, detail = "HTTP " .. tostring(status) }
	end
	if cached and type(cached.index) == "table" then
		return { index = cached.index, source = M.SOURCE_CACHE, etag = cached.etag, store = false, error = failure }
	end
	if type(bundled) == "table" then
		return { index = bundled, source = M.SOURCE_BUNDLED, etag = nil, store = false, error = failure }
	end
	return { index = nil, source = M.SOURCE_NONE, etag = nil, store = false, error = failure }
end

--- Runs one conditional index refresh.
--- deps.read_cache() -> { text, etag } | nil reads the local cache;
--- deps.write_cache(text, etag) -> ok, err stores a fresh index;
--- deps.bundled_index is the decoded index shipped with the app (or nil);
--- deps.local_source selects the checkout's registry without remote cache or HTTP.
--- deps.transport.get(url, headers, timeout_ms, callback(status, body, err, headers))
--- must call back exactly once; deps.decode_json decodes.
--- on_done(outcome) is called exactly once (see M.resolve_index); a cached
--- index that could not be used is set aside and named in
--- outcome.cache_warning, never dropped without a word.
--- @param settings table Result of Registry.resolve().
--- @param deps table
--- @param on_done function
function M.refresh(settings, deps, on_done)
	if deps.local_source then
		local valid, detail = M.validate_index(deps.bundled_index)
		on_done({ index = valid and deps.bundled_index or nil,
			source = valid and M.SOURCE_BUNDLED or M.SOURCE_NONE, store = false,
			error = not valid and { code = M.ERROR_INVALID_INDEX, detail = detail } or nil })
		return
	end
	local cached = nil
	local cache_warning = nil
	local cache = deps.read_cache()
	if type(cache) == "table" then
		local index, _, detail = M.decode_index(cache.text, deps.decode_json, settings.max_file_bytes)
		if index then
			cached = { index = index, etag = cache.etag }
		else
			cache_warning = "the cached registry index is unusable: " .. tostring(detail)
		end
	end
	local url = Registry.raw_url(settings, settings.index_file)
	local headers = M.request_headers(cached and cached.etag or nil)
	local finished = false
	deps.transport.get(url, headers, settings.timeout_ms, function(status, body, err, response_headers)
		if finished then return end
		finished = true
		local outcome = M.resolve_index({ status = status, body = body, err = err, headers = response_headers },
			cached, deps.bundled_index, deps.decode_json, settings.max_file_bytes)
		outcome.cache_warning = cache_warning
		if outcome.store then
			local stored, store_err = deps.write_cache(outcome.text, outcome.etag)
			if not stored then
				outcome.cache_error = "cannot store the registry index: " .. tostring(store_err)
			end
		end
		on_done(outcome)
	end)
end





-- ===================================
-- ===================================
-- ======= 2/ Installed record =======
-- ===================================
-- ===================================

--- An empty installed-layouts record.
--- @return table
function M.empty_installed()
	return { schema_version = M.INSTALLED_SCHEMA_VERSION, layouts = {} }
end

--- Detaches a JSON model while retaining explicit null and array identities.
--- @param value any
--- @return any copy
local function copy_json_value(value)
	if type(value) ~= "table" or Json.is_null(value) then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = copy_json_value(child) end
	return Json.is_array(value) and Json.array(copy) or copy
end

--- Why one entry of the installed-layouts record cannot be used, if it cannot.
--- @param id any The entry's key.
--- @param entry any The entry.
--- @return string|nil problem
local function installed_entry_problem(id, entry)
	if not Registry.is_valid_id(id) then return "'" .. tostring(id) .. "' is not a layout id" end
	if type(entry) ~= "table" or Json.is_array(entry) or Json.is_null(entry) then
		return "the entry is not an object"
	end
	if entry.id ~= id then return "its id field does not name this entry" end
	if type(entry.sha256) ~= "string" or type(entry.version) ~= "string" then
		return "it has no verified sha256 and version"
	end
	if entry.extension ~= nil then
		local extension = entry.extension
		if type(extension) ~= "table" or Json.is_null(extension) or Json.is_array(extension) then
			return "its extension is not an object"
		end
		-- The published validator checks inventory contents; retain lossless
		-- object/array identity here before its generic table checks run.
		local files = extension.files
		if type(files) == "table" and not Json.is_null(files) then
			local count, length = 0, #files
			for index, file in pairs(files) do
				if type(index) ~= "number" or index < 1 or index > length or index % 1 ~= 0
					or type(file) ~= "table" or Json.is_null(file) or Json.is_array(file) then
					return "its extension files are not an array of objects"
				end
				count = count + 1
			end
			if count ~= length then return "its extension files are not a complete array" end
		end
		local valid, reason = Extension.validate(entry)
		if not valid then return "its extension is unusable: " .. reason end
	end
	return nil
end

--- Decodes the installed-layouts record. A missing file (nil text) is an
--- empty record; an unreadable one is an error, never an empty record, so a
--- damaged file cannot make installed layouts look absent. One entry this
--- build cannot use (an older build's shape, an id it no longer accepts) is
--- left out of `layouts` and kept, with the reason, in `outdated`: the caller
--- warns about it, and the other layouts stay installed.
--- @param text string|nil
--- @param decode_json function
--- @return table|nil record { schema_version, layouts = { [id] = entry },
---   outdated = { [id] = { entry = raw entry, detail = reason } } }
--- @return string|nil error
function M.decode_installed(text, decode_json)
	if text == nil then return M.empty_installed(), nil end
	local ok, record = pcall(decode_json, text)
	if not ok or type(record) ~= "table" or Json.is_array(record) or Json.is_null(record) then
		return nil, "the installed-layouts record is not valid JSON"
	end
	if record.schema_version ~= M.INSTALLED_SCHEMA_VERSION then
		return nil, "the installed-layouts record has schema version " .. tostring(record.schema_version)
	end
	if type(record.layouts) ~= "table" or Json.is_array(record.layouts) or Json.is_null(record.layouts) then
		return nil, "the installed-layouts record has no layouts table"
	end
	local root_members = {}
	for key, value in pairs(record) do
		if key ~= "schema_version" and key ~= "layouts" then root_members[key] = copy_json_value(value) end
	end
	local layouts, outdated = {}, {}
	for id, entry in pairs(record.layouts) do
		local problem = installed_entry_problem(id, entry)
		if problem then outdated[tostring(id)] = { entry = entry, detail = problem }
		else layouts[id] = entry end
	end
	record.layouts, record.outdated = layouts, outdated
	_installed_sources[record] = { root_members = root_members, outdated = copy_json_value(outdated) }
	return record, nil
end

--- A new record to write, holding the entries a decode left out unchanged: a
--- write never deletes an entry the user was told to fix.
--- @param record table A decoded record.
--- @return table copy
local function writable_copy(record)
	local source = _installed_sources[record]
	if not source then
		-- Existing programmatic records may carry the public obsolete registry.
		-- Their remaining root members are ordinary source model values.
		local root_members = {}
		for key, value in pairs(record) do
			if key ~= "schema_version" and key ~= "layouts" and key ~= "outdated" then
				root_members[key] = copy_json_value(value)
			end
		end
		source = { root_members = root_members, outdated = copy_json_value(record.outdated or {}) }
	end
	local copy = M.empty_installed()
	local retained = copy_json_value(source)
	for key, value in pairs(retained.root_members) do copy[key] = copy_json_value(value) end
	for id, item in pairs(retained.outdated) do copy.layouts[id] = copy_json_value(item.entry) end
	_installed_sources[copy] = retained
	return copy
end

-- Fields supplied by the published layout index are replaced as one verified
-- entry. Omitted future fields have no owner in this build and remain source
-- data; omitted owned fields must not revive an older extension or metadata.
local INSTALLED_ENTRY_FIELDS = {
	id = true, name = true, family = true, keyboard_name = true,
	version = true, file = true, sha256 = true, size = true,
	licence = true, homepage = true, author = true,
	languages = true, variants = true, platforms = true,
	keycode_convention = true, source_url = true, extension = true,
	source_sha256 = true, licence_file = true, xkb = true,
}

local function overlay_verified_entry(installed, entry)
	local copy = copy_json_value(entry)
	if installed then
		for key, value in pairs(installed) do
			if not INSTALLED_ENTRY_FIELDS[key] and entry[key] == nil then
				copy[key] = copy_json_value(value)
			end
		end
	end
	return copy
end

--- A copy of the record with one entry added or replaced, to write.
--- @param record table
--- @param entry table Registry index entry the installed copy was verified against.
--- @return table
function M.with_installed(record, entry)
	local copy = writable_copy(record)
	for id, installed in pairs(record.layouts) do
		if not _installed_sources[copy].outdated[id] then copy.layouts[id] = copy_json_value(installed) end
	end
	local installed = not _installed_sources[copy].outdated[entry.id] and record.layouts[entry.id] or nil
	copy.layouts[entry.id] = overlay_verified_entry(installed, entry)
	-- A verified same-id install explicitly replaces an obsolete row. A later
	-- builder must not resurrect that original row after this acknowledged edit.
	_installed_sources[copy].outdated[entry.id] = nil
	return copy
end

--- A copy of the record without one entry, to write.
--- @param record table
--- @param id string
--- @return table
function M.without_installed(record, id)
	local copy = writable_copy(record)
	for installed_id, installed in pairs(record.layouts) do
		if installed_id ~= id and not _installed_sources[copy].outdated[installed_id] then
			copy.layouts[installed_id] = copy_json_value(installed)
		end
	end
	return copy
end

--- The installed entries, sorted by id.
--- @param record table
--- @return table
function M.installed_list(record)
	local ids = {}
	for id in pairs(record.layouts) do ids[#ids + 1] = id end
	table.sort(ids)
	local list = {}
	for _, id in ipairs(ids) do list[#list + 1] = record.layouts[id] end
	return list
end

--- Whether an entry belongs to the Ergopti family.
--- @param entry table|nil
--- @param ergopti_family string registry.ergopti_family of the shared defaults.
--- @return boolean
function M.is_ergopti(entry, ergopti_family)
	return type(entry) == "table" and entry.family == ergopti_family
end





-- =================================
-- =================================
-- ======= 3/ Layout source ========
-- =================================
-- =================================

--- The entry of the shipped index when the shipped file IS the one ``entry``
--- describes (same path, size and checksum), nil otherwise.
--- @param bundled table|nil Index shipped with the app.
--- @param entry table Entry of the index being installed from.
--- @return table|nil
function M.bundled_entry(bundled, entry)
	if type(bundled) ~= "table" then return nil end
	local shipped = Registry.find_entry(bundled, entry.id)
	if shipped and shipped.file == entry.file and shipped.size == entry.size and shipped.sha256 == entry.sha256 then
		return shipped
	end
	return nil
end

--- Obtains the verified bytes of one layout: from the copy shipped with the
--- app when it is the described file, from the registry otherwise.
--- deps.bundled_index, deps.read_bundled(relative_path) -> text|nil, deps.transport
--- ({ get, sha256 }). on_done(true, { text, source }) or on_done(false, reason)
--- is called exactly once.
--- @param settings table
--- @param entry table
--- @param deps table
--- @param on_done function
function M.acquire(settings, entry, deps, on_done)
	local finished = false
	local function finish(ok, detail)
		if finished then return end
		finished = true
		if not ok or entry.extension == nil then on_done(ok, detail) return end
		Extension.acquire(settings, entry, deps, function(complete, content)
			if not complete then on_done(false, content) return end
			detail.content = content
			on_done(true, detail)
		end)
	end
	if M.bundled_entry(deps.bundled_index, entry) then
		-- A shipped copy the shipped index lists but that cannot be read is a
		-- damaged installation; the registry still serves the same bytes, so the
		-- download below replaces it and its checksum proves the result.
		local text = deps.read_bundled(entry.file)
		if type(text) == "string" then
			deps.transport.sha256(text, function(digest, digest_err)
				if type(digest) ~= "string" then
					finish(false, "cannot digest the shipped layout: " .. tostring(digest_err))
					return
				end
				local ok, reason = Registry.verify(entry, text, digest)
				if not ok then
					finish(false, "the shipped copy is damaged: " .. tostring(reason))
					return
				end
				finish(true, { text = text, source = M.SOURCE_BUNDLED })
			end)
			return
		end
	end
	Registry.fetch_layout(settings, entry, deps.transport, function(ok, detail)
		if not ok then
			finish(false, detail)
			return
		end
		finish(true, { text = detail, source = M.SOURCE_NETWORK })
	end)
end

return M
