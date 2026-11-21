--- settings/adapters/registry_cache.lua

--- ==============================================================================
--- MODULE: Shipped Registry Parse Cache (Hammerspoon)
--- DESCRIPTION:
--- Caches only the typed parse of the immutable config migration registry
--- (_shared/settings/data/config_schema/migrations.toml), the port of
--- windows/settings/engine/publication/registry_cache.ahk. A hit replaces the
--- TOML decode with a bounded binary read; the registry validation still runs.
---
--- FEATURES & RATIONALE:
--- 1. Exact identity. The cache key is the native SHA-256 of the source bytes
---    and of every parser file (the TOML codec folder, its helpers and this
---    module) plus the interpreter version, so a registry edit or a parser
---    change is a stale cache, never a wrong one.
--- 2. A typed codec that never evaluates cached bytes: strings, integers,
---    floats, booleans and tables are read back through string.unpack with
---    size, count, duplicate-key and trailing-byte checks. Config
---    migration rewrites a user's settings, so a cache that could carry code
---    or a forged shape is refused rather than trusted.
--- 3. Validation on every hit: the cached model goes through
---    migrate.validate_registry exactly as a parsed one does.
--- 4. A corrupt, foreign or stale cache is refused and logged, then the
---    authoritative source is parsed again and the cache rewritten.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local Migrate = require("settings.engine.migration.migrate")
local TomlCodec = require("core.text.engine.toml_codec")
local LOG = "settings.adapters.registry_cache"




-- =====================================
-- =====================================
-- ======= 1/ Constants & State ========
-- =====================================
-- =====================================


-- The parse depends on these modules beyond the TOML codec folder. The
-- migration engine is not among them: it only validates, and validation runs
-- live on every hit.
local IDENTITY_MODULES = {
	"core.text.engine.table_util",
	"core.text.engine.utils_core",
	"settings.adapters.registry_cache",
}

-- Value tags of the typed payload.
local TAG_TABLE, TAG_STRING, TAG_INTEGER, TAG_FLOAT, TAG_TRUE, TAG_FALSE = "T", "S", "I", "F", "1", "0"

-- Ports and cache path, set once by M.init; nil until then.
local _state = nil

--- The largest payload admitted, as on Windows: the registry is about 11 KB,
--- so a larger file is forged or corrupt. Nesting needs no bound of its own:
--- every level costs payload bytes, and Lua's stack limit raises an error the
--- loader's pcall turns into a refusal.
--- @return number bytes
function M.max_bytes()
	return require("core.timing.engine.timings").count("limits", "registry_cache_payload_bytes")
end




-- =====================================
-- =====================================
-- ======= 2/ Typed codec ==============
-- =====================================
-- =====================================

--- Appends the typed encoding of one decoded TOML value to `out`.
--- @param value any A value toml_codec.decode can return.
--- @param out table Accumulator of byte fragments.
local function encode_value(value, out)
	local kind = type(value)
	if kind == "string" then
		out[#out + 1] = TAG_STRING .. string.pack(">s4", value)
	elseif kind == "boolean" then
		out[#out + 1] = value and TAG_TRUE or TAG_FALSE
	elseif math.type(value) == "integer" then
		out[#out + 1] = TAG_INTEGER .. string.pack(">i8", value)
	elseif math.type(value) == "float" then
		out[#out + 1] = TAG_FLOAT .. string.pack(">d", value)
	elseif kind == "table" then
		if getmetatable(value) ~= nil then error("registry cache refuses a table with a metatable", 0) end
		local count = #value
		local keys = {}
		for key in pairs(value) do
			if type(key) == "string" then
				keys[#keys + 1] = key
			elseif math.type(key) ~= "integer" or key < 1 or key > count then
				error("registry cache keys must be strings or dense array indices", 0)
			end
		end
		table.sort(keys)
		out[#out + 1] = TAG_TABLE .. string.pack(">I4I4", count, #keys)
		for index = 1, count do
			if value[index] == nil then error("registry cache arrays must be dense", 0) end
			encode_value(value[index], out)
		end
		for _, key in ipairs(keys) do
			out[#out + 1] = string.pack(">s4", key)
			encode_value(value[key], out)
		end
	else
		error("registry cache contains an unsupported " .. kind .. " value", 0)
	end
end

--- Encodes a decoded registry into the typed payload.
--- @param model table Output of toml_codec.decode.
--- @return string payload
function M.encode(model)
	if type(model) ~= "table" then error("registry cache encodes a decoded table only", 0) end
	local out = {}
	encode_value(model, out)
	local payload = table.concat(out)
	if #payload > M.max_bytes() then error("registry cache payload exceeds its size limit", 0) end
	return payload
end

--- Unpacks one fixed-size field, refusing a read past the payload's end.
local function unpack_at(format, size, bytes, position)
	if position + size - 1 > #bytes then error("registry cache is truncated", 0) end
	return string.unpack(format, bytes, position)
end

--- Reads a length-prefixed string at `position`.
local function read_string(bytes, position)
	local length = unpack_at(">I4", 4, bytes, position)
	if position + 4 + length - 1 > #bytes then error("registry cache is truncated", 0) end
	return bytes:sub(position + 4, position + 3 + length), position + 4 + length
end

--- Reads one typed value at `position`.
--- @return any value
--- @return number next_position
local function decode_value(bytes, position)
	if position > #bytes then error("registry cache is truncated", 0) end
	local tag = bytes:sub(position, position)
	position = position + 1
	if tag == TAG_STRING then return read_string(bytes, position) end
	if tag == TAG_TRUE then return true, position end
	if tag == TAG_FALSE then return false, position end
	if tag == TAG_INTEGER then return unpack_at(">i8", 8, bytes, position) end
	if tag == TAG_FLOAT then return unpack_at(">d", 8, bytes, position) end
	if tag ~= TAG_TABLE then error("registry cache has an unknown value tag", 0) end
	local count, keys
	count, keys, position = unpack_at(">I4I4", 8, bytes, position)
	-- Every entry takes at least one byte: a larger count is forged.
	if count + keys > #bytes - position + 1 then error("registry cache has an impossible collection count", 0) end
	local value = {}
	for index = 1, count do
		value[index], position = decode_value(bytes, position)
	end
	local previous = nil
	for _ = 1, keys do
		local key
		key, position = read_string(bytes, position)
		-- The encoder sorts the keys: an unsorted or repeated key is not its output.
		if previous ~= nil and key <= previous then error("registry cache has an unsorted or duplicate key", 0) end
		previous = key
		value[key], position = decode_value(bytes, position)
	end
	return value, position
end

--- Decodes a typed payload; any defect raises.
--- @param payload string
--- @return table model
function M.decode(payload)
	if type(payload) ~= "string" or #payload > M.max_bytes() then
		error("registry cache requires a bounded payload", 0)
	end
	local model, position = decode_value(payload, 1)
	if position ~= #payload + 1 then error("registry cache has trailing bytes", 0) end
	if type(model) ~= "table" then error("registry cache root is not a table", 0) end
	return model
end




-- =====================================
-- =====================================
-- ======= 3/ Envelope & identity ======
-- =====================================
-- =====================================

--- Hashes one port result, refusing anything but 64 lowercase hex digits.
local function checked_hash(hash, bytes, what)
	local digest = hash(bytes)
	if type(digest) ~= "string" or not digest:match("^" .. string.rep("%x", 64) .. "$") then
		error("registry cache could not hash " .. what, 0)
	end
	return digest:lower()
end

--- Builds the cache file text for one identity and payload. It needs no
--- format magic: this module's own bytes are part of the identity, so any
--- change of format is a new identity, and an older file reads as stale.
--- @param identity string 64 hex digits.
--- @param payload string Typed payload.
--- @param hash function SHA-256 port, bytes to lowercase hex.
--- @return string text
function M.envelope(identity, payload, hash)
	return identity .. "\n" .. checked_hash(hash, payload, "the payload") .. "\n" .. payload
end

--- Opens a cache file text. Raises a table `{ stale = true }` for a well-formed
--- cache of another identity, and a string for a corrupt one.
--- @param text string Cache file bytes.
--- @param identity string Expected identity.
--- @param hash function SHA-256 port.
--- @return table model
function M.open_envelope(text, identity, hash)
	if type(text) ~= "string" then error("registry cache envelope could not be read", 0) end
	local cached_identity, checksum, start = text:match("^(%x+)\n(%x+)\n()")
	if cached_identity == nil or #cached_identity ~= 64 or #checksum ~= 64 or cached_identity:match("%u")
		or checksum:match("%u") then
		error("registry cache envelope is malformed", 0)
	end
	if cached_identity ~= identity then
		error({ stale = true, detail = "registry cache was built from another parser or registry" }, 0)
	end
	local payload = text:sub(start)
	if checked_hash(hash, payload, "the payload") ~= checksum then error("registry cache payload checksum does not match", 0) end
	return M.decode(payload)
end

--- Identity of the parser: every file that decides what the cached model is.
--- @param ports table Initialized ports.
--- @return string identity 64 hex digits.
local function parser_identity(ports)
	local paths = {}
	local codec_path = package.searchpath("core.text.engine.toml_codec.codec", package.path)
	if not codec_path then error("registry parser identity could not find the TOML codec", 0) end
	local codec_dir = codec_path:match("^(.*)/[^/]+$")
	local names = ports.list_dir(codec_dir)
	local listed = {}
	for _, name in ipairs(names) do
		if name:match("%.lua$") then listed[#listed + 1] = name end
	end
	-- An empty folder would fence nothing: a parser change would keep the cache.
	if #listed == 0 then error("registry parser identity found no TOML parser source", 0) end
	table.sort(listed)
	for _, name in ipairs(listed) do paths[#paths + 1] = codec_dir .. "/" .. name end
	for _, module in ipairs(IDENTITY_MODULES) do
		local path = package.searchpath(module, package.path)
		if not path then error("registry parser identity could not find " .. module, 0) end
		paths[#paths + 1] = path
	end
	local lines = { "typed-registry-cache-v1", _VERSION }
	for _, path in ipairs(paths) do
		local bytes, detail = ports.read(path)
		if type(bytes) ~= "string" then
			error("registry parser identity could not read '" .. path .. "' (" .. tostring(detail) .. ")", 0)
		end
		lines[#lines + 1] = path:match("[^/]+$") .. ":" .. checked_hash(ports.hash, bytes, path)
	end
	return checked_hash(ports.hash, table.concat(lines, "\n"), "the parser identity")
end




-- =====================================
-- =====================================
-- ======= 4/ Native ports =============
-- =====================================
-- =====================================

--- Reads a whole file; nil and a detail when it is missing or unreadable.
local function native_read(path)
	local handle, open_error = io.open(path, "rb")
	if not handle then return nil, open_error end
	local bytes, read_error = handle:read("a")
	local closed = handle:close()
	if type(bytes) ~= "string" or not closed then return nil, read_error or "close failed" end
	return bytes
end

--- Publishes bytes through a sibling stage and a rename.
local function native_write(path, bytes)
	local stage = path .. ".stage"
	local handle, open_error = io.open(stage, "wb")
	if not handle then return nil, open_error end
	local written, write_error = handle:write(bytes)
	local closed, close_error = handle:close()
	if not written or not closed then
		os.remove(stage)
		return nil, write_error or close_error
	end
	local renamed, rename_error = os.rename(stage, path)
	if not renamed then
		os.remove(stage)
		return nil, rename_error
	end
	return true
end

--- Lists a folder's entries through Hammerspoon.
local function native_list_dir(dir)
	local names = {}
	for name in hs.fs.dir(dir) do
		if name ~= "." and name ~= ".." then names[#names + 1] = name end
	end
	return names
end

--- Creates the cache folder through Hammerspoon; true when it exists.
local function native_ensure_dir(dir)
	local attributes = hs.fs.attributes(dir)
	if attributes then return attributes.mode == "directory" end
	local parent = dir:match("^(.*)/[^/]+$")
	if parent and parent ~= "" and not native_ensure_dir(parent) then return false end
	return hs.fs.mkdir(dir) == true
end

local NATIVE_PORTS = {
	hash = function(bytes) return hs.hash.SHA256(bytes) end,
	read = native_read,
	write = native_write,
	list_dir = native_list_dir,
	ensure_dir = native_ensure_dir,
	clock = function() return hs.timer.absoluteTime() / 1e6 end,
}




-- =====================================
-- =====================================
-- ======= 5/ Public API ===============
-- =====================================
-- =====================================

--- Sets the cache file and the ports once; a second call is a defect.
--- @param opts table `{ cache_path, ports? }`; ports default to Hammerspoon.
function M.init(opts)
	if _state ~= nil then error("registry cache is already initialized", 2) end
	if type(opts) ~= "table" or type(opts.cache_path) ~= "string" or opts.cache_path == "" then
		error("registry cache needs a cache_path", 2)
	end
	local ports = {}
	for name, native in pairs(NATIVE_PORTS) do
		ports[name] = opts.ports and opts.ports[name] or native
		if type(ports[name]) ~= "function" then error("registry cache port '" .. name .. "' is not a function", 2) end
	end
	_state = { cache_path = opts.cache_path, ports = ports }
end

--- Forgets the initialization; tests only.
function M._reset() _state = nil end

--- Reads and validates the registry, from the cache when its identity holds.
--- Same contract as migrate.load_registry, which config_migrate.run accepts
--- as its `registry_loader`.
--- @param path string Absolute path of migrations.toml.
--- @return table|nil registry Issued by migrate.validate_registry.
--- @return string|nil detail
function M.load_registry(path)
	if _state == nil then error("registry cache is not initialized", 2) end
	if type(path) ~= "string" or path == "" then return nil, "no registry path" end
	local ports, cache_path = _state.ports, _state.cache_path
	local source, read_error = ports.read(path)
	if type(source) ~= "string" then
		return nil, "the registry '" .. path .. "' could not be read (" .. tostring(read_error) .. ")"
	end
	local started = ports.clock()
	local identity_ok, identity = pcall(function()
		return checked_hash(ports.hash, parser_identity(ports) .. ":" .. checked_hash(ports.hash, source, path),
			"the registry identity")
	end)
	if not identity_ok then
		Logger.warn(LOG, "Registry cache identity failed: %s; parsing the authoritative source.", tostring(identity))
		identity = nil
	end
	if identity then
		local text = ports.read(cache_path)
		if text ~= nil then
			local opened, model = pcall(M.open_envelope, text, identity, ports.hash)
			if opened then
				local registry, detail = Migrate.validate_registry(model)
				if registry then
					Logger.info(LOG, "Registry parse cache hit, validated in %.1f ms.", ports.clock() - started)
					return registry
				end
				Logger.warn(LOG, "Registry parse cache refused: its model fails validation (%s); "
					.. "parsing the authoritative source.", tostring(detail))
			elseif type(model) == "table" and model.stale then
				Logger.info(LOG, "Registry parse cache is stale: %s; parsing the authoritative source.", model.detail)
			else
				Logger.warn(LOG, "Registry parse cache refused: %s; parsing the authoritative source.", tostring(model))
			end
		end
	end
	local decoded_ok, decoded = pcall(TomlCodec.decode, source)
	if not decoded_ok or type(decoded) ~= "table" then
		return nil, "the registry '" .. path .. "' is not valid TOML"
	end
	-- Encoded before validation hands the model's tables to the runtime.
	local encoded_ok, payload = pcall(M.encode, decoded)
	local registry, detail = Migrate.validate_registry(decoded)
	if not registry then return nil, detail end
	Logger.info(LOG, "Registry parse cache miss, authoritative parse validated in %.1f ms.", ports.clock() - started)
	if identity == nil then return registry end
	if not encoded_ok then
		Logger.warn(LOG, "Registry cache could not be encoded: %s.", tostring(payload))
		return registry
	end
	local dir = cache_path:match("^(.*)/[^/]+$")
	local written, write_error = false, "the cache folder could not be created"
	if dir and ports.ensure_dir(dir) then
		written, write_error = ports.write(cache_path, M.envelope(identity, payload, ports.hash))
	end
	if written then
		Logger.info(LOG, "Registry parse cache published (%d payload bytes).", #payload)
	else
		Logger.warn(LOG, "Registry cache could not be published: %s.", tostring(write_error))
	end
	return registry
end

return M
