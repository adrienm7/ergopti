--- modules/llm/api_entries.lua

--- ==============================================================================
--- MODULE: Remote API Entries (Linux)
--- DESCRIPTION:
--- The API endpoints the user added (provider, model, optional URL, key) and
--- which one predictions use.
---
--- FEATURES & RATIONALE:
--- 1. One private file, ~/.config/ergopti_plus/api_keys.json, created with mode
---    0600 like ~/.netrc: the key is readable by its owner and nobody else. It
---    lives beside storage.json rather than in the configuration folder, which
---    users may point at a synced or shared directory.
--- 2. Written to a fresh temporary file and renamed, so a crash leaves the
---    previous file intact and a pre-existing file's looser mode never carries
---    over.
--- 3. Keys never reach a log: entries are described by id and provider.
--- 4. `label` stays required, so this file still loads in the builds before
---    2026-10; it holds the automatic name the tray writes and no build after
---    them reads it: every tray names an entry after its provider and model.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Json = require("json")
local ConfigPaths = require("infra.config_paths")
local ConfigOutdated = require("config_outdated")
local LocalCatalogue = require("modules.llm.local_server_catalogue")
local AuthPolicy = require("llm.local_server_auth")

local LOG = "modules.llm.api_entries"
local VERSION = 1
local PRIVATE_MODE = tonumber("600", 8)
local O_WRONLY, O_CREAT, O_EXCL = 1, 64, 128

local _path_override = nil
local _state = nil
local _sequence = 0

-- Creates a new file only its owner can read: libc through LuaJIT's FFI,
-- built on first use, or the primitive a test installed.
local _create_private = nil




-- =========================================
-- =========================================
-- ======= 1/ File =========================
-- =========================================
-- =========================================

--- The private entries file.
--- @return string
function M.path()
	return _path_override or (ConfigPaths.config_home() .. "/ergopti_plus/api_keys.json")
end

--- The libc primitive: open(2) with O_CREAT | O_EXCL and mode 0600, so the
--- file is private from its first byte, then write, fsync and close.
---
--- Built on first use rather than at load. The FFI exists only under LuaJIT,
--- the one interpreter the daemon runs on, where this changes nothing; on any
--- other interpreter the first save raises "module 'ffi' not found" instead of
--- the whole module refusing to load, so the entry logic stays reachable by a
--- test that installs its own primitive.
--- @return function (path, text) -> ok, err
local function libc_create_private()
	local ffi = require("ffi")
	-- Private names: evdev_reader and uinput_writer declare open() without its
	-- mode argument, and a second declaration of the same name is refused.
	ffi.cdef([[
		int ergopti_private_open(const char *pathname, int flags, int mode) __asm__("open");
		long ergopti_private_write(int fd, const void *buf, unsigned long count) __asm__("write");
		int ergopti_private_close(int fd) __asm__("close");
		int ergopti_private_fsync(int fd) __asm__("fsync");
	]])
	return function(path, text)
		local fd = ffi.C.ergopti_private_open(path, O_WRONLY + O_CREAT + O_EXCL, PRIVATE_MODE)
		if fd < 0 then return false, "cannot create " .. path end
		local written = tonumber(ffi.C.ergopti_private_write(fd, text, #text))
		local synced = ffi.C.ergopti_private_fsync(fd)
		ffi.C.ergopti_private_close(fd)
		if written ~= #text or synced ~= 0 then return false, "short write to " .. path end
		return true
	end
end

--- Writes text to a new file only its owner can read, then renames it over path.
--- @param path string
--- @param text string
--- @return boolean ok, string|nil err
local function write_private(path, text)
	local dir = path:match("^(.*)/[^/]+$")
	if dir then os.execute("mkdir -p '" .. (dir:gsub("'", "'\\''")) .. "'") end
	local tmp = path .. ".tmp"
	os.remove(tmp)
	_create_private = _create_private or libc_create_private()
	local created, create_err = _create_private(tmp, text)
	if not created then
		os.remove(tmp)
		return false, create_err
	end
	local renamed, rename_err = os.rename(tmp, path)
	if not renamed then
		os.remove(tmp)
		return false, tostring(rename_err)
	end
	return true
end

--- A usable entry, or nil.
--- @param raw any
--- @return table|nil
local function valid_entry(raw)
	if type(raw) ~= "table" then return nil end
	for _, key in ipairs({ "id", "provider", "label" }) do
		if type(raw[key]) ~= "string" or raw[key] == "" then return nil end
	end
	for _, key in ipairs({ "model", "base_url" }) do
		if raw[key] ~= nil and type(raw[key]) ~= "string" then return nil end
	end
	local _, servers = LocalCatalogue.load({})
	if not AuthPolicy.token_allowed(raw.provider, raw.token, servers) then return nil end
	return {
		id = raw.id,
		provider = raw.provider,
		label = raw.label,
		token = raw.token,
		model = type(raw.model) == "string" and raw.model or "",
		base_url = type(raw.base_url) == "string" and raw.base_url or "",
	}
end

--- How a warning names a stored entry: its id when it has one, never its key.
--- @param raw any The stored entry.
--- @param index number Its position in the file.
--- @return string
local function entry_name(raw, index)
	local id = type(raw) == "table" and type(raw.id) == "string" and raw.id ~= "" and raw.id or nil
	return id and ("entries[id=" .. id .. "]") or ("entries[#" .. index .. "]")
end

--- Whether a decoded value is a JSON list: consecutive integer keys from 1.
--- @param value table
--- @return boolean
local function is_list(value)
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return false end
		count = count + 1
	end
	return count == #value
end

--- Loads the file once. A malformed file is kept aside, not overwritten. An
--- entry an older build wrote in another shape is outdated: warned once,
--- left out, and written back unchanged, so its key is never deleted. A file
--- this build cannot write back whole (another version, entries that are not
--- a list) is read as far as it can be, and every write to it is refused.
--- @return table state
local function state()
	if _state then return _state end
	_state = { version = VERSION, entries = {}, active_id = "", outdated = {}, extras = {}, row_order = {}, root_extras = {} }
	local fh = io.open(M.path(), "r")
	if not fh then return _state end
	local text = fh:read("*a")
	fh:close()
	local root = Json.decode_lossless(text)
	if type(root) ~= "table" or type(root.entries) ~= "table" then
		local aside = M.path() .. ".corrupt"
		os.rename(M.path(), aside)
		Logger.error(LOG, "API entries file is malformed — kept at %s, starting empty.", aside)
		return _state
	end
	if root.version ~= nil and root.version ~= VERSION then
		_state.write_refusal = "it has version " .. tostring(root.version) .. ", which this build does not write"
	elseif not Json.is_array(root.entries) or not is_list(root.entries) then
		_state.write_refusal = "its entries are not a list, as this build writes them"
	end
	if root.active_id ~= nil and type(root.active_id) ~= "string" then
		_state.write_refusal = "its selection has a type this build does not write"
	end
	for key, value in pairs(root) do
		if key ~= "version" and key ~= "entries" and key ~= "active_id" then _state.root_extras[key] = value end
	end
	local ids = {}
	for index, raw in ipairs(root.entries) do
		local entry = valid_entry(raw)
		_state.row_order[#_state.row_order + 1] = { id = entry and entry.id or nil, raw = raw }
		if entry and ids[entry.id] then _state.write_refusal = "it contains duplicate API entry identities" end
		if entry then ids[entry.id] = true end
		if entry then
			_state.entries[#_state.entries + 1] = entry
			-- Fields a later build added travel back with the entry.
			_state.extras[entry.id] = raw
		else
			_state.outdated[#_state.outdated + 1] = raw
			ConfigOutdated.report_in_file(M.path(), entry_name(raw, index),
				"its entry fields do not match this build's supported text types")
		end
	end
	if type(root.active_id) == "string" and M.get(root.active_id) then
		_state.active_id = root.active_id
	elseif type(root.active_id) == "string" and root.active_id ~= "" then
		-- Kept as written until the user chooses an entry.
		_state.dangling_active_id = root.active_id
		ConfigOutdated.report_in_file(M.path(), "active_id", "no usable entry has this id; no entry is active")
	end
	return _state
end

--- One entry as written back: its stored fields, this build's values over them.
--- @param entry table A usable entry.
--- @return table
local function stored_form(entry)
	local out = {}
	for key, value in pairs(state().extras[entry.id] or {}) do out[key] = value end
	for key, value in pairs(entry) do out[key] = value end
	return out
end

--- Persists the current state, the outdated entries included as they were.
--- A file this build cannot write back whole is never replaced: the write is
--- refused with its bytes unchanged, since rewriting it would drop keys.
--- @return boolean
local function persist()
	local current = state()
	if current.write_refusal then
		Logger.error(LOG, "API entries were not saved: '%s' %s; fix or move that file first, "
			.. "or rewriting it would lose its keys.", M.path(), current.write_refusal)
		return false
	end
	local entries = {}
	local pending = {}
	for _, entry in ipairs(current.entries) do pending[entry.id] = entry end
	for _, row in ipairs(current.row_order) do
		if row.id then
			local entry = pending[row.id]
			if entry then entries[#entries + 1] = stored_form(entry); pending[row.id] = nil end
		else
			entries[#entries + 1] = row.raw
		end
	end
	-- New entries have no historical row yet; append in the user's order.
	for _, entry in ipairs(current.entries) do
		if pending[entry.id] then entries[#entries + 1] = stored_form(entry); pending[entry.id] = nil end
	end
	local active = current.active_id ~= "" and current.active_id or current.dangling_active_id or ""
	local image = {}
	for key, value in pairs(current.root_extras) do image[key] = value end
	image.version, image.entries, image.active_id = VERSION, Json.array(entries), active
	local ok, err = write_private(M.path(), Json.encode(image))
	if not ok then Logger.error(LOG, "API entries could not be saved: %s.", tostring(err)) end
	return ok
end




-- =========================================
-- =========================================
-- ======= 2/ Entries ======================
-- =========================================
-- =========================================

--- Every entry, in the order they were added.
--- @return table
function M.list()
	local copy = {}
	for index, entry in ipairs(state().entries) do copy[index] = entry end
	return copy
end

--- One entry by id.
--- @param id string
--- @return table|nil
function M.get(id)
	for _, entry in ipairs(state().entries) do
		if entry.id == id then return entry end
	end
	return nil
end

--- The entry predictions use, or nil.
--- @return table|nil
function M.active()
	local id = state().active_id
	return id ~= "" and M.get(id) or nil
end

--- Adds an entry and makes it active.
--- @param fields table { provider, token, label, model?, base_url? }
--- @return table|nil entry, string|nil err
function M.add(fields)
	_sequence = _sequence + 1
	local entry = valid_entry({
		id = string.format("%s-%d-%d", tostring(fields.provider), os.time(), _sequence),
		provider = fields.provider,
		label = fields.label,
		token = fields.token,
		model = fields.model,
		base_url = fields.base_url,
	})
	if not entry then return nil, "provider, label and key are required" end
	local current = state()
	current.entries[#current.entries + 1] = entry
	local previous = current.active_id
	current.active_id = entry.id
	if not persist() then
		table.remove(current.entries)
		current.active_id = previous
		return nil, "the entry could not be saved"
	end
	-- The user chose an entry: a stored selection nothing matched is replaced.
	current.dangling_active_id = nil
	Logger.info(LOG, "API entry '%s' (%s) added and selected.", entry.id, entry.provider)
	return entry
end

--- Selects the entry predictions use.
--- @param id string
--- @return boolean
function M.set_active(id)
	if not M.get(id) then return false end
	local previous = state().active_id
	state().active_id = id
	if persist() then
		state().dangling_active_id = nil
		return true
	end
	state().active_id = previous
	return false
end

--- Deletes an entry and its key.
--- @param id string
--- @return boolean
function M.remove(id)
	local current = state()
	for index, entry in ipairs(current.entries) do
		if entry.id == id then
			table.remove(current.entries, index)
			local previous = current.active_id
			if previous == id then current.active_id = "" end
			if persist() then
				Logger.info(LOG, "API entry '%s' removed.", entry.id)
				return true
			end
			table.insert(current.entries, index, entry)
			current.active_id = previous
			return false
		end
	end
	return false
end

--- Points the store at another file and forgets the loaded state (tests).
--- @param path string|nil
function M._set_path_for_test(path)
	_path_override = path
	_state = nil
end

--- Replaces the private-file primitive (tests on a host without POSIX
--- permission bits). nil restores the libc one.
--- @param create function|nil (path, text) -> ok, err; must refuse an existing path.
function M._set_private_create_for_test(create)
	_create_private = create
end

return M
