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
---    interpreter and to the JS reference.
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

-- Resolved softly, like toml_codec.writer: macOS has its ring-buffer logger,
-- the Linux daemon and the LuaJIT runners use the shim.
local _ok_log, Logger = pcall(require, "infra.logger")
if not _ok_log or type(Logger) ~= "table" then
	Logger = require("logger.shim")
end
local TomlCodec  = require("toml_codec")
local TomlWriter = require("toml_codec.writer")
local Records    = require("config_unused_keys")
local LOG        = "config_migrate"

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

--- Fields of each op of the closed set.
local OPS = {
	rename        = { required = { "section", "key" }, optional = { "to_section", "to_key" } },
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
	for _, field in ipairs({ "key", "to_key" }) do
		if op[field] ~= nil and not is_bare_key(op[field]) then
			return false, "'" .. field .. "' must be one bare segment"
		end
	end
	if op.op == "rename" and op.to_section == nil and op.to_key == nil then
		return false, "rename needs to_section or to_key"
	end
	if op.op == "map_value" then
		if type(op.map) ~= "table" or #op.map == 0 then return false, "map_value needs a non-empty map" end
		for _, pair in ipairs(op.map) do
			if type(pair) ~= "table" or not is_scalar(pair.from) or not is_scalar(pair.to) then
				return false, "each map entry is { from, to } with scalar values"
			end
		end
	end
	if op.op == "set_if_absent" and not is_scalar(op.value) then
		if type(op.value) ~= "table" then return false, "set_if_absent writes a scalar or an array" end
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
	local current = decoded.registry.current_version
	local unstamped = decoded.registry.unstamped_version
	if not is_version(current) or not is_version(unstamped) or unstamped > current then
		return nil, "current_version and unstamped_version must be integers with 1 <= unstamped <= current"
	end
	local steps = {}
	for name, step in pairs(type(decoded.steps) == "table" and decoded.steps or {}) do
		if type(step) ~= "table" or not is_version(step.from) or step.to ~= step.from + 1 then
			return nil, "step '" .. tostring(name) .. "' must go from N to N + 1"
		end
		if name ~= "v" .. version_text(step.from) .. "_to_v" .. version_text(step.to) then
			return nil, "step '" .. tostring(name) .. "' is misnamed"
		end
		if type(step.drivers) ~= "table" or #step.drivers == 0 then
			return nil, "step '" .. name .. "' names no driver"
		end
		local drivers = {}
		for _, driver in ipairs(step.drivers) do
			if not M.DRIVERS[driver] then return nil, "step '" .. name .. "' names unknown driver '" .. tostring(driver) .. "'" end
			drivers[driver] = true
		end
		if type(step.reason) ~= "string" or step.reason == "" then
			return nil, "step '" .. name .. "' has no reason"
		end
		if type(step.ops) ~= "table" then return nil, "step '" .. name .. "' has no ops array" end
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
	return { current = as_integer(current), unstamped = as_integer(unstamped), steps = steps }
end

--- Reads and validates a registry file.
--- @param path string Absolute path of migrations.toml.
--- @param file_adapter table|nil Platform file adapter.
--- @return table|nil registry
--- @return string|nil detail
function M.load_registry(path, file_adapter)
	if type(path) ~= "string" or path == "" then return nil, "no registry path" end
	local content, status, detail = TomlWriter.read_classified(path, file_adapter)
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
	local scan, scan_err = Records.scan_records(source)
	if not scan then return nil, scan_err end
	local sections = {}
	for _, header in ipairs(scan.headers) do
		if header.section and not header.array and sections[header.section] == nil then
			sections[header.section] = {}
		end
	end
	for _, record in ipairs(scan.records) do
		if record.addressable then
			sections[record.section][record.key] = { value = value_at(decoded, record.path), record = record }
		end
	end
	return { sections = sections }, scan
end

--- A copy of the model sharing its entry objects.
local function clone_model(model)
	local sections = {}
	for name, entries in pairs(model.sections) do
		local copy = {}
		for key, entry in pairs(entries) do copy[key] = entry end
		sections[name] = copy
	end
	return { sections = sections }
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
function M.apply_steps(model, registry, driver, from_version)
	if not M.DRIVERS[driver] then error("config_migrate: unknown driver '" .. tostring(driver) .. "'", 2) end
	for _, step in ipairs(registry.steps) do
		if step.from >= from_version and step.drivers[driver] then
			for _, op in ipairs(step.ops) do APPLY[op.op](model.sections, op) end
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
function M.plan(source, registry, driver)
	local before, scan = M.model_from_source(source)
	if not before then return { outcome = "failed", detail = scan } end
	local outcome, version = M.classify(before, registry)
	if outcome ~= "migrate" then return { outcome = outcome, version = version } end
	local after = M.apply_steps(clone_model(before), registry, driver, version)
	local candidate, render_err = render(source, scan, before, after)
	if not candidate then return { outcome = "failed", version = version, detail = render_err } end
	local reread = M.model_from_source(candidate)
	if not reread or not same_value(M.plain(reread), M.plain(after)) then
		return { outcome = "failed", version = version,
			detail = "the rewritten file would not read back as the migrated configuration" }
	end
	return { outcome = "migrated", version = version, candidate = candidate, model = after }
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
	return TomlWriter.write_refusal(path)
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
	if type(opts) ~= "table" or type(opts.path) ~= "string" or opts.path == "" then
		error("config_migrate.run needs a path", 2)
	end
	if not M.DRIVERS[opts.driver] then error("config_migrate.run needs a known driver", 2) end
	local log = opts.logger or Logger
	local path = opts.path
	local result = { status = "failed", read_only = false }
	log.start(LOG, "Checking the config schema version of '%s' (%s driver)…", path, opts.driver)

	local function refuse(status, detail)
		detail = tostring(detail or status)
		result.status = status
		result.detail = detail
		result.read_only = true
		TomlWriter.refuse_writes(path, detail)
		log.error(LOG, "Config migration of '%s' refused (%s): %s. The file is left untouched and "
			.. "this session will not write it.", path, status, tostring(detail))
		return result
	end

	local registry, registry_err = opts.registry, nil
	if registry == nil then registry, registry_err = M.load_registry(opts.registry_path, opts.file_adapter) end
	if not registry then return refuse("failed", registry_err) end
	result.to = registry.current

	-- The file is writable this session: whatever creates it again stamps it.
	local function writable(status)
		result.status = status
		TomlWriter.set_create_rows(path, {
			{ section = M.META_SECTION, key = M.VERSION_KEY, value = registry.current },
		})
		return result
	end

	local read = opts.read or function(target) return TomlWriter.read_classified(target, opts.file_adapter) end
	local read_ok, source, status, detail = pcall(read, path)
	if not read_ok then return refuse("failed", "reading the file raised: " .. tostring(source)) end
	if status == "absent" then
		log.success(LOG, "No config file at '%s' yet; nothing to migrate.", path)
		return writable("absent")
	end
	if status ~= "ok" or type(source) ~= "string" then
		return refuse("failed", "the file could not be read (" .. tostring(detail or status) .. ")")
	end

	local plan = M.plan(source, registry, opts.driver)
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
		return refuse("invalid", "[_meta] schema_version is not a positive integer")
	end
	if plan.outcome == "unsupported" then
		return refuse("unsupported", "no migration path from schema v" .. version_text(plan.version))
	end
	if plan.outcome ~= "migrated" then return refuse("failed", plan.detail) end

	local backup = M.backup_path(path, registry.current, opts.stamp or os.date(M.STAMP_FORMAT))
	result.backup = backup
	local create_backup = opts.create_backup or function(target, content)
		return TomlWriter.publish_if_unchanged(target, content, opts.file_adapter, { status = "absent" })
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
		return TomlWriter.publish_if_unchanged(target, content, opts.file_adapter, expected_source)
	end
	local publish_ok, published, publish_detail = pcall(publish, path, plan.candidate,
		{ status = "ok", content = source })
	if not publish_ok or published ~= true then
		return refuse("failed", "publication failed: " .. tostring(publish_ok and publish_detail or published))
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
	TomlWriter.refuse_writes(opts.path, detail)
	local log = opts.logger or Logger
	log.error(LOG, "Config migration of '%s' refused (failed): %s. The file is left untouched and "
		.. "this session will not write it.", opts.path, detail)
	return { status = "failed", read_only = true, detail = detail }
end

return M
