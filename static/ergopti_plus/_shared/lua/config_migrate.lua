--- _shared/lua/config_migrate.lua

--- ==============================================================================
--- MODULE: Config Migration (shared Lua engine)
--- DESCRIPTION:
--- Versions a driver's config.toml at boot. It reads ``[_meta] schema_version``,
--- runs the shared registry's steps for this driver in order, and publishes the
--- migrated file once, after a verified byte-exact backup. The Lua counterpart
--- of windows/infra/config_migrate.ahk, shared by the macOS and Linux drivers;
--- the registry is _shared/core/config_schema/migrations.toml and the decision
--- record docs/adr/009-config-versioning.md.
---
--- FEATURES & RATIONALE:
--- 1. Data-only steps. A step is a list of ops from a closed set (rename,
---    move_section, merge_into, map_value, delete, set_if_absent). The engine
---    holds the only op semantics on this side; the corpus under
---    _shared/tests/corpus/config_migrations pins them to the Windows
---    interpreter and to the JS reference, and the registry defects under
---    _shared/tests/corpus/config_migration_registries pin which registries
---    all three accept.
--- 2. One flat model. A section is a ``[header]`` path and a key is one entry
---    inside it; arrays and inline tables are opaque values. Records the text
---    cannot address (quoted keys, arrays of tables, root keys) are invisible
---    to ops and kept byte for byte.
--- 3. Byte-preserving publication. Only the records an op changed are cut,
---    rewritten or appended; comments, order and every other byte survive. The
---    candidate is decoded again and must equal the migrated model before it
---    can replace the file, and the stamp is set after every op.
--- 4. A file this build cannot version is never written. A newer, invalid or
---    unreadable file, or a failed migration, makes every later write to that
---    path refuse for the session through toml_codec.writer, and logs ERROR.
--- 5. A file this build writes stays versioned. For an absent, current or
---    migrated file the stamp becomes the row toml_codec.writer adds when a
---    writer creates the file, so a later boot never reads a file this build
---    created as an unstamped, older one.
--- ==============================================================================

local M = {}
local SourceIdentity = require("module_source_identity")
local source_sibling, source_same = SourceIdentity.sibling, SourceIdentity.same
local source_directory = require("module_source_directory").capture()

-- Resolved softly, like toml_codec.writer: macOS has its ring-buffer logger,
-- the Linux daemon and the LuaJIT runners use the shim.
local _ok_log, Logger = pcall(require, "infra.logger")
if not _ok_log or type(Logger) ~= "table" then
	Logger = require("logger.shim")
end
local TomlCodec  = require("toml_codec")
local writer_bindings = setmetatable({}, { __mode = "k" })
local TomlWriter, native_reader, native_publisher
local function writer()
	local published = rawget(package.loaded, "toml_codec.writer")
	if type(published) ~= "table" then published = require("toml_codec.writer") end
	local ports = writer_bindings[published]
	assert(type(ports) == "function", "migration writer was not issued by the constructor")
	local origin, reader, publisher = ports()
	assert(rawequal(origin, published) and type(reader) == "function"
		and type(publisher) == "function", "migration writer origin is invalid")
	TomlWriter, native_reader, native_publisher = published, reader, publisher
	return TomlWriter
end
local function writer_live(origin)
	local published = rawget(package.loaded, "toml_codec.writer")
	if not rawequal(published, origin or TomlWriter) then return false end
	local ports = writer_bindings[published]
	if type(ports) ~= "function" then return false end
	local issued, reader, publisher, preparation = ports()
	return rawequal(issued, published) and rawequal(rawget(published, "read_classified"), reader)
		and rawequal(rawget(published, "publish_if_unchanged"), publisher)
		and rawequal(rawget(published, "preparation_admission"), preparation)
end
local LeafRows   = require("toml_codec.leaf_rows")
local Records
local function records()
	if Records == nil then Records = require("config_unused_keys") end
	return Records
end
local LOG        = "config_migrate"
local canonical_decode = assert(rawget(TomlCodec, "decode_with_shapes"))

-- The native initializer's pure receipt retains original methods, including
-- absence. Generic unregistered adapter seams need no native constructor;
-- a boot destination captures only an actual initializer owner/issuer tuple.
-- This assumes the trusted normal loader, not hostile searcher/debug mutation.
local function native_configuration_ports(driver)
	local owner = rawget(package.loaded, "adapters.file_system")
	if owner == nil then owner = require("adapters.file_system") end
	if type(owner) ~= "table" then return nil end
	local issuer = rawget(owner, "configuration_ports")
	if type(issuer) ~= "function" then return nil end
	local source = debug.getinfo(1, "S").source
	local folder = driver == "hs" and "macos" or driver
	local expected = source_sibling(debug.getinfo(issuer, "S").source,
		folder .. "/adapters/file_system.lua", "_shared/lua/config_migrate.lua", source_directory)
	if not source_same(source, expected, source_directory) then return nil end
	local called, issued, reader, writer_method, publisher, remover, admitted_remover, exact_remover, delete = pcall(issuer)
	if not called or not rawequal(issued, owner) or type(reader) ~= "function"
		or type(writer_method) ~= "function" or type(publisher) ~= "function" or type(delete) ~= "function"
		or remover ~= nil and type(remover) ~= "function"
		or admitted_remover ~= nil and type(admitted_remover) ~= "function"
		or exact_remover ~= nil and type(exact_remover) ~= "function" then return nil end
	if not rawequal(rawget(owner, "read_with_status"), reader)
		or not rawequal(rawget(owner, "write_if_unchanged"), writer_method)
		or not rawequal(rawget(owner, "write_if_unchanged_admitted"), publisher)
		or not rawequal(rawget(owner, "remove_if_unchanged"), remover)
		or not rawequal(rawget(owner, "remove_if_unchanged_admitted"), admitted_remover)
		or not rawequal(rawget(owner, "remove_exact"), exact_remover)
		or not rawequal(rawget(owner, "delete"), delete) then return nil end
	return { owner = owner, issuer = issuer, reader = reader, writer = writer_method, publisher = publisher,
		remover = remover, admitted_remover = admitted_remover, exact_remover = exact_remover, delete = delete }
end

local BOM = string.char(0xEF, 0xBB, 0xBF)

--- The registry, relative to the _shared/ tree. Pinned to the Windows
--- interpreter's copy by tools/test/test-config-migrations.cjs.
M.REGISTRY_PATH = "core/config_schema/migrations.toml"

--- The section and key holding a file's version.
M.META_SECTION = "_meta"
M.VERSION_KEY  = "schema_version"

--- os.date format of the backup timestamp, the Windows "yyyyMMdd-HHmmss".
M.STAMP_FORMAT = "%Y%m%d-%H%M%S"

--- Driver identifiers a step may name.
M.DRIVERS = { ahk = true, hs = true, linux = true }

-- The only keys of [registry] and of a [steps.*] table. Anything else is a
-- defect every interpreter rejects: the shared registry-defect corpus pins it.
local REGISTRY_FIELDS = { current_version = true, unstamped_version = true }
local STEP_FIELDS = { from = true, to = true, drivers = true, reason = true, ops = true }

--- Fields of each op of the closed set.
local OPS = {
	rename        = { required = { "section", "key" }, optional = { "to_section", "to_key" } },
	copy_if_absent = { required = { "section", "key" }, optional = { "to_section", "to_key" } },
	move_ergopti_variant = { required = { "section", "key", "to_key", "base_key", "alt_gr_key", "source_key", "false_variant", "true_variant" }, optional = { "neutral_variant" } },
	move_chord_action = { required = { "section", "key", "to_section", "action", "conditional_key", "disabled_action", "platform" }, optional = {} },
	move_section  = { required = { "section", "to_section" }, optional = {} },
	merge_into    = { required = { "section", "to_section" }, optional = {} },
	map_value     = { required = { "section", "key", "map" }, optional = {} },
	delete        = { required = { "section" }, optional = { "key" } },
	set_if_absent = { required = { "section", "key", "value" }, optional = {} },
}





-- ==========================
-- ==========================
-- ======= 1/ Helpers =======
-- ==========================
-- ==========================

--- Whether a value is a positive integral number (a TOML 3.0 counts as 3).
--- @param value any
--- @return boolean
local function is_version(value)
	return type(value) == "number" and value >= 1 and value == math.floor(value) and value < 2 ^ 53
end

-- The constructor owns these destinations. Public defaults/rows and a copied
-- module cannot grant readiness. The normal loader constructs one journal;
-- arbitrary replacement searchers/debug mutation are outside this boundary.
local destinations = {}
local validated_registries = setmetatable({}, { __mode = "k" })
local admission_factory

local function detached(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = detached(child) end
	return copy
end

-- Resolve only a journal key, never rewrite a native path or fold its case.
-- Dot spellings of a known destination are refused: '..' through a symlink
-- does not establish physical equivalence to the lexically reduced path.
local function destination_key(path)
	local spelling = tostring(path):gsub("\\", "/"):gsub("/+", "/")
	local parts, ambiguous = {}, false
	for part in spelling:gmatch("[^/]+") do
		if part == "." then ambiguous = true
		elseif part == ".." then
			ambiguous = true
			if #parts > 0 and parts[#parts] ~= ".." then table.remove(parts)
			else parts[#parts + 1] = part end
		else parts[#parts + 1] = part end
	end
	return (spelling:sub(1, 1) == "/" and "/" or "") .. table.concat(parts, "/"), ambiguous
end

local function current_schema(source, version)
	if type(source) ~= "table" then return false end
	if source.status == "absent" then return true end
	if source.status ~= "ok" or type(source.content) ~= "string" then return false end
	local called, document, shapes = pcall(canonical_decode, source.content)
	if not called or type(document) ~= "table" or type(shapes) ~= "table" then return false end
	local meta = document._meta
	return type(meta) == "table" and shapes.arrays[meta] ~= true
		and is_version(meta.schema_version) and meta.schema_version == version
end

local function native_ports_live(record)
	local owner = record.port_owner
	return owner == nil or rawequal(rawget(package.loaded, "adapters.file_system"), owner)
		and rawequal(rawget(owner, "configuration_ports"), record.port_issuer)
		and rawequal(rawget(owner, "read_with_status"), record.port_reader)
		and rawequal(rawget(owner, "write_if_unchanged"), record.port_writer)
		and rawequal(rawget(owner, "write_if_unchanged_admitted"), record.port_publisher)
		and rawequal(rawget(owner, "remove_if_unchanged"), record.port_conditional_remover)
		and rawequal(rawget(owner, "remove_if_unchanged_admitted"), record.port_remover)
		and rawequal(rawget(owner, "remove_exact"), record.port_exact_remover)
		and rawequal(rawget(owner, "delete"), record.port_delete)
end
local function native_port_admitted(record, adapter)
	if adapter == nil then return record.shared_native end
	return record.port_owner ~= nil and rawequal(adapter, record.port_owner) and native_ports_live(record)
end
local function destination_live(record)
	return writer_live(record.writer) and native_ports_live(record)
		and rawequal(rawget(TomlCodec, "decode_with_shapes"), canonical_decode)
		and rawequal(rawget(package.loaded, "config_migrate"), M)
		and rawequal(rawget(M, "writer_admission_factory"), admission_factory)
		and rawequal(destinations[record.key], record)
end

local function capture_admission(path, source, candidate, operation, adapter)
	local key, ambiguous = destination_key(path)
	local record = destinations[key]
	if record == nil then return nil end
	if ambiguous or not destination_live(record) or not native_port_admitted(record, adapter) then return false end
	local snapshot = { status = source.status, content = source.content }
	local migration = record.publication
	if operation == "publish" and migration ~= nil and not migration.consumed
		and snapshot.status == migration.status and snapshot.content == migration.source
		and candidate == migration.candidate then
		migration.consumed = true
		return function()
			return destination_live(record) and rawequal(record.publication, migration)
				and migration.consumed and current_schema({ status = "ok", content = candidate }, record.current)
		end, snapshot
	end
	if record.phase ~= "ready" or not current_schema(snapshot, record.current)
		or candidate ~= nil and not current_schema({ status = "ok", content = candidate }, record.current) then
		return false
	end
	return function()
		return destination_live(record) and record.phase == "ready"
			and current_schema(snapshot, record.current)
			and (candidate == nil or current_schema({ status = "ok", content = candidate }, record.current))
	end, snapshot
end

local function read_admitted(path, adapter)
	local key, ambiguous = destination_key(path)
	local record = destinations[key]
	if record == nil then return nil end
	if ambiguous or not destination_live(record) or not native_port_admitted(record, adapter) then return false end
	if record.reading then
		record.reading = nil
		return function() return destination_live(record) end
	end
	-- A version-refused boot may still read precisely the validated physical
	-- image it captured. This grants no READY state or publication admission.
	local refused_source = record.version_refused_source
	if record.phase == "preparing" and type(refused_source) == "string" then
		return function(content, status)
			return destination_live(record) and record.phase == "preparing"
				and record.version_refused_source == refused_source
				and status == "ok" and content == refused_source
		end
	end
	if record.phase ~= "ready" then return false end
	return function(content, status)
		return destination_live(record) and record.phase == "ready"
			and current_schema({ status = status, content = content }, record.current)
	end
end

--- Captures the constructor's checking functions; it exposes no phase setter.
--- Writer calls this during real construction and pins the exact origin/factory.
--- @return table origin
--- @return function capture
--- @return function read_check
admission_factory = function(origin, ports)
	if origin ~= nil then
		-- Only the canonical initializer performs this handoff. A public call,
		-- copied module or replacement getter cannot register native ports. This
		-- is loader-cooperative authentication, not a hostile-searcher sandbox.
		local caller = debug.getinfo(2, "S")
		local own = debug.getinfo(1, "S").source
		local expected = source_sibling(own, "config_migrate.lua", "toml_codec/writer.lua", source_directory)
		assert(type(origin) == "table" and type(ports) == "function" and caller.what == "main"
			and source_same(caller.source, expected, source_directory), "writer admission must originate in its canonical constructor")
		assert(writer_bindings[origin] == nil, "writer constructor was already issued")
		writer_bindings[origin] = ports
	end
	return M, capture_admission, read_admitted
end
M.writer_admission_factory = admission_factory

--- A version as an integer where the runtime has an integer subtype, so every
--- writer renders it ``3`` and never ``3.0``.
--- @param value number A value is_version accepted.
--- @return number
local function as_integer(value)
	return math.tointeger and math.tointeger(value) or value
end

--- Type-strict deep equality; numbers compare by value.
--- @param left any
--- @param right any
--- @return boolean
local function same_value(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do
		if not same_value(value, right[key]) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end
M.same_value = same_value

--- Whether text is a dotted path of bare segments.
--- @param text any
--- @return boolean
local function is_section_path(text)
	if type(text) ~= "string" or text == "" then return false end
	for segment in (text .. "."):gmatch("([^%.]*)%.") do
		if not segment:match("^[%w_%-]+$") then return false end
	end
	return true
end

local function is_bare_key(text)
	return type(text) == "string" and text:match("^[%w_%-]+$") ~= nil
end

local function is_scalar(value)
	local kind = type(value)
	return kind == "string" or kind == "number" or kind == "boolean"
end

--- Whether a decoded value is a TOML array. toml_codec decodes arrays and
--- inline tables into the same Lua tables, so only the keys tell them apart
--- (an empty inline table stays indistinguishable from an empty array).
--- @param value any
--- @return boolean
local function is_array(value)
	if type(value) ~= "table" then return false end
	local count = 0
	for _ in pairs(value) do count = count + 1 end
	return count == #value
end

--- Sorted keys of a table.
local function sorted_keys(map)
	local keys = {}
	for key in pairs(map) do keys[#keys + 1] = key end
	table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
	return keys
end

--- Formats a version for a log line without a Lua 5.4 float suffix.
local function version_text(value)
	if type(value) == "number" and value == math.floor(value) then
		return string.format("%d", value)
	end
	return tostring(value)
end





-- ===========================
-- ===========================
-- ======= 2/ Registry =======
-- ===========================
-- ===========================

--- Validates one op against the closed set.
--- @param op any
--- @return boolean ok
--- @return string|nil detail
local function validate_op(op)
	if type(op) ~= "table" then return false, "an op must be a table" end
	local spec = OPS[op.op]
	if not spec then return false, "unknown op '" .. tostring(op.op) .. "'" end
	local allowed = { op = true }
	for _, field in ipairs(spec.required) do
		allowed[field] = true
		if op[field] == nil then return false, op.op .. " needs '" .. field .. "'" end
	end
	for _, field in ipairs(spec.optional) do allowed[field] = true end
	for field in pairs(op) do
		if not allowed[field] then return false, op.op .. " does not take '" .. tostring(field) .. "'" end
	end
	for _, field in ipairs({ "section", "to_section" }) do
		if op[field] ~= nil and not is_section_path(op[field]) then
			return false, "'" .. field .. "' must be a dotted path of bare segments"
		end
	end
	for _, field in ipairs({ "key", "to_key", "conditional_key" }) do
		if op[field] ~= nil and not is_bare_key(op[field]) then
			return false, "'" .. field .. "' must be one bare segment"
		end
	end
	if (op.op == "rename" or op.op == "copy_if_absent") and op.to_section == nil and op.to_key == nil then
		return false, op.op .. " needs to_section or to_key"
	end
	if op.op == "move_ergopti_variant" then
		for _, field in ipairs({ "base_key", "alt_gr_key", "source_key", "false_variant", "true_variant" }) do
			if not is_bare_key(op[field]) then return false, "variant intent fields must be declared bare identifiers" end
		end
		if op.key == op.to_key or op.false_variant == op.true_variant then
			return false, "variant handoff requires distinct source, destination and choices"
		end
		if op.neutral_variant ~= nil and (not is_bare_key(op.neutral_variant) or op.neutral_variant == op.false_variant or op.neutral_variant == op.true_variant) then
			return false, "neutral variant must be a distinct declared bare identifier"
		end
		local seen = {}
		for _, field in ipairs({ "key", "to_key", "base_key", "alt_gr_key", "source_key" }) do
			if seen[op[field]] then return false, "variant intent participants must be distinct" end
			seen[op[field]] = true
		end
	end
	if op.op == "move_chord_action" then
		if op.platform ~= "macos" then return false, "move_chord_action requires platform macos" end
		for _, field in ipairs({ "action", "disabled_action" }) do
			if not is_bare_key(op[field]) then return false, "'" .. field .. "' must be an action id" end
		end
		if op.section == op.to_section then return false, "move_chord_action must change section" end
	end
	if op.op == "map_value" then
		if not is_array(op.map) or #op.map == 0 then return false, "map_value needs a non-empty map" end
		for _, pair in ipairs(op.map) do
			if type(pair) ~= "table" or not is_scalar(pair.from) or not is_scalar(pair.to) then
				return false, "each map entry is { from, to } with scalar values"
			end
			for field in pairs(pair) do
				if field ~= "from" and field ~= "to" then
					return false, "each map entry is { from, to } with scalar values"
				end
			end
		end
	end
	if op.op == "set_if_absent" and not is_scalar(op.value) then
		if not is_array(op.value) then return false, "set_if_absent writes a scalar or an array" end
		for _, item in ipairs(op.value) do
			if not is_scalar(item) then return false, "set_if_absent arrays hold scalars only" end
		end
	end
	return true
end

--- Validates a decoded registry and returns it in execution order.
--- @param decoded table Decoded migrations.toml.
--- @return table|nil registry `{ current, unstamped, steps = { { from, to, drivers, reason, ops } } }`.
--- @return string|nil detail
function M.validate_registry(decoded)
	if type(decoded) ~= "table" or type(decoded.registry) ~= "table" then
		return nil, "the registry has no [registry] table"
	end
	for name in pairs(decoded) do
		if name ~= "registry" and name ~= "steps" then
			return nil, "the registry has an unknown table [" .. tostring(name) .. "]"
		end
	end
	for field in pairs(decoded.registry) do
		if not REGISTRY_FIELDS[field] then
			return nil, "[registry] has an unknown key '" .. tostring(field) .. "'"
		end
	end
	if decoded.steps ~= nil and type(decoded.steps) ~= "table" then
		return nil, "steps must be [steps.v<N>_to_v<N+1>] tables"
	end
	local current = decoded.registry.current_version
	local unstamped = decoded.registry.unstamped_version
	if not is_version(current) or not is_version(unstamped) or unstamped > current then
		return nil, "current_version and unstamped_version must be integers with 1 <= unstamped <= current"
	end
	local steps = {}
	for name, step in pairs(decoded.steps or {}) do
		if type(step) ~= "table" or not is_version(step.from) or step.to ~= step.from + 1 then
			return nil, "step '" .. tostring(name) .. "' must go from N to N + 1"
		end
		for field in pairs(step) do
			if not STEP_FIELDS[field] then
				return nil, "step '" .. tostring(name) .. "' has an unknown field '" .. tostring(field) .. "'"
			end
		end
		if name ~= "v" .. version_text(step.from) .. "_to_v" .. version_text(step.to) then
			return nil, "step '" .. tostring(name) .. "' is misnamed"
		end
		if not is_array(step.drivers) or #step.drivers == 0 then
			return nil, "step '" .. name .. "' names no driver"
		end
		local drivers = {}
		for _, driver in ipairs(step.drivers) do
			if not M.DRIVERS[driver] then return nil, "step '" .. name .. "' names unknown driver '" .. tostring(driver) .. "'" end
			drivers[driver] = true
		end
		if type(step.reason) ~= "string" or step.reason:match("^%s*$") then
			return nil, "step '" .. name .. "' has no reason"
		end
		if not is_array(step.ops) then return nil, "step '" .. name .. "' has no ops array" end
		for index, op in ipairs(step.ops) do
			local ok, detail = validate_op(op)
			if not ok then return nil, "step '" .. name .. "' op " .. index .. ": " .. detail end
		end
		steps[#steps + 1] = { from = step.from, to = step.to, drivers = drivers, reason = step.reason, ops = step.ops }
	end
	table.sort(steps, function(left, right) return left.from < right.from end)
	if #steps ~= current - unstamped then
		return nil, "the steps do not chain v" .. version_text(unstamped) .. " to v" .. version_text(current)
	end
	for index, step in ipairs(steps) do
		if step.from ~= unstamped + index - 1 then
			return nil, "the chain has a gap at v" .. version_text(step.from)
		end
	end
	local registry = { current = as_integer(current), unstamped = as_integer(unstamped), steps = steps }
	validated_registries[registry] = detached(registry)
	return registry
end

--- Reads and validates a registry file.
--- @param path string Absolute path of migrations.toml.
--- @param file_adapter table|nil Platform file adapter.
--- @return table|nil registry
--- @return string|nil detail
function M.load_registry(path, file_adapter)
	if type(path) ~= "string" or path == "" then return nil, "no registry path" end
	local content, status, detail = writer().read_classified(path, file_adapter)
	if status ~= "ok" or type(content) ~= "string" then
		return nil, "the registry '" .. path .. "' could not be read (" .. tostring(detail or status) .. ")"
	end
	local ok, decoded = pcall(TomlCodec.decode, content)
	if not ok or type(decoded) ~= "table" then
		return nil, "the registry '" .. path .. "' is not valid TOML"
	end
	return M.validate_registry(decoded)
end





-- =============================
-- =============================
-- ======= 3/ Flat Model =======
-- =============================
-- =============================

--- Reads a decoded value at a segment path.
local function value_at(decoded, path)
	local node = decoded
	for _, segment in ipairs(path) do
		if type(node) ~= "table" then return nil end
		node = node[segment]
	end
	return node
end

--- Builds the flat model of a config source.
--- Every entry is a table `{ value, record? }`; an op moves the entry itself,
--- so the renderer can tell a moved record from one it must rewrite.
--- @param source string Exact file content.
--- @return table|nil model `{ sections = { [section] = { [key] = entry } } }`.
--- @return table|string scan_or_error The record scan, or a failure detail.
function M.model_from_source(source)
	if type(source) ~= "string" then return nil, "no source" end
	local decoded_ok, decoded = pcall(TomlCodec.decode, source)
	if not decoded_ok or type(decoded) ~= "table" then return nil, "the file is not valid TOML" end
	local scan, scan_err = records().scan_records(source)
	if not scan then return nil, scan_err end
	local sections, opaque_sections = {}, {}
	for _, header in ipairs(scan.headers) do
		if header.section and not header.array and sections[header.section] == nil then
			sections[header.section] = {}
		end
		if header.array and header.segments then opaque_sections[table.concat(header.segments, ".")] = true end
	end
	for _, record in ipairs(scan.records) do
		if record.addressable then
			sections[record.section][record.key] = { value = value_at(decoded, record.path), record = record }
		elseif record.header and record.header.segments then
			opaque_sections[table.concat(record.header.segments, ".")] = true
		end
	end
	return { sections = sections, opaque_sections = opaque_sections }, scan
end

--- A copy of the model sharing its entry objects.
local function clone_model(model)
	local sections = {}
	for name, entries in pairs(model.sections) do
		local copy = {}
		for key, entry in pairs(entries) do copy[key] = entry end
		sections[name] = copy
	end
	return { sections = sections, opaque_sections = model.opaque_sections }
end

--- `{ [section] = { [key] = value } }` without sections holding no key: an
--- empty table and an absent one are the same configuration.
--- @param model table
--- @return table
function M.plain(model)
	local out = {}
	for name, entries in pairs(model.sections) do
		if next(entries) ~= nil then
			local values = {}
			for key, entry in pairs(entries) do values[key] = entry.value end
			out[name] = values
		end
	end
	return out
end





-- ======================
-- ======================
-- ======= 4/ Ops =======
-- ======================
-- ======================

local function sections_at_or_below(sections, name)
	local out = {}
	local prefix = name .. "."
	for section in pairs(sections) do
		if section == name or section:sub(1, #prefix) == prefix then out[#out + 1] = section end
	end
	table.sort(out)
	return out
end

local function drop_if_empty(sections, name)
	if sections[name] ~= nil and next(sections[name]) == nil then sections[name] = nil end
end

--- Moves one entry; an existing target keeps its value.
local function move_entry(sections, section, key, to_section, to_key)
	local source = sections[section]
	if source == nil or source[key] == nil then return end
	local entry = source[key]
	source[key] = nil
	if sections[to_section] == nil then sections[to_section] = {} end
	if sections[to_section][to_key] == nil then
		sections[to_section][to_key] = entry
	else
		Logger.info(LOG, "[%s] %s already holds a value; the old [%s] %s is dropped.",
			to_section, to_key, section, key)
	end
end

local APPLY = {}

function APPLY.rename(sections, op)
	local to_section = op.to_section or op.section
	move_entry(sections, op.section, op.key, to_section, op.to_key or op.key)
	drop_if_empty(sections, op.section)
	drop_if_empty(sections, to_section)
end

--- Explicit ancestor values and child tables also occupy a destination path.
--- A conditional copy must not replace them or extend a closed inline value.
local function copy_destination_absent(sections, section, key)
	if sections[section] and sections[section][key] ~= nil then return false end
	local path = section
	while true do
		local parent, name = path:match("^(.*)%.([^%.]+)$")
		if not parent then parent, name = "", path end
		if sections[parent] and sections[parent][name] ~= nil then return false end
		if parent == "" then break end
		path = parent
	end
	local destination = section .. "." .. key
	return #sections_at_or_below(sections, destination) == 0
end

local VARIANT_REFUSAL = "Ergopti variant migration refused:"


-- Every new operation names jointly retained physical and semantic owners.
-- A root scalar, inline record, quoted leaf or array namespace is not an
-- absent participant just because the addressable flat model omits it.
local function variant_parts_under(parts, prefix)
	if type(parts) ~= "table" or #parts < #prefix then return false end
	for index, part in ipairs(prefix) do if parts[index] ~= part then return false end end
	return true
end

local function variant_source_witness(source, scan, before, operations)
	local decoded
	for _, op in ipairs(operations) do
		if op.op == "move_ergopti_variant" then
			decoded = decoded or TomlCodec.decode(source)
			local entries = before.sections[op.section] or {}
			local function refuse(detail) error(VARIANT_REFUSAL .. " " .. detail, 0) end
			for _, field in ipairs({ "key", "to_key", "base_key", "alt_gr_key", "source_key" }) do
				local parts = {}; for segment in op.section:gmatch("[^.]+") do parts[#parts + 1] = segment end
				parts[#parts + 1] = op[field]
				local value = decoded
				for _, segment in ipairs(parts) do
					if value == nil then break end
					if type(value) ~= "table" then refuse("joint source has an occupied ancestor") end
					value = value[segment]
				end
				if (value ~= nil) ~= (entries[op[field]] ~= nil) then refuse("joint source ownership disagrees") end
				if value ~= nil and not same_value(value, entries[op[field]].value) then refuse("joint source types disagree") end
				for _, record in ipairs(scan.records) do
					if variant_parts_under(record.path, parts) or variant_parts_under(parts, record.path or {}) then
						if not record.addressable or #record.path ~= #parts then
							refuse("joint source is not an addressable physical leaf")
						end
					end
				end
				for section in pairs(before.opaque_sections or {}) do
					if op.section == section or op.section:sub(1, #section + 1) == section .. "." then
						refuse("joint source has an opaque table namespace")
					end
				end
			end
		end
	end
end

function APPLY.move_ergopti_variant(sections, op)
	local source = sections[op.section] or {}
	local function refuse(detail) error(VARIANT_REFUSAL .. " " .. detail, 0) end
	for _, field in ipairs({ "key", "to_key", "base_key", "alt_gr_key", "source_key" }) do
		local view = {}
		for name, entries in pairs(sections) do
			local copy = {}; for key, entry in pairs(entries) do copy[key] = entry end
			view[name] = copy
		end
		if view[op.section] then view[op.section][op[field]] = nil end
		if not copy_destination_absent(view, op.section, op[field]) then
			refuse("an intent participant has an occupied namespace")
		end
	end
	for _, field in ipairs({ "base_key", "alt_gr_key" }) do
		if source[op[field]] and type(source[op[field]].value) ~= "boolean" then
			refuse("an independent layer gate is not an exact TOML boolean")
		end
	end
	local selected = source[op.source_key]
	if selected and (type(selected.value) ~= "string" or (selected.value ~= "" and not selected.value:match("^[a-z][a-z0-9_]*$"))) then
		refuse("the registry source intent is malformed")
	end
	local target = source[op.to_key]
	if target and (type(target.value) ~= "string" or (target.value ~= op.false_variant and target.value ~= op.true_variant and target.value ~= op.neutral_variant)) then
		refuse("the new variant is not a recognized exact choice")
	end
	local legacy = source[op.key]
	if not legacy then return end
	if type(legacy.value) ~= "boolean" then refuse("the historical variant is not an exact TOML boolean") end
	local variant = legacy.value and op.true_variant or op.false_variant
	if target and target.value ~= variant then refuse("recognized old and new variants conflict") end
	-- All typed/source/namespace witnesses precede source consumption.
	source[op.to_key] = { value = variant }
	source[op.key] = nil
end

function APPLY.copy_if_absent(sections, op)
	local source = sections[op.section]
	if source == nil or source[op.key] == nil then return end
	local to_section, to_key = op.to_section or op.section, op.to_key or op.key
	local target = sections[to_section]
	if not copy_destination_absent(sections, to_section, to_key) then return end
	if target == nil then target = {}; sections[to_section] = target end
	local entry = source[op.key]
	target[to_key] = { value = LeafRows.clone_value(entry.value), record = entry.record }
end

--- Resolve physical aliases exclusively through the injected canonical catalogue.
local function chord_action_slot(value, catalogue, platform_name)
	if type(value) ~= "table" or type(value.key) ~= "string" or not is_array(value.mods) then return nil end
	for field in pairs(value) do if field ~= "mods" and field ~= "key" then return nil end end
	local platform = catalogue.platforms[platform_name]
	local aliases, wanted = {}, {}
	for _, modifier in ipairs(platform.modifiers) do
		aliases[modifier.id] = modifier.id
		aliases[modifier.hammerspoon] = modifier.id
	end
	for _, modifier in ipairs(value.mods) do
		if type(modifier) ~= "string" then return nil end
		local id = aliases[modifier:lower()]
		if id == nil or wanted[id] then return nil end
		wanted[id] = true
	end
	local key_id
	for _, key in ipairs(catalogue.keys) do
		local candidate = value.key:lower()
		if candidate == key.id or candidate == (key.chord_key or key.id)
			or candidate == (key.macos_key or key.id) then key_id = key.id; break end
	end
	if key_id == nil then return nil end
	for _, group in ipairs(platform.shortcut_groups) do
		local matched = #group.modifiers == #value.mods
		for _, modifier in ipairs(group.modifiers) do if not wanted[modifier] then matched = false end end
		if matched then return group.prefix .. key_id end
	end
	return nil
end

--- Every destination must already be a recognized action or have a free namespace.
--- Resolve all choices before writing any of them, so unsupported values retain
--- their source record and its native owner unchanged.
function APPLY.move_chord_action(sections, op, context, model)
	local source = sections[op.section]
	local child_path = op.section .. "." .. op.key
	local child = sections[child_path]
	local value, child_source
	if source and source[op.key] then value = source[op.key].value
	elseif child then
		if #sections_at_or_below(sections, child_path) ~= 1 then return end
		for path in pairs(model and model.opaque_sections or {}) do
			if path == child_path or path:sub(1, #child_path + 1) == child_path .. "." then return end
		end
		value, child_source = {}, true
		for key, entry in pairs(child) do value[key] = entry.value end
	else return end
	local catalogue = context and context.modifier_chords
	local actions = context and context.assignable_actions
	local platform = catalogue and catalogue.platforms and catalogue.platforms[op.platform]
	if type(catalogue) ~= "table" or type(catalogue.keys) ~= "table" or type(platform) ~= "table"
		or type(platform.modifiers) ~= "table" or type(platform.shortcut_groups) ~= "table"
		or type(actions) ~= "table" then error("config_migrate: missing chord action context", 2) end
	if actions[op.action] ~= true or actions[op.disabled_action] ~= true then
		error("config_migrate: migration action is absent from the action catalogue", 2)
	end
	local slot = value ~= false and chord_action_slot(value, catalogue, op.platform) or nil
	if value ~= false and slot == nil then return end
	if slot == op.conditional_key then return end
	local target = sections[op.to_section]
	local function represented(key)
		local entry = target and target[key]
		if entry ~= nil then return type(entry.value) == "string" and actions[entry.value] == true end
		return copy_destination_absent(sections, op.to_section, key)
	end
	if not represented(op.conditional_key) or (slot and not represented(slot)) then return end
	if target == nil then target = {}; sections[op.to_section] = target end
	if slot and target[slot] == nil then target[slot] = { value = op.action } end
	if target[op.conditional_key] == nil then target[op.conditional_key] = { value = op.disabled_action } end
	if child_source then sections[child_path] = nil
	else source[op.key] = nil; drop_if_empty(sections, op.section) end
end

function APPLY.move_section(sections, op)
	for _, name in ipairs(sections_at_or_below(sections, op.section)) do
		local target = op.to_section .. name:sub(#op.section + 1)
		for _, key in ipairs(sorted_keys(sections[name])) do
			move_entry(sections, name, key, target, key)
		end
		sections[name] = nil
		drop_if_empty(sections, target)
	end
end

function APPLY.merge_into(sections, op)
	if sections[op.section] == nil then return end
	for _, key in ipairs(sorted_keys(sections[op.section])) do
		move_entry(sections, op.section, key, op.to_section, key)
	end
	sections[op.section] = nil
	drop_if_empty(sections, op.to_section)
end

function APPLY.map_value(sections, op)
	local entries = sections[op.section]
	local entry = entries and entries[op.key]
	if entry == nil then return end
	for _, pair in ipairs(op.map) do
		if same_value(pair.from, entry.value) then
			entries[op.key] = { value = pair.to }
			return
		end
	end
end

function APPLY.delete(sections, op)
	if op.key == nil then
		for _, name in ipairs(sections_at_or_below(sections, op.section)) do sections[name] = nil end
	elseif sections[op.section] ~= nil then
		sections[op.section][op.key] = nil
		drop_if_empty(sections, op.section)
	end
end

function APPLY.set_if_absent(sections, op)
	if sections[op.section] == nil then sections[op.section] = {} end
	if sections[op.section][op.key] == nil then sections[op.section][op.key] = { value = op.value } end
end

--- Reads a model's version against a registry.
--- @param model table
--- @param registry table
--- @return string outcome "current" | "migrate" | "newer" | "invalid" | "unsupported"
--- @return any version The file's version (the unstamped version when absent).
function M.classify(model, registry)
	local meta = model.sections[M.META_SECTION]
	local entry = meta and meta[M.VERSION_KEY]
	local version = registry.unstamped
	if entry ~= nil then
		version = entry.value
		if not is_version(version) then return "invalid", version end
	end
	if version > registry.current then return "newer", version end
	if version == registry.current then return "current", version end
	if version < registry.unstamped then return "unsupported", version end
	return "migrate", version
end

--- Runs every step at or above from_version for one driver, then stamps the
--- registry's current version. Mutates the model.
--- @param model table
--- @param registry table
--- @param driver string "ahk" | "hs" | "linux"
--- @param from_version number
--- @return table model
function M.apply_steps(model, registry, driver, from_version, context)
	if not M.DRIVERS[driver] then error("config_migrate: unknown driver '" .. tostring(driver) .. "'", 2) end
	for _, step in ipairs(registry.steps) do
		if step.from >= from_version and step.drivers[driver] then
			for _, op in ipairs(step.ops) do APPLY[op.op](model.sections, op, context, model) end
		end
	end
	if model.sections[M.META_SECTION] == nil then model.sections[M.META_SECTION] = {} end
	model.sections[M.META_SECTION][M.VERSION_KEY] = { value = registry.current }
	return model
end





-- ============================
-- ============================
-- ======= 5/ Rendering =======
-- ============================
-- ============================

--- The TOML text of an entry's value: the source text of a one-line record,
--- otherwise a fresh encoding.
local function value_text(entry)
	local record = entry.record
	if record and record.first == record.last and type(record.value) == "string" then
		return record.value
	end
	return TomlCodec.encode_value(entry.value)
end

--- Rewrites source into the migrated model, touching only changed records.
--- @param source string Exact file content.
--- @param scan table Record scan of source.
--- @param before table Model of source.
--- @param after table Migrated model.
--- @return string|nil candidate
--- @return string|nil detail
local function render(source, scan, before, after)
	local lines = scan.lines
	local eol = "\n"
	for _, line in ipairs(lines) do
		if line.eol ~= "" then eol = line.eol break end
	end
	local bom = lines[1] ~= nil and lines[1].text:sub(1, 3) == BOM

	local dropped, replaced, placed = {}, {}, {}
	local header_last = {}
	for _, record in ipairs(scan.records) do
		local header = record.header
		if header then header_last[header] = math.max(header_last[header] or header.index, record.last) end
		if record.addressable then
			local now = after.sections[record.section] and after.sections[record.section][record.key]
			if now == nil then
				for index = record.first, record.last do dropped[index] = true end
			else
				placed[record.section] = placed[record.section] or {}
				placed[record.section][record.key] = true
				if now ~= before.sections[record.section][record.key] then
					local indent = lines[record.first].text:match("^(%s*)") or ""
					replaced[record.first] = indent .. record.key .. " = " .. value_text(now)
					for index = record.first + 1, record.last do dropped[index] = true end
				end
			end
		end
	end

	local open_header = {}
	for _, header in ipairs(scan.headers) do
		if header.section and not header.array then
			if after.sections[header.section] == nil and before.sections[header.section] ~= nil then
				for _, record in ipairs(scan.records) do
					if record.header == header and not record.addressable then
						return nil, "section [" .. header.section .. "] holds entries the migration cannot rewrite"
					end
				end
				dropped[header.index] = true
			else
				open_header[header.section] = header
			end
		end
	end

	-- New keys go after the last record of their section's header, or into a
	-- new section: [_meta] before the first table, any other at the end.
	local after_line, before_line, appended = {}, {}, {}
	local first_header = nil
	for _, header in ipairs(scan.headers) do
		if not dropped[header.index] then first_header = header.index break end
	end
	for _, name in ipairs(sorted_keys(after.sections)) do
		local pending = {}
		for _, key in ipairs(sorted_keys(after.sections[name])) do
			if not (placed[name] and placed[name][key]) then
				pending[#pending + 1] = key .. " = " .. value_text(after.sections[name][key])
			end
		end
		local header = open_header[name]
		if header then
			if #pending > 0 then
				local anchor = header_last[header] or header.index
				after_line[anchor] = after_line[anchor] or {}
				for _, text in ipairs(pending) do table.insert(after_line[anchor], text) end
			end
		elseif #pending > 0 or next(after.sections[name]) == nil then
			local block = { "[" .. name .. "]" }
			for _, text in ipairs(pending) do block[#block + 1] = text end
			if name == M.META_SECTION and first_header then
				block[#block + 1] = ""
				before_line[first_header] = block
			else
				appended[#appended + 1] = block
			end
		end
	end

	local out = {}
	local function emit(text, line_eol)
		if #out > 0 and out[#out] == "" then out[#out] = eol end
		out[#out + 1] = text
		out[#out + 1] = line_eol
	end
	for index, line in ipairs(lines) do
		if before_line[index] then
			for _, text in ipairs(before_line[index]) do emit(text, eol) end
		end
		if not dropped[index] then
			local text = replaced[index] or line.text
			if index == 1 and bom and text:sub(1, 3) == BOM then text = text:sub(4) end
			emit(text, line.eol)
		end
		if after_line[index] then
			for _, text in ipairs(after_line[index]) do emit(text, eol) end
		end
	end
	for _, block in ipairs(appended) do
		if #out > 0 then emit("", eol) end
		for _, text in ipairs(block) do emit(text, eol) end
	end
	if #out > 0 and out[#out] == "" and source:sub(-1) == "\n" then out[#out] = eol end
	local candidate = table.concat(out)
	if bom then candidate = BOM .. candidate end
	return candidate
end

--- Plans the migration of one config source for one driver, without I/O.
--- @param source string Exact file content.
--- @param registry table Validated registry.
--- @param driver string "ahk" | "hs" | "linux"
--- @return table plan `{ outcome, version, candidate?, detail? }`; outcome is
---   "current", "migrated", "newer", "invalid", "unsupported" or "failed".
function M.plan(source, registry, driver, context)
	local before, scan = M.model_from_source(source)
	if not before then return { outcome = "failed", detail = scan } end
	local outcome, version = M.classify(before, registry)
	if outcome ~= "migrate" then return { outcome = outcome, version = version } end
	local applied, after = pcall(function()
		for _, step in ipairs(registry.steps) do
			if step.from >= version and step.drivers[driver] then
				variant_source_witness(source, scan, before, step.ops)
			end
		end
		return M.apply_steps(clone_model(before), registry, driver, version, context)
	end)
	if not applied then
		if tostring(after):sub(1, #VARIANT_REFUSAL) == VARIANT_REFUSAL then
			return { outcome = "invalid", version = version, detail = tostring(after) }
		end
		error(after, 0)
	end
	local candidate, render_err = render(source, scan, before, after)
	if not candidate then return { outcome = "failed", version = version, detail = render_err } end
	local reread = M.model_from_source(candidate)
	if not reread or not same_value(M.plain(reread), M.plain(after)) then
		return { outcome = "failed", version = version,
			detail = "the rewritten file would not read back as the migrated configuration" }
	end
	return { outcome = "migrated", version = version, candidate = candidate, model = after }
end

--- Plans validated record operations for an independently owned TOML file.
--- Unlike config schema migration, this leaves metadata and version stamps alone.
--- @param source string Exact file bytes.
--- @param operations table Dense array of migration operations.
--- @return table plan Outcome, candidate bytes and detached model, or refusal detail.
function M.plan_operations(source, operations)
	if not is_array(operations) then return { outcome = "failed", detail = "operations must be an array" } end
	for _, op in ipairs(operations) do
		local valid, detail = validate_op(op)
		if not valid then return { outcome = "failed", detail = detail } end
		if op.op == "move_chord_action" then
			return { outcome = "failed", detail = "independent record operations cannot depend on action context" }
		end
	end
	local before, scan = M.model_from_source(source)
	if not before then return { outcome = "failed", detail = scan } end
	local witnessed, refusal = pcall(variant_source_witness, source, scan, before, operations)
	if not witnessed then
		if tostring(refusal):sub(1, #VARIANT_REFUSAL) == VARIANT_REFUSAL then
			return { outcome = "invalid", detail = tostring(refusal) }
		end
		error(refusal, 0)
	end
	local after = clone_model(before)
	for _, op in ipairs(operations) do
		if op.op == "move_ergopti_variant" then
			local accepted, refusal = pcall(APPLY[op.op], after.sections, op, nil, after)
			if not accepted then
				if tostring(refusal):sub(1, #VARIANT_REFUSAL) == VARIANT_REFUSAL then
					return { outcome = "invalid", detail = tostring(refusal) }
				end
				error(refusal, 0)
			end
		else
			APPLY[op.op](after.sections, op, nil, after)
		end
	end
	if same_value(M.plain(before), M.plain(after)) then
		return { outcome = "current", candidate = source, model = after }
	end
	local candidate, detail = render(source, scan, before, after)
	if not candidate then return { outcome = "failed", detail = detail } end
	local reread = M.model_from_source(candidate)
	if not reread or not same_value(M.plain(reread), M.plain(after)) then
		return { outcome = "failed", detail = "independent record operations do not read back as their candidate model" }
	end
	return { outcome = "migrated", candidate = candidate, model = after }
end

--- Load migration identities explicitly before config-dependent native modules.
--- Missing data is reported to boot's existing read-only refusal owner.
function M.load_context(path, action_catalogue, file_adapter)
	local acquired, context, detail = pcall(function()
		if type(path) ~= "string" or path == "" then return nil, "no modifier catalogue path" end
		local ok, content, status = pcall(writer().read_classified, path, file_adapter)
		if not ok or status ~= "ok" or type(content) ~= "string" then
			return nil, "the modifier catalogue could not be read"
		end
		local decoded, detail = require("json").decode_lossless(content)
		local platform = type(decoded) == "table" and type(decoded.platforms) == "table" and decoded.platforms.macos
		if detail ~= nil or type(decoded) ~= "table" or type(decoded.keys) ~= "table"
			or type(platform) ~= "table" or type(platform.modifiers) ~= "table"
			or type(platform.shortcut_groups) ~= "table" then
			return nil, "the modifier catalogue is invalid"
		end
		local built, actions = pcall(require("actions.assignable").build, action_catalogue, decoded, "macos")
		if not built then return nil, "the action catalogue is invalid: " .. tostring(actions) end
		return { modifier_chords = decoded, assignable_actions = actions }
	end)
	if not acquired then return nil, "migration context acquisition raised: " .. tostring(context) end
	return context, detail
end





-- =======================
-- =======================
-- ======= 6/ Boot =======
-- =======================
-- =======================

--- ``config.toml`` + 3 + "20260924-101500" -> ``config.pre-v3-20260924-101500.toml``
--- in the same directory: the bytes as they were before version 3.
--- @param path string
--- @param version number The version the migration reaches.
--- @param stamp string
--- @return string
function M.backup_path(path, version, stamp)
	local dir, name = path:match("^(.*[/\\])([^/\\]+)$")
	if not dir then dir, name = "", path end
	local stem, ext = name:match("^(.+)(%.[^%.]+)$")
	if not stem then stem, ext = name, "" end
	return dir .. stem .. ".pre-v" .. version_text(version) .. "-" .. stamp .. ext
end

--- The reason writes to path are refused this session, or nil.
--- @param path string
--- @return string|nil
function M.read_only_reason(path)
	return writer().write_refusal(path)
end

--- Migrates a config file at boot. Every outcome other than "absent",
--- "current" and "migrated" leaves the file untouched and refuses every later
--- write to it for the session.
---
--- Seams: `read(path) -> content, status, detail`, `create_backup(path,
--- content) -> true | false, detail` (must refuse an existing path) and
--- `publish(path, content, expected_source) -> true | false, detail`; by
--- default all three go through toml_codec.writer with `file_adapter`.
--- @param opts table `{ path, driver, registry? | registry_path, stamp?,
---   file_adapter?, read?, create_backup?, publish?, logger? }`.
--- @return table result `{ status, from?, to?, backup?, read_only, detail? }`.
function M.run(opts)
	if type(opts) ~= "table" or getmetatable(opts) ~= nil
		or type(rawget(opts, "path")) ~= "string" or rawget(opts, "path") == "" then
		error("config_migrate.run needs a plain options table and a path", 2)
	end
	-- Copy callback identities before the first external function. An observer
	-- cannot turn a custom seam into native authority by editing opts later.
	local supplied = opts
	opts = {}
	for _, name in ipairs({ "path", "driver", "registry", "registry_path", "stamp", "file_adapter", "read",
		"create_backup", "publish", "logger", "context", "context_error" }) do opts[name] = rawget(supplied, name) end
	if not M.DRIVERS[opts.driver] then error("config_migrate.run needs a known driver", 2) end
	local path = opts.path
	local key, ambiguous = destination_key(path)
	if ambiguous then error("config migration needs a canonical path spelling", 2) end
	local record = { key = key, phase = "preparing" }
	destinations[key] = record
	record.writer = writer()
	record.adapter = opts.file_adapter
	local native_ports = native_configuration_ports(opts.driver)
	if native_ports ~= nil then
		record.port_owner, record.port_issuer = native_ports.owner, native_ports.issuer
		record.port_reader, record.port_writer, record.port_publisher =
			native_ports.reader, native_ports.writer, native_ports.publisher
		record.port_conditional_remover, record.port_remover, record.port_exact_remover, record.port_delete =
			native_ports.remover, native_ports.admitted_remover, native_ports.exact_remover, native_ports.delete
	end
	record.native_adapter = record.port_owner ~= nil and rawequal(record.adapter, record.port_owner)
	record.shared_native = record.adapter == nil or record.native_adapter and opts.driver == "linux"
	if type(record.adapter) == "table" then
		record.adapter_reader = rawget(record.adapter, "read_with_status")
		record.adapter_publisher = rawget(record.adapter, "write_if_unchanged_admitted")
	end
	local registry = opts.registry and detached(validated_registries[opts.registry]) or nil
	local supplied_registry = opts.registry ~= nil
	local log = opts.logger or Logger
	local result = { status = "failed", read_only = false }
	log.start(LOG, "Checking the config schema version of '%s' (%s driver)…", path, opts.driver)

	local function refuse(status, detail)
		detail = tostring(detail or status)
		result.status = status
		result.detail = detail
		result.read_only = true
		writer().refuse_writes(path, detail)
		log.error(LOG, "Config migration of '%s' refused (%s): %s. The file is left untouched and "
			.. "this session will not write it.", path, status, tostring(detail))
		return result
	end

	if not destination_live(record) then return refuse("failed", "config admission owner changed before registry read") end
	if opts.read == nil and opts.publish == nil and opts.create_backup == nil
		and (record.port_owner == nil or record.adapter ~= nil and not record.native_adapter) then
		return refuse("failed", "native configuration initializer is unavailable")
	end

	local registry_err
	if supplied_registry and registry == nil then return refuse("failed", "registry was not issued by validation") end
	if not supplied_registry then
		local loaded
		loaded, registry_err = M.load_registry(opts.registry_path, opts.file_adapter)
		registry = loaded and detached(validated_registries[loaded])
	end
	if not registry then return refuse("failed", registry_err) end
	if opts.context_error ~= nil then return refuse("failed", opts.context_error) end
	result.to = registry.current
	record.current = registry.current
	if not destination_live(record) then return refuse("failed", "config admission owner changed during boot") end

	local adapter = opts.file_adapter
	local native_adapter = adapter == nil or record.native_adapter
	local native_io_adapter = adapter
	if record.native_adapter and opts.driver == "linux" then
		-- The Linux adapter is exactly the shared writer delegate. Use its same
		-- captured native owner once, rather than recursively consuming a permit.
		local reader_source = type(record.adapter_reader) == "function" and debug.getinfo(record.adapter_reader, "S").source
		local expected = source_sibling(reader_source, "linux/adapters/file_system.lua",
			"_shared/lua/config_migrate.lua", source_directory)
		if source_same(debug.getinfo(1, "S").source, expected, source_directory) then native_io_adapter = nil
		else native_adapter = false end
	end
	local native_default = opts.read == nil and opts.publish == nil and opts.create_backup == nil
		and native_adapter and record.port_owner ~= nil
	local default_read
	-- The file is writable this session: whatever creates it again stamps it.
	local function writable(status)
		if not destination_live(record) then return refuse("failed", "config admission owner changed during boot") end
		if writer().write_refusal(path) ~= nil then return refuse("failed", "this destination remains refused for the session") end
		result.status = status
		-- Custom IO seams retain their model/testing contract but do not prove a
		-- native destination was admitted by this constructor.
		if native_default then
			local content, current_status = default_read(path)
			if not current_schema({ status = current_status, content = content }, registry.current) then
				return refuse("failed", "fresh native source is not current before runtime admission")
			end
			record.phase = "ready"
		end
		writer().set_create_rows(path, {
			{ section = M.META_SECTION, key = M.VERSION_KEY, value = registry.current },
		})
		return result
	end

	local native_read = native_reader
	default_read = function(target)
		if not rawequal(rawget(writer(), "read_classified"), native_read) then return nil, "error", "migration reader changed" end
		record.reading = true
		local called, content, status, detail = pcall(native_read, target, native_io_adapter)
		record.reading = nil
		if not called then return nil, "error", tostring(content) end
		if not destination_live(record) then return nil, "error", "config admission owner changed during read" end
		return content, status, detail
	end
	local read = opts.read or default_read
	local read_ok, source, status, detail = pcall(read, path)
	if not read_ok then return refuse("failed", "reading the file raised: " .. tostring(source)) end
	if status == "absent" then
		log.success(LOG, "No config file at '%s' yet; nothing to migrate.", path)
		return writable("absent")
	end
	if status ~= "ok" or type(source) ~= "string" then
		return refuse("failed", "the file could not be read (" .. tostring(detail or status) .. ")")
	end

	local canonical_ok, canonical, canonical_shapes = pcall(canonical_decode, source)
	if not canonical_ok or type(canonical) ~= "table" then return refuse("failed", "source is not valid canonical TOML") end
	local meta = canonical._meta
	if meta ~= nil and (type(meta) ~= "table" or canonical_shapes.arrays[meta] == true) then
		return refuse("invalid", "canonical _meta must be a non-array table")
	end
	local version
	if type(meta) == "table" then version = meta.schema_version end
	local function refuse_version(status, detail)
		-- Only the genuine default reader and canonical document/meta checks
		-- above establish this initial image. Custom seams grant no reader port.
		if native_default and destination_live(record) then record.version_refused_source = source end
		return refuse(status, detail)
	end
	if version ~= nil and not is_version(version) then return refuse_version("invalid", "canonical schema version is invalid") end
	if version ~= nil and version > registry.current then return refuse_version("newer", "canonical schema version is newer than this build") end
	local plan = M.plan(source, registry, opts.driver, opts.context)
	if version ~= nil and version ~= registry.current and plan.version ~= version then
		return refuse("unsupported", "legacy metadata is not addressable by this migration owner")
	end
	-- The strict canonical document, not the flat migration operation model,
	-- owns current-schema admission for inline/dotted/quoted metadata.
	if current_schema({ status = "ok", content = source }, registry.current) then
		plan = { outcome = "current", version = registry.current, candidate = source }
	elseif plan.outcome == "current" then
		return refuse("invalid", "canonical schema metadata is not current")
	end
	result.from = plan.version
	if plan.outcome == "current" then
		log.success(LOG, "'%s' is at schema v%s; nothing to migrate.", path, version_text(registry.current))
		return writable("current")
	end
	if plan.outcome == "newer" then
		return refuse("newer", "the file declares schema v" .. version_text(plan.version)
			.. ", newer than this build's v" .. version_text(registry.current))
	end
	if plan.outcome == "invalid" then
		if type(plan.detail) == "string" and plan.detail:find("Ergopti variant migration refused:", 1, true) == 1 then
			return refuse("invalid", plan.detail)
		end
		return refuse("invalid", "[_meta] schema_version is not a positive integer")
	end
	if plan.outcome == "unsupported" then
		return refuse("unsupported", "no migration path from schema v" .. version_text(plan.version))
	end
	if plan.outcome ~= "migrated" then return refuse("failed", plan.detail) end

	-- Reacquire the physical source before any backup effect. A callback can
	-- replace the file after its earlier observation without changing the plan.
	if opts.create_backup == nil then
		local fresh, fresh_status = default_read(path)
		if fresh_status ~= "ok" or fresh ~= source then return refuse("failed", "source changed before migration backup") end
	end
	local backup = M.backup_path(path, registry.current, opts.stamp or os.date(M.STAMP_FORMAT))
	result.backup = backup
	local create_backup = opts.create_backup or function(target, content)
		return writer().publish_if_unchanged(target, content, opts.file_adapter, { status = "absent" })
	end
	local create_ok, created, create_detail = pcall(create_backup, backup, source)
	if not create_ok or created ~= true then
		return refuse("failed", "the backup '" .. backup .. "' could not be created: "
			.. tostring(create_ok and create_detail or created))
	end
	local copy_ok, copy, copy_status = pcall(read, backup)
	if not copy_ok or copy_status ~= "ok" or copy ~= source then
		return refuse("failed", "the backup '" .. backup .. "' does not hold the exact bytes")
	end

	local publish = opts.publish or function(target, content, expected_source)
		local publisher = native_publisher
		record.publication = { status = expected_source.status, source = expected_source.content, candidate = content }
		local called, published, detail = pcall(publisher, target, content, native_io_adapter, expected_source)
		record.publication = nil
		if not called then return false, tostring(published) end
		return published, detail
	end
	local publish_ok, published, publish_detail = pcall(publish, path, plan.candidate,
		{ status = "ok", content = source })
	if not publish_ok or published ~= true then
		return refuse("failed", "publication failed: " .. tostring(publish_ok and publish_detail or published))
	end

	if native_default then
		local actual, actual_status = default_read(path)
		if actual_status ~= "ok" or actual ~= plan.candidate then
			return refuse("failed", "native migration did not publish its exact candidate")
		end
	end
	result.content = plan.candidate
	result.previous = source
	log.success(LOG, "Migrated '%s' from schema v%s to v%s; backup at '%s'.", path,
		version_text(plan.version), version_text(registry.current), backup)
	return writable("migrated")
end

--- The boot entry point: M.run, with a raise turned into the same refusal so
--- a defect in the engine can never leave the session writing a file it did
--- not version.
--- @param opts table Options of M.run.
--- @return table result Result of M.run.
function M.boot(opts)
	if type(opts) ~= "table" or type(opts.path) ~= "string" or opts.path == "" then
		error("config_migrate.boot needs a path", 2)
	end
	local ok, result = xpcall(M.run, debug.traceback, opts)
	if ok then return result end
	local detail = "the config migration raised: " .. tostring(result)
	writer().refuse_writes(opts.path, detail)
	local log = opts.logger or Logger
	log.error(LOG, "Config migration of '%s' refused (failed): %s. The file is left untouched and "
		.. "this session will not write it.", opts.path, detail)
	return { status = "failed", read_only = true, detail = detail }
end

return M
