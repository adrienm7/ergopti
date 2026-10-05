--- adapters/storage.lua

--- ==============================================================================
--- MODULE: Storage Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the Storage port contract defined in
--- static/ergopti_plus/_shared/core/ports/Storage.spec.js. Provides a key-value
--- persistent store backed by a JSON file under XDG_CONFIG_HOME
--- (~/.config/ergopti_plus/storage.json) so settings survive daemon restarts
--- and reboots without depending on D-Bus or gconf.
---
--- FEATURES & RATIONALE:
--- 1. XDG-compliant path: respects XDG_CONFIG_HOME so containerised environments
---    and users with non-standard home directories work out of the box.
--- 2. Atomic write: data is written to a .tmp file then renamed so a crash during
---    a write never corrupts the main store.
--- 3. Lazy load: the JSON file is read only on the first call (or after reload),
---    keeping daemon startup fast.
--- 4. Fail-safe returns: every method returns a safe default on error.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Shell  = require("adapters.shell_runner")
local NoReplaceMove = require("infra.no_replace_move")

-- Shared pure-Lua JSON codec (single source of truth for all Lua drivers). The
-- bespoke encoder/decoder this replaces silently flattened nested tables and
-- dropped arrays on the decode path, corrupting any non-flat stored value
local json = require("json")

local _owned_writer = nil

--- Resolves publication only after Storage has completed its boot ownership.
--- Eager Writer resolution softly loads i18n, whose native owner needs Storage.
--- @return table writer
local function owned_writer()
	if _owned_writer == nil then _owned_writer = require("toml_codec.writer") end
	return _owned_writer
end

local _owned_inverse = nil

--- Resolves the existing exact inverse without reintroducing the boot cycle.
--- @return table inverse
local function owned_inverse()
	if _owned_inverse == nil then _owned_inverse = require("config_file_inverse") end
	return _owned_inverse
end

local LOG = "adapters.storage"
local ENOENT = 2 -- Native Linux errno: only a proven missing store may start empty.


-- ========================================
-- ========================================
-- ======= 1/ Path Resolution =============
-- ========================================
-- ========================================

local function _config_dir()
	-- NOTE the directory is "ergopti_plus", not "ergopti" as everywhere else.
	-- Preserved deliberately: this is where existing installs keep their
	-- storage.json, and unifying the name would orphan every stored setting
	-- with no migration. The HOME fallback is the shared one.
	local ConfigPaths = require("infra.config_paths")
	return ConfigPaths.config_home() .. "/ergopti_plus/"
end

local _STORE_PATH = _config_dir() .. "storage.json"
local _TMP_PATH   = _STORE_PATH .. ".tmp"
local _CORRUPT_PATH = _STORE_PATH .. ".corrupt"


-- ========================================
-- ========================================
-- ======= 2/ Internal State ==============
-- ========================================
-- ========================================

local _cache = nil   -- in-memory copy of the store; nil until first load
local _load_blocked = false
local _recovery = nil


local _owned_io_busy = false
local _owned_file_debt = nil
local _owned_effect_paths = {}

--- Linux public keys are strings in its physical JSON object.
--- @param key string
--- @return boolean valid
local function owned_logical_key(key) return type(key) == "string" and key ~= "" end

-- Private receipts deliberately do not retain their weak-map token key. A
-- journal keeps a committed token alive; unsettled effects remain gate-owned.
local _owned_gates, _owned_aliases, _owned_generations = {}, {}, {}
local _owned_receipts = setmetatable({}, { __mode = "k" })
local _owned_epoch = 0
local _owned_finalizing = {}

--- Copies only finite native settings/JSON values without caller ownership.
--- @param value any
--- @param seen table|nil
--- @return any copy
local function owned_copy(value, seen)
	if json.is_null(value) then return value end
	local kind = type(value)
	if kind == "number" then
		assert(value == value and value ~= math.huge and value ~= -math.huge, "non-finite value")
		local encoded = assert(json.encode(value))
		local decoded = json.decode_lossless(encoded)
		assert(type(decoded) == "number" and decoded == value
			and (value ~= 0 or 1 / decoded == 1 / value), "numeric backup cannot round-trip")
		return value
	end
	if kind == "string" or kind == "boolean" or kind == "nil" then return value end
	assert(kind == "table" and getmetatable(value) == nil, "unsupported storage value")
	seen = seen or {}
	assert(not seen[value], "cyclic storage value")
	seen[value] = true
	local copy, numeric, textual, count = {}, false, false, 0
	for key, child in pairs(value) do
		assert(type(key) == "string" or (type(key) == "number" and key >= 1 and key % 1 == 0), "invalid value key")
		numeric, textual = numeric or type(key) == "number", textual or type(key) == "string"
		count = count + 1
		copy[key] = owned_copy(child, seen)
	end
	assert(not (numeric and textual), "mixed storage table")
	if numeric then for index = 1, count do assert(rawget(copy, index) ~= nil, "sparse storage array") end end
	seen[value] = nil
	if json.is_array(value) then copy = json.array(copy) end
	return copy
end

--- Compares captured native identities, including JSON arrays and null.
--- @param left any
--- @param right any
--- @return boolean equal
local function owned_equal(left, right)
	if json.is_null(left) or json.is_null(right) then return left == right end
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	if json.is_array(left) ~= json.is_array(right) then return false end
	for key, value in pairs(left) do if not owned_equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

--- Tests a cell without conflating false, zero, absence or native value kinds.
--- @param left table
--- @param right table
--- @return boolean equal
local function owned_cell_equal(left, right)
	return left.present == right.present and (not left.present or owned_equal(left.value, right.value))
end

--- Admits a caller's dense, unique logical alias set before acquiring any gate.
--- @param aliases table
--- @return table|nil aliases_copy
local function owned_alias_list(aliases)
	if type(aliases) ~= "table" or getmetatable(aliases) ~= nil then return nil end
	local count, seen, copy = 0, {}, {}
	for index in pairs(aliases) do
		if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then return nil end
		count = count + 1
	end
	if count == 0 then return nil end
	for index = 1, count do
		local alias = rawget(aliases, index)
		if type(alias) ~= "string" or alias == "" or alias:find("\0", 1, true) or seen[alias] or not owned_logical_key(alias) then return nil end
		seen[alias], copy[index] = true, alias
	end
	table.sort(copy)
	return copy
end

--- Acquires just the supplied aliases for one private aggregate owner.
--- @param owner table Opaque primary transaction owner.
--- @param aliases table Dense logical keys.
--- @return boolean acquired
function M.acquire_owned(owner, aliases)
	if type(owner) ~= "table" or _owned_gates[owner] ~= nil or _owned_finalizing[owner] then return false end
	local keys = owned_alias_list(aliases)
	if not keys then return false end
	for _, key in ipairs(keys) do if _owned_aliases[key] ~= nil then return false end end
	_owned_epoch = _owned_epoch + 1
	local gate = { keys = keys, epoch = _owned_epoch, sequence = 0, busy = false }
	_owned_gates[owner] = gate
	for _, key in ipairs(keys) do _owned_aliases[key] = owner end
	return true
end

--- Releases gates only after primary compensation and native effects settle.
--- Committed receipt inverses stay privately valid for a later reacquisition.
--- @param owner table
--- @return boolean released
function M.release_owned(owner)
	local gate = _owned_gates[owner]
	if not gate or gate.busy or gate.debt ~= nil then return false end
	gate.busy = true
	local pending = rawget(owner, "pending")
	local okay = true
	if pending ~= nil then
		local called, result = false, nil
		if type(pending) == "function" then called, result = pcall(pending) end
		okay = called and result == false and rawequal(rawget(owner, "pending"), pending)
	end
	gate.busy = false
	if not okay then return false end
	for _, key in ipairs(gate.keys) do _owned_aliases[key] = nil end
	_owned_gates[owner] = nil
	return true
end

--- Reports only unsettled native effect/cleanup debt, never a held alias gate.
--- @param owner table
--- @param receipt table Opaque native token.
--- @return boolean pending
function M.pending_owned(owner, receipt)
	local record = _owned_receipts[receipt]
	return record ~= nil and rawequal(record.owner, owner) and record.pending == true
end

--- Verifies receipt ownership and the same acquired alias set across reentry.
--- @param owner table
--- @param receipt table
--- @param publishing boolean
--- @return table|nil gate
--- @return table|nil record
local function owned_authority(owner, receipt, publishing)
	local gate, record = _owned_gates[owner], _owned_receipts[receipt]
	if not rawequal(package.loaded["adapters.storage"], M) then return nil end
	if not gate or gate.busy or not record or not rawequal(record.owner, owner) or not owned_equal(gate.keys, record.keys) then return nil end
	if gate.debt ~= nil and not rawequal(gate.debt, record) then return nil end
	if publishing and (record.used or record.epoch ~= gate.epoch or record.sequence ~= gate.sequence) then return nil end
	return gate, record
end

--- Detaches validated update cells and rejects keys outside the acquired set.
--- @param owner table
--- @param updates table
--- @return table|nil detached
local function owned_updates(owner, updates)
	if type(updates) ~= "table" or getmetatable(updates) ~= nil then return nil end
	local called, copy = pcall(function()
		local result = {}
		for key, cell in pairs(updates) do
			assert(type(key) == "string" and rawequal(_owned_aliases[key], owner), "unowned alias")
			assert(type(cell) == "table" and getmetatable(cell) == nil and type(cell.present) == "boolean", "invalid cell")
			for field in pairs(cell) do assert(field == "present" or field == "value", "invalid cell field") end
			assert((cell.present and cell.value ~= nil) or (not cell.present and cell.value == nil), "invalid presence")
			result[key] = { present = cell.present, value = owned_copy(cell.value) }
		end
		return result
	end)
	return called and copy or nil
end

--- Pins live adapter methods so reentrant callbacks cannot replace the owner.
--- @param record table
--- @return boolean current
local function owned_live(record)
	if not rawequal(package.loaded["adapters.storage"], M) then return false end
	for name, callback in pairs(record.methods) do if not rawequal(M[name], callback) then return false end end
	if record.file_owner then
		for name, callback in pairs(record.file_methods) do if not rawequal(record.file_owner[name], callback) then return false end end
	end
	return true
end

--- Captures the adapter capability identities, never a caller-supplied image.
--- @return table methods
local function owned_methods()
	local methods = {}
	for _, name in ipairs({ "acquire_owned", "release_owned", "capture_owned", "publish_owned",
		"restore_owned", "pending_owned", "forget_owned", "set", "delete", "clear" }) do methods[name] = M[name] end
	if M.set_many then methods.set_many = M.set_many end
	if M.delete_exact then methods.delete_exact = M.delete_exact end
	return methods
end

--- Finalizes a primary journal without deleting backup files or changing values.
--- A weak owner tombstone retains exact idempotence while breaking LuaJIT cycles.
--- @param owner table
--- @param receipt table
--- @return boolean forgotten
function M.forget_owned(owner, receipt)
	if type(owner) ~= "table" then return false end
	local record = _owned_receipts[receipt]
	if not record then return false end
	if record.forgotten then return rawequal(record.owner_box[1], owner) end
	local gate = _owned_gates[owner]
	if not rawequal(record.owner, owner) or record.pending or gate ~= nil
		or _owned_finalizing[owner] then return false end
	_owned_finalizing[owner] = true
	local pending = rawget(owner, "pending")
	local okay = pending == nil
	if type(pending) == "function" then
		local called, result = pcall(pending)
		okay = called and result == false and rawequal(rawget(owner, "pending"), pending)
	end
	_owned_finalizing[owner] = nil
	if not okay or record.pending or not rawequal(_owned_receipts[receipt], record) then return false end
	_owned_receipts[receipt] = { forgotten = true, owner_box = setmetatable({ owner }, { __mode = "v" }) }
	return true
end


-- ========================================
-- ========================================
-- ======= 3/ Persistence Helpers =========
-- ========================================
-- ========================================

--- Closes a file and normalises Lua's protected-call return shape.
--- @param fh file*
--- @return boolean
local function _close(fh)
	local ok, closed = pcall(fh.close, fh)
	return ok and closed == true
end

--- Finds a recovery path without overwriting an older corrupt-store backup.
--- @return string|nil Unoccupied path, or nil when absence cannot be proven.
local function _next_recovery_path()
	local candidate = _CORRUPT_PATH
	local suffix = 0
	while true do
		-- Opening is not an existence probe: FIFO endpoints block and dangling
		-- links look absent. Skip known occupied special paths without following
		-- them; keep ordinary-file read refusals conservative as before.
		local path = Shell.quote(candidate)
		local query = "if test -L " .. path .. " || { test -e " .. path .. " && test ! -f " .. path
			.. "; }; then printf special; else printf ordinary; fi"
		local queried, inspected, kind = pcall(Shell.exec_checked, query)
		if not queried or inspected ~= true or (kind ~= "special" and kind ~= "ordinary") then return nil end
		if kind == "ordinary" then
			local ok, fh, _, errno = pcall(io.open, candidate, "r")
			if not ok then return nil end
			if not fh then return errno == ENOENT and candidate or nil end
			_close(fh)
		end
		suffix = suffix + 1
		candidate = _CORRUPT_PATH .. "." .. suffix
	end
end

--- Preserves malformed store bytes before a new empty store may be created.
--- @param reason string Stable recovery reason.
local function _preserve_corrupt_store(reason)
	local recovery_path = _next_recovery_path()
	local ok, renamed = false, false
	while recovery_path do
		local failure
		ok, renamed, failure = pcall(NoReplaceMove.move, _STORE_PATH, recovery_path)
		if not ok or renamed == true or failure ~= "EEXIST" then break end
		-- Inspection is advisory: another writer can claim this name before the
		-- native move. Reinspect without replacing any concurrently created inode.
		recovery_path = _next_recovery_path()
	end
	if ok and renamed == true then
		_recovery = { reason = reason, path = recovery_path, preserved = true }
		Logger.error(LOG, "Corrupt storage preserved at '%s'; starting with an empty store.", recovery_path)
		return
	end
	_recovery = { reason = reason, path = _STORE_PATH, preserved = false }
	_load_blocked = true
	Logger.error(LOG, "Corrupt storage could not be preserved; mutations are blocked.")
end

--- Loads the store from disk into _cache.
local function _load()
	local ok_open, fh, _, open_errno = pcall(require("infra.regular_file_reader").open, _STORE_PATH)
	if not ok_open or not fh then
		_cache = {}
		if ok_open and open_errno == ENOENT then return end
		_load_blocked = true
		_recovery = { reason = "read_failed", path = _STORE_PATH, preserved = true }
		Logger.error(LOG, "Storage read could not start; original path retained and mutations blocked.")
		return
	end
	local read_ok, content = pcall(fh.read, fh, "*a")
	local close_ok = _close(fh)
	if not read_ok or type(content) ~= "string" or not close_ok then
		_cache = {}
		_load_blocked = true
		_recovery = { reason = "read_failed", path = _STORE_PATH, preserved = true }
		Logger.error(LOG, "Storage read did not commit; original file retained and mutations blocked.")
		return
	end
	local decode_ok, decoded = pcall(json.decode, content)
	-- Lua represents both JSON objects and arrays as tables. A root array is
	-- not this key-value store: the next object write would discard its entries.
	if decode_ok and type(decoded) == "table" and content:match("^%s*{") then
		_cache = decoded
		return
	end
	_cache = {}
	_preserve_corrupt_store("invalid_json")
end

--- Creates the staging inode exclusively and retains its original descriptor.
--- LuaJIT forwards C11 wx to libc; stock Lua rejects that stdio mode, so its
--- native libuv descriptor supplies the same no-clobber boundary.
--- @return file*|table|nil handle
local function _open_owned_temp()
	if _VERSION == "Lua 5.1" then return io.open(_TMP_PATH, "wx") end
	local ok, uv = pcall(require, "luv")
	if not ok or type(uv.fs_open) ~= "function" or type(uv.fs_write) ~= "function" or type(uv.fs_close) ~= "function" then
		return nil, "exclusive storage staging is unavailable"
	end
	local fd, err = uv.fs_open(_TMP_PATH, "wx", 384) -- Native 0600 permission bits.
	if not fd then return nil, err end
	return {
		write = function(_, bytes)
			local offset = 0
			while offset < #bytes do
				local written, failure = uv.fs_write(fd, bytes:sub(offset + 1), offset)
				if type(written) ~= "number" or written <= 0 or written > #bytes - offset then
					return nil, failure or "storage write did not commit"
				end
				offset = offset + written
			end
			return true
		end,
		close = function() return uv.fs_close(fd) end,
	}
end

--- Persists a staged cache to disk atomically.
--- @param staged table Candidate store that is not yet published in memory.
--- @return boolean
--- @return table|nil snapshot Owned representation of the persisted JSON.
local function _flush(staged)
	if type(staged) ~= "table" or _load_blocked then return false end
	local encode_ok, payload = pcall(json.encode, staged)
	if not encode_ok or type(payload) ~= "string" then
		Logger.error(LOG, "_flush(): store could not be encoded.")
		return false
	end
	-- Own the same representation a subsequent process will read, rather than
	-- publishing caller tables whose later mutations bypass durable writes.
	local decode_ok, snapshot = pcall(json.decode, payload)
	if not decode_ok or type(snapshot) ~= "table" then
		Logger.error(LOG, "_flush(): store could not round-trip through JSON.")
		return false
	end
	local open_ok, fh = pcall(_open_owned_temp)
	if not open_ok or not fh then
		-- Create the directory only after a direct open proved it is needed. This
		-- keeps an already-existing directory independent of shell flavour while
		-- still requiring mkdir's exact result on a first write. The path comes
		-- from the environment and is quoted as one inert POSIX word.
		if not Shell.run(string.format("mkdir -p %s 2>/dev/null", Shell.quote(_config_dir()))) then
			Logger.error(LOG, "_flush(): configuration directory could not be created.")
			return false
		end
		open_ok, fh = pcall(_open_owned_temp)
	end
	if not open_ok or not fh then
		Logger.error(LOG, "_flush(): temporary file could not be opened.")
		return false
	end
	local write_ok, written = pcall(fh.write, fh, payload)
	if not write_ok or written == nil or written == false then
		_close(fh)
		pcall(os.remove, _TMP_PATH)
		Logger.error(LOG, "_flush(): temporary write did not commit.")
		return false
	end
	if not _close(fh) then
		pcall(os.remove, _TMP_PATH)
		Logger.error(LOG, "_flush(): temporary file could not be closed.")
		return false
	end
	local rename_ok, renamed = pcall(os.rename, _TMP_PATH, _STORE_PATH)
	if not rename_ok or renamed ~= true then
		pcall(os.remove, _TMP_PATH)
		Logger.error(LOG, "_flush(): atomic rename failed.")
		return false
	end
	return true, snapshot
end

--- Ensures the in-memory cache is populated.
local function _ensure_loaded()
	if _cache == nil then _load() end
end

--- Returns a shallow store copy suitable for top-level key transactions.
--- @return table
local function _staged_cache()
	local staged = {}
	for key, value in pairs(_cache) do staged[key] = value end
	return staged
end

--- Commits one cache mutation and publishes it only after durable persistence.
--- @param mutate function Receives the staged table.
--- @return boolean
local function _commit(mutate)
	_ensure_loaded()
	if _load_blocked then return false end
	local staged = _staged_cache()
	local ok, err = pcall(mutate, staged)
	if not ok then
		Logger.error(LOG, "Storage mutation staging failed — %s", tostring(err))
		return false
	end
	local flushed, snapshot = _flush(staged)
	if not flushed then return false end
	_cache = snapshot
	return true
end




--- Reads only admitted regular native files, never recovering an invalid store.
--- Symlinks are refused here because publication cannot preserve their source kind.
--- @param path string
--- @return string|nil bytes
--- @return string status
local function owned_read_file(path)
	if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then return nil, "error" end
	local queried, okay, kind = pcall(Shell.exec_checked,
		"if test -L " .. Shell.quote(path) .. "; then printf link; else printf ordinary; fi")
	if not queried or okay ~= true or kind ~= "ordinary" then return nil, "error" end
	local called, handle, _, errno = pcall(require("infra.regular_file_reader").open, path)
	if not called or not handle then return nil, called and errno == ENOENT and "absent" or "error" end
	local read, bytes = pcall(handle.read, handle, "*a")
	local closed = _close(handle)
	if read and type(bytes) == "string" and closed then return bytes, "ok" end
	return nil, "error"
end

--- Compares exact decimal values without delegating identity to binary rounding.
--- Grammar admission stays with the existing JSON decoder; this is a receipt
--- comparison of validated numeric lexemes, not another document parser.
--- @param token string Valid JSON numeric token.
--- @return string|nil normalized
local function owned_decimal_identity(token)
	local mantissa, exponent = token:match("^([^eE]+)[eE]([+-]?%d+)$")
	mantissa, exponent = mantissa or token, exponent or "0"
	local sign = mantissa:sub(1, 1) == "-" and "-" or "+"
	if sign == "-" then mantissa = mantissa:sub(2) end
	local integer, fractional = mantissa:match("^(%d+)%.(%d+)$")
	integer, fractional = integer or mantissa, fractional or ""
	local digits = (integer .. fractional):gsub("^0+", "")
	if digits == "" then return sign .. "zero" end
	local power = tonumber(exponent)
	-- A bounded receipt cannot use a rounded exponent as its own identity.
	-- Nonzero enormous exponents cannot cancel a physically readable mantissa.
	if not power or power ~= power or math.abs(power) > 9007199254740991 then return nil end
	power = power - #fractional
	local suffix = digits:match("0+$") or ""
	if suffix ~= "" then digits, power = digits:sub(1, #digits - #suffix), power + #suffix end
	return sign .. digits .. ":" .. string.format("%.0f", power)
end

--- Checks only raw numeric receipts outside escaped JSON strings.
--- The existing decoder validates the complete object first. This bounded
--- lexical pass neither reads object members nor implements JSON grammar.
--- Unsupported precision remains untouched rather than becoming future data loss.
--- @param bytes string Valid complete JSON source.
--- @return boolean safe
local function owned_numeric_source_safe(bytes)
	local position, quoted = 1, false
	while position <= #bytes do
		local char = bytes:sub(position, position)
		if quoted then
			if char == "\\" then position = position + 2
			elseif char == '"' then quoted = false; position = position + 1
			else position = position + 1 end
		elseif char == '"' then quoted = true; position = position + 1
		elseif char == "-" or char:match("%d") then
			local start = position
			repeat position = position + 1 until position > #bytes or not bytes:sub(position, position):match("[%d.eE+-]")
			local token = bytes:sub(start, position - 1)
			local value = json.decode_lossless(token)
			if type(value) ~= "number" then return false end
			local encoded = json.encode(value)
			local original, candidate = owned_decimal_identity(token), owned_decimal_identity(encoded)
			if original == nil or original ~= candidate then return false end
			-- The published spelling must also keep its sign/precision when the
			-- next native process reads it (notably Lua5.4's integer negative zero).
			local reread = json.decode_lossless(encoded)
			if type(reread) ~= "number" or owned_decimal_identity(json.encode(reread)) ~= candidate then return false end
		else position = position + 1 end
	end
	return not quoted
end

--- Reads the complete strict JSON object and keeps lossless future source kinds.
--- @return table|nil source
--- @return table|nil document
local function owned_store_source()
	local bytes, status = owned_read_file(_STORE_PATH)
	if status == "absent" then return { status = status }, {} end
	if status ~= "ok" or not bytes:match("^%s*{") then return nil end
	local okay, document = pcall(json.decode_lossless, bytes)
	if not okay or type(document) ~= "table" or json.is_array(document) or json.is_null(document)
		or not owned_numeric_source_safe(bytes) then return nil end
	return { status = "ok", content = bytes }, document
end

--- Keeps terminal native readback inside the same backing-file reentry guard.
--- @return table|nil source
--- @return table|nil document
local function owned_store_readback()
	if _owned_io_busy then return nil end
	_owned_io_busy = true
	local okay, source, document = pcall(owned_store_source)
	_owned_io_busy = false
	if okay then return source, document end
	return nil
end

--- Projects exact document cells without aliasing the persistence snapshot.
--- @param keys table
--- @param document table
--- @return table cells
local function owned_document_cells(keys, document)
	local cells = {}
	for _, key in ipairs(keys) do
		cells[key] = { present = document[key] ~= nil, value = owned_copy(document[key]) }
	end
	return cells
end

--- Verifies owned cells and cooperating same-value generation receipts.
--- @param record table
--- @param document table
--- @return boolean current
local function owned_store_current(record, document)
	if not owned_live(record) then return false end
	local cells = owned_document_cells(record.keys, document)
	for _, key in ipairs(record.keys) do
		if not owned_cell_equal(cells[key], record.expected[key])
			or (_owned_generations[key] or 0) ~= record.generations[key] then return false end
	end
	return true
end

--- Serializes only an actual native publisher call, not an acquired cohort.
--- Foreign aliases remain writable between effects and during retained inverses.
--- @param callback function
--- @return boolean committed
--- @return any detail
--- @return any cleanup
local function owned_file_effect(callback, path)
	if _owned_effect_paths[path] or (path == _STORE_PATH and _owned_io_busy) then return false, "storage publication reentry" end
	_owned_effect_paths[path] = true
	if path == _STORE_PATH then _owned_io_busy = true end
	local okay, committed, detail, cleanup = pcall(callback)
	_owned_effect_paths[path] = nil
	if path == _STORE_PATH then _owned_io_busy = false end
	if not okay then return false, tostring(committed) end
	return committed == true, detail, cleanup
end

--- Uses the existing conditional publisher with nonblocking classified reads.
--- @param files table Actual native file adapter.
--- @return table adapter
local function owned_file_adapter(files)
	local publish, remove = files.write_if_unchanged, files.delete
	return { read_with_status = owned_read_file,
		write_if_unchanged = function(path, bytes, expected)
			return owned_file_effect(function() return publish(path, bytes, expected) end, path)
		end,
		delete = function(path)
			return owned_file_effect(function() return remove(path) end, path)
		end }
end

--- Publishes the same legacy cache projection a subsequent ordinary load reads.
--- @param source table
local function owned_cache_source(source)
	_cache = source.status == "absent" and {} or assert(json.decode(source.content))
end

--- Keeps alias callback reentry from changing a receipt during capture/effect.
--- @param gate table
--- @param callback function
--- @return any result
--- @return any cells
local function owned_guard(gate, callback)
	gate.busy = true
	local okay, result, cells = pcall(callback)
	gate.busy = false
	if not okay then Logger.error(LOG, "Owned storage operation refused — %s.", tostring(result)); return false end
	return result, cells
end

--- Captures actual storage bytes before any legacy recovery or runtime effect.
--- @param owner table
--- @return table|nil receipt
--- @return table|nil cells Detached actual native present/value cells.
function M.capture_owned(owner)
	local gate = _owned_gates[owner]
	if not rawequal(package.loaded["adapters.storage"], M) or not gate or gate.busy or gate.debt ~= nil or _load_blocked then return nil end
	local captured, cells = owned_guard(gate, function()
		local identity = { methods = owned_methods() }
		local source, document = owned_store_source()
		if not source or not owned_live(identity) then return nil end
		local snapshot, generations = owned_document_cells(gate.keys, document), {}
		for _, key in ipairs(gate.keys) do generations[key] = _owned_generations[key] or 0 end
		gate.sequence = gate.sequence + 1
		local token = {}
		_owned_receipts[token] = { owner = owner, keys = owned_copy(gate.keys), snapshot = snapshot,
			expected = owned_copy(snapshot), generations = generations, epoch = gate.epoch,
			sequence = gate.sequence, pending = false, methods = identity.methods, original = source }
		owned_cache_source(source)
		return token, owned_copy(snapshot)
	end)
	return type(captured) == "table" and captured or nil, cells
end

--- Settles actual publication cleanup before comparing or compensating effects.
--- @param record table
--- @return boolean settled
local function owned_storage_settle(record)
	if record.backup then
		if owned_writer().retry_publication_cleanup(record.backup) ~= true then return false end

	end
	if record.forward and owned_inverse().settle_publication(record.forward) ~= true then
		_owned_file_debt = record; return false
	end
	if rawequal(_owned_file_debt, record) and (not record.inverse or (record.inverse.inverse_receipt == nil
		and record.inverse.removal_cleanup == nil)) then _owned_file_debt = nil end
	return true
end

--- Publishes an owned JSON projection through existing source-conditional I/O.
--- Foreign aliases come from the latest actual document and remain unmodified.
--- @param owner table
--- @param receipt table
--- @param updates table Alias to present/value cell.
--- @param backup_path string Unoccupied verified backup destination.
--- @param files table Classified conditional native file adapter.
--- @return boolean published
function M.publish_owned(owner, receipt, updates, backup_path, files)
	local gate, record = owned_authority(owner, receipt, true)
	if not gate then return false end
	local detached = owned_updates(owner, updates)
	if not detached or type(backup_path) ~= "string" or backup_path == "" or backup_path == _STORE_PATH
		or backup_path:find("\0", 1, true) or type(files) ~= "table"
		or type(files.write_if_unchanged) ~= "function" or type(files.delete) ~= "function" then return false end
	return owned_guard(gate, function()
		local source, document = owned_store_source()
		if not source or not owned_store_current(record, document) then return false end
		-- Normalize update values through the same lossless JSON identities used
		-- for the actual source, after strict validation ruled out silent losses.
		for _, cell in pairs(detached) do if cell.present then cell.value = json.decode_lossless(assert(json.encode(cell.value))) end end
		local candidate_document = owned_copy(document)
		for key, cell in pairs(detached) do if cell.present then candidate_document[key] = cell.value else candidate_document[key] = nil end end
		local candidate = assert(json.encode(candidate_document))
		if not owned_numeric_source_safe(candidate) then return false end
		record.used, record.files, record.updates = true, owned_file_adapter(files), detached
		record.file_owner, record.file_methods = files, { write_if_unchanged = files.write_if_unchanged, delete = files.delete }
		record.before, record.candidate = source, candidate
		local backup = assert(json.encode({ format = "ergopti-owned-storage-v1", source = source, cells = record.snapshot }))
		record.backup = { path = backup_path, content = backup }
		record.pending, gate.debt = true, record
		local backed, _, cleanup = owned_writer().publish_if_unchanged(backup_path, backup, record.files, { status = "absent" })
		record.backup.publication_cleanup = type(cleanup) == "function" and cleanup or nil
		record.backup.publication_effect = backed == true
		if not owned_storage_settle(record) then return false end
		if backed ~= true then record.pending, gate.debt = false, nil; return false end
		local backup_bytes, backup_status = owned_writer().read_classified(backup_path, record.files)
		if backup_status ~= "ok" or backup_bytes ~= backup then record.pending, gate.debt = false, nil; return false end
		local latest, latest_document = owned_store_source()
		if not latest or not owned_store_current(record, latest_document) or latest.status ~= source.status
			or latest.content ~= source.content then record.pending, gate.debt = false, nil; return false end
		-- Retain compensation authority before invoking the actual publisher: a
		-- false acknowledgement may still need native cleanup/readback resolution.
		record.forward = { path = _STORE_PATH, source = source, candidate = candidate }
		local written, _, forward_cleanup = owned_writer().publish_if_unchanged(_STORE_PATH, candidate, record.files, source)
		record.forward.publication_cleanup = type(forward_cleanup) == "function" and forward_cleanup or nil
		if record.forward.publication_cleanup then _owned_file_debt = record end
		record.forward.publication_effect = written == true
		if not owned_storage_settle(record) then return false end
		local observed, observed_document = owned_store_readback()
		if not observed then return false end
		if observed.status == "ok" and observed.content == candidate then
			record.effect = true
			record.expected = owned_document_cells(record.keys, candidate_document)
			owned_cache_source(observed)
		elseif observed.status == source.status and observed.content == source.content then
			record.effect = false
			record.pending, gate.debt = false, nil
			return false
		else return false end
		if written ~= true or not owned_store_current(record, observed_document) then return false end
		for key in pairs(detached) do
			_owned_generations[key] = (_owned_generations[key] or 0) + 1
			record.generations[key] = _owned_generations[key]
		end
		record.committed, record.pending, gate.debt = true, false, nil
		return true
	end)
end

--- Restores only owned cells through the existing exact native file inverse.
--- An untouched complete source is restored byte-for-byte, including absence;
--- when foreign aliases changed, their latest values and JSON kinds survive.
--- @param owner table
--- @param receipt table
--- @return boolean restored
function M.restore_owned(owner, receipt)
	local gate, record = owned_authority(owner, receipt, false)
	if not gate then return false end
	return owned_guard(gate, function()
		if record.restored then return true end
		if record.forward and record.effect ~= false then record.pending, gate.debt = true, record end
		if not owned_storage_settle(record) then return false end
		if not record.forward then record.restored, record.pending, gate.debt = true, false, nil; return true end
		local current, document = owned_store_source()
		if not current or not owned_live(record) then return false end
		if record.effect == nil then
			if current.status == record.before.status and current.content == record.before.content then
				record.restored, record.pending, gate.debt = true, false, nil; return true
			end
			if current.status ~= "ok" or current.content ~= record.candidate then return false end
			record.expected = owned_document_cells(record.keys, document)
			record.effect = true
		end
		if record.effect == false then record.restored, record.pending, gate.debt = true, false, nil; return true end
		if record.inverse == nil then
			if not owned_store_current(record, document) then return false end
			local restored_document = owned_copy(document)
			for key in pairs(record.updates) do
				local before = record.snapshot[key]
				if before.present then restored_document[key] = before.value else restored_document[key] = nil end
			end
			local target
			if current.content == record.candidate then target = record.before
			elseif record.original.status == "absent" and next(restored_document) == nil then target = { status = "absent" }
			else target = { status = "ok", content = assert(json.encode(restored_document)) } end
			record.inverse = { path = _STORE_PATH, source = target, candidate = current.content, verify_absence = true }
		end
		record.pending, gate.debt = true, record
		if not owned_live(record) then return false end
		if not record.inverse_effect and owned_inverse().restore(record.inverse, record.files) ~= true then
			if record.inverse.inverse_receipt ~= nil or record.inverse.removal_cleanup ~= nil then _owned_file_debt = record end
			return false
		end
		record.inverse_effect = true
		if rawequal(_owned_file_debt, record) then _owned_file_debt = nil end
		local observed, observed_document = owned_store_readback()
		local target = record.inverse.source
		if not observed or not owned_live(record) or observed.status ~= target.status or observed.content ~= target.content then return false end
		for _, key in ipairs(record.keys) do
			if not owned_cell_equal(owned_document_cells(record.keys, observed_document)[key], record.snapshot[key]) then return false end
		end
		for key in pairs(record.updates) do _owned_generations[key] = (_owned_generations[key] or 0) + 1 end
		owned_cache_source(observed)
		record.restored, record.pending, gate.debt = true, false, nil
		return true
	end)
end

--- Publishes a foreign ordinary mutation from actual source while gates are held.
--- This avoids replacing already-published owned cells with a stale legacy cache.
--- @param mutate function
--- @return boolean committed
local function owned_foreign_commit(mutate)
	if _owned_io_busy or _owned_file_debt ~= nil or _load_blocked then return false end
	local okay, result = pcall(function()
		local source, document = owned_store_source()
		if not source then return false end
		local staged = owned_copy(document)
		mutate(staged)
		staged = owned_copy(staged)
		local payload = assert(json.encode(staged))
		if not owned_numeric_source_safe(payload) then return false end
		local files = owned_file_adapter(require("adapters.file_system"))
		if owned_writer().publish_if_unchanged(_STORE_PATH, payload, files, source) ~= true then return false end
		local current, status = owned_writer().read_classified(_STORE_PATH, files)
		if status ~= "ok" or current ~= payload or not rawequal(package.loaded["adapters.storage"], M) then return false end
		owned_cache_source({ status = "ok", content = payload })
		return true
	end)
	return okay and result == true
end


-- =========================================
-- =========================================
-- ======= 4/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Stores a value under the given key in the persistent store.
--- @param key string
--- @param value any Scalar or nested table value.
--- @return boolean True on success, false on error.
function M.set(key, value)
	local alias = tostring(key)
	if _owned_aliases[alias] ~= nil or _owned_io_busy or _owned_file_debt ~= nil then return false end
	local committed
	if next(_owned_aliases) ~= nil then committed = owned_foreign_commit(function(staged) staged[alias] = value end)
	else committed = _commit(function(staged) staged[alias] = value end) end
	if committed == true then _owned_generations[alias] = (_owned_generations[alias] or 0) + 1 end
	return committed == true
end

--- Stores several top-level values in one durable rename transaction.
--- @param values table Map of storage keys to values.
--- @return boolean
function M.set_many(values)
	if type(values) ~= "table" or _owned_io_busy or _owned_file_debt ~= nil then return false end
	for key in pairs(values) do if _owned_aliases[tostring(key)] ~= nil then return false end end
	local function mutate(staged) for key, value in pairs(values) do staged[tostring(key)] = value end end
	local committed
	if next(_owned_aliases) ~= nil then committed = owned_foreign_commit(mutate)
	else committed = _commit(mutate) end
	if committed == true then
		for key in pairs(values) do local alias = tostring(key); _owned_generations[alias] = (_owned_generations[alias] or 0) + 1 end
	end
	return committed == true
end

--- Reads the value stored under the given key.
--- @param key string
--- @param default_value any Returned when no value is stored.
--- @return any
function M.get(key, default_value)
	_ensure_loaded()
	local ok, result = pcall(function()
		local value = _cache[tostring(key)]
		-- Native settings backends return values, not mutable cache ownership.
		if type(value) == "table" then return json.decode(json.encode(value)) end
		return value
	end)
	if not ok then
		Logger.error(LOG, "get(): failed to read key '%s' — %s", tostring(key), tostring(result))
		return default_value
	end
	if result == nil then return default_value end
	return result
end

--- Deletes the entry for the given key from the persistent store.
--- @param key string
--- @return boolean True on success, including an already-absent key.
function M.delete(key)
	local storage_key = tostring(key)
	if _owned_aliases[storage_key] ~= nil or _owned_io_busy or _owned_file_debt ~= nil then return false end
	if next(_owned_aliases) ~= nil then
		local committed = owned_foreign_commit(function(staged) staged[storage_key] = nil end)
		if committed then _owned_generations[storage_key] = (_owned_generations[storage_key] or 0) + 1 end
		return committed == true
	end
	_ensure_loaded()
	if _load_blocked then return false end
	if _cache[storage_key] == nil then
		_owned_generations[storage_key] = (_owned_generations[storage_key] or 0) + 1
		return true
	end
	local committed = _commit(function(staged) staged[storage_key] = nil end)
	if committed then _owned_generations[storage_key] = (_owned_generations[storage_key] or 0) + 1 end
	return committed == true
end

--- Reports whether a value is currently stored under the given key.
--- @param key string
--- @return boolean
function M.has(key)
	_ensure_loaded()
	local ok, result = pcall(function()
		return _cache[tostring(key)] ~= nil
	end)
	if not ok then
		Logger.error(LOG, "has(): failed to probe key '%s' — %s", tostring(key), tostring(result))
		return false
	end
	return result == true
end

--- The file the store persists to, for the configuration backup that copies
--- it with the configuration folder (modules/updater/config_backup.lua).
--- @return string Absolute path.
function M.path()
	return _STORE_PATH
end

--- Returns all keys currently present in the persistent store.
--- @return table Array of key strings.
function M.keys()
	_ensure_loaded()
	local ok, result = pcall(function()
		local arr = {}
		for k in pairs(_cache) do arr[#arr + 1] = k end
		return arr
	end)
	if not ok then
		Logger.error(LOG, "keys(): failed to retrieve key list — %s", tostring(result))
		return {}
	end
	return type(result) == "table" and result or {}
end

--- Deletes every key currently present in the persistent store.
--- @return boolean True when all entries have been removed without error.
function M.clear()
	if next(_owned_aliases) ~= nil or _owned_io_busy or _owned_file_debt ~= nil then return false end
	_ensure_loaded()
	if _load_blocked then return false end
	local count = 0
	for _ in pairs(_cache) do count = count + 1 end
	if count == 0 then return true end
	if not _commit(function(staged)
		for key in pairs(staged) do staged[key] = nil end
	end) then
		return false
	end
	Logger.debug(LOG, "clear(): removed %d key(s).", count)
	return true
end

--- Returns recovery metadata after a corrupt or incomplete store read.
--- @return table|nil { reason, path, preserved }
function M.recovery_status()
	if not _recovery then return nil end
	return {
		reason = _recovery.reason,
		path = _recovery.path,
		preserved = _recovery.preserved,
	}
end

return M
