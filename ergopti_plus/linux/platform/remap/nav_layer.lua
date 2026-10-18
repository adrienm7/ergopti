--- platform/remap/nav_layer.lua

--- ==============================================================================
--- MODULE: Native Navigation Layer
--- DESCRIPTION:
--- Compiles the shared layer vocabulary into daemon-owned evdev chords. Only
--- explicitly configured bindings run; an absent file leaves every key native.
--- An outdated entry never stops the daemon: it is warned once and ignored,
--- and the rest of the file still binds (the maintainer's outdated-entry rule).
--- ==============================================================================

local M = {}
local Layers = require("keymap.layers")
local Json = require("json")
local Toml = require("toml_codec")
local Writer = require("toml_codec.writer")
local Outdated = require("config_outdated")
local Logger = require("logger.shim")

local LOG = "platform.remap.nav_layer"

local Brightness = require("brightness_actions").load()

local MODIFIER_KEYS = { ctrl = "ControlLeft", alt = "AltLeft", shift = "ShiftLeft", meta = "MetaLeft" }

-- Shared loader codes that reject the layer file as a whole.
local WHOLE_FILE_ERRORS = {
	file_unreadable = true, toml_invalid = true,
	schema_version_missing = true, schema_version_unsupported = true,
}

-- Original-load observations are keyed only by private issuances from load.
-- They describe configured inputs, never native installation or output rights.
local source_records = setmetatable({}, { __mode = "k" })
local original_load, original_compile, original_capture
local original_read, original_json, original_toml = Writer.read_classified, Json.decode, Toml.decode
local layer_ports = {}
local LAYER_PORT_NAMES = { "load_context", "load_user_file", "user_file_path", "new_context", "load", "error_signature" }
for _, name in ipairs(LAYER_PORT_NAMES) do
	layer_ports[name] = Layers[name]
end

local function copy_fields(value, shape, active)
	shape, active = shape or "map", active or {}
	-- Fixed compiler grammar: map -> row -> chord list -> chord -> numbers.
	-- No arbitrary object recursion, __pairs, functions, holes or cyclic data.
	if type(value) ~= "table" or getmetatable(value) ~= nil or active[value] then return nil, false end
	active[value] = true
	local copy, count = {}, 0
	local row_chords = shape == "row" and rawget(value, "chords") ~= nil
	for key, item in pairs(value) do
		local child
		if shape == "map" or shape == "chords" or shape == "numbers" then
			if type(key) ~= "number" or key ~= key or math.abs(key) == math.huge
				or key % 1 ~= 0 or key < (shape == "map" and 0 or 1) then active[value] = nil; return nil, false end
			child = shape == "map" and "row" or "chord"
		elseif shape == "row" and row_chords and key == "chords" then child = "chords"
		elseif (shape == "row" and not row_chords or shape == "chord") and (key == "mods" or key == "keys") then
			child = "numbers"
		else active[value] = nil; return nil, false end
		if shape == "numbers" then
			if type(item) ~= "number" or item ~= item or math.abs(item) == math.huge
				or item % 1 ~= 0 or item < 0 then active[value] = nil; return nil, false end
			copy[key] = item
		else
			local copied, valid = copy_fields(item, child, active)
			if not valid then active[value] = nil; return nil, false end
			copy[key] = copied
		end
		count = count + 1
	end
	active[value] = nil
	if shape == "numbers" or shape == "chords" then
		for index = 1, count do if rawget(copy, index) == nil then return nil, false end end
		if shape == "chords" and count == 0 then return nil, false end
	elseif shape == "row" and row_chords then
		if count ~= 1 then return nil, false end
	elseif shape == "row" or shape == "chord" then
		if count ~= 2 or rawget(copy, "mods") == nil or rawget(copy, "keys") == nil then return nil, false end
	end
	return copy, true
end

local function same_fields(value, expected)
	if type(expected) ~= "table" then return type(value) == type(expected) and value == expected end
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	for key, item in pairs(expected) do if not same_fields(rawget(value, key), item) then return false end end
	for key in pairs(value) do if rawget(expected, key) == nil then return false end end
	return true
end

local function source_ports_current()
	if not rawequal(package.loaded["platform.remap.nav_layer"], M) or getmetatable(M) ~= nil
		or rawget(M, "load") ~= original_load or rawget(M, "compile") ~= original_compile
		or rawget(M, "capture_source_observation") ~= original_capture
		or not rawequal(package.loaded["toml_codec.writer"], Writer) or getmetatable(Writer) ~= nil
		or rawget(Writer, "read_classified") ~= original_read
		or not rawequal(package.loaded["json"], Json) or getmetatable(Json) ~= nil or rawget(Json, "decode") ~= original_json
		or not rawequal(package.loaded["toml_codec"], Toml) or getmetatable(Toml) ~= nil or rawget(Toml, "decode") ~= original_toml
		or not rawequal(package.loaded["keymap.layers"], Layers) or getmetatable(Layers) ~= nil then return false end
	for _, name in ipairs(LAYER_PORT_NAMES) do
		local port = layer_ports[name]
		if type(port) ~= "function" or rawget(Layers, name) ~= port then return false end
	end
	return true
end

--- Returns original-load bytes only after the shared reader acknowledges close.
--- A genuine ENOENT remains absence; a failed read/close is never an empty layer.
local function read_file(path, remember, reader)
	local content, status, detail = reader(path)
	if remember then remember(path, content, status) end
	if status == "ok" and type(content) == "string" then return content end
	if status == "absent" and content == nil then return nil end
	error(tostring(detail or "navigation source read did not commit"), 0)
end

--- Shipped registry/vocabulary failure is fatal, including proven absence.
local function read_shipped(path, remember, reader)
	local content = read_file(path, remember, reader)
	if content == nil then error("navigation shipped file missing: " .. path, 0) end
	return content
end

--- Resolves a keyboard key through the canonical physical registry.
local function key_code(registry, name)
	local entry = registry.keys[name]
	if type(entry) ~= "table" or entry.kind ~= "key" or type(entry.evdev) ~= "number" then
		error("the native navigation engine cannot intercept or emit " .. tostring(name), 2)
	end
	return entry.evdev
end

--- Compiles resolved bindings without doing I/O or acquiring input devices.
--- @param bindings table Physical-key ids mapped to shared resolutions.
--- @param registry table Canonical physical-key registry.
--- @return table layer Evdev input codes mapped to native chord sequences.
function M.compile(bindings, registry)
	local layer = {}
	for source, resolved in pairs(bindings) do
		local code = key_code(registry, source)
		if resolved.kind == "none" then
			layer[code] = { mods = {}, keys = {} }
		elseif resolved.kind == "call" and Brightness.actions[resolved.handler] then
			layer[code] = { mods = {}, keys = { Brightness.actions[resolved.handler].linux_code } }
		elseif resolved.kind == "keystroke" then
			local chords = {}
			for _, chord in ipairs(resolved.chords) do
				local mods = {}
				for _, name in ipairs(chord.mods) do
					mods[#mods + 1] = key_code(registry, assert(MODIFIER_KEYS[name], "unsupported navigation modifier"))
				end
				chords[#chords + 1] = { mods = mods, keys = { key_code(registry, chord.key) } }
			end
			assert(#chords > 0, "a navigation keystroke needs at least one chord")
			layer[code] = { chords = chords }
		else
			error("unsupported native navigation resolution: " .. tostring(resolved.kind), 2)
		end
	end
	return layer
end

original_compile = M.compile

--- Whether the shared loader rejected the file as a whole: unreadable, not
--- TOML, without or with another layers schema version, or a `layers` value
--- that is not a table. Such a file binds nothing, and that stays this load's
--- failure; every other error names one entry.
--- @param item table A shared loader error record.
--- @return boolean
local function rejects_whole_file(item)
	return WHOLE_FILE_ERRORS[item.code] == true or (item.code == "invalid_value_type" and item.layer == nil)
end

--- The TOML path of the entry one loader error names.
--- @param item table A shared loader error record.
--- @return table segments
local function entry_path(item)
	local segments = {}
	if item.layer ~= nil then segments = { "layers", item.layer } end
	for _, field in ipairs({ "section", "key" }) do
		if item[field] ~= nil then segments[#segments + 1] = item[field] end
	end
	return segments
end

--- Reads the user's layer. A file the shared loader rejects as a whole raises,
--- so a reload keeps the layer in force; an entry this build no longer runs (a
--- retired action, key, field or layer) is warned once and ignored, and every
--- other binding of the file still loads.
--- @param opts table { shared_root, config_dir, boot? }. A boot load isolates
---   classified user-file failures; every later load remains strict.
--- @return table layer Native chords for the navigation layer.
function M.load(opts)
	local sources, eligible = {}, source_ports_current()
	-- A legacy caller may deliberately replace a port (including a throwing
	-- compiler). Preserve that load behavior, but never issue source provenance.
	local observing = eligible
	local reader = observing and original_read or Writer.read_classified
	local json_decode = observing and original_json or Json.decode
	local toml_decode = observing and original_toml or Toml.decode
	local load_context = observing and layer_ports.load_context or Layers.load_context
	local load_user_file = observing and layer_ports.load_user_file or Layers.load_user_file
	local compile = observing and original_compile or M.compile
	local function rejoin()
		if not source_ports_current() then eligible = false end
	end
	local function invoke(port, ...)
		rejoin()
		local result = port(...)
		rejoin()
		return result
	end
	local function remember(path, bytes, status)
		rejoin()
		sources[#sources + 1] = { path = path, bytes = bytes, status = status }
	end
	local decode_json = function(bytes) return invoke(json_decode, bytes) end
	local decode_toml = function(bytes) return invoke(toml_decode, bytes) end
	local shared_root = opts.shared_root
	local ctx = invoke(load_context, {
		shared_root = shared_root, json_decode = decode_json,
		toml_decode = decode_toml, read_file = function(path) rejoin(); return read_shipped(path, remember, reader) end,
	})
	local config_dir = opts.config_dir
	local result = invoke(load_user_file, {
		config_dir = config_dir, os = "linux", ctx = ctx,
		toml_decode = decode_toml, read_file = function(path) rejoin(); return read_file(path, remember, reader) end,
	})
	for _, item in ipairs(result.errors) do
		if rejects_whole_file(item) then
			-- Only the initial engine may isolate a refused user file. A reload
			-- must leave its previously acknowledged engine in force instead.
			if opts.boot == true then
				Logger.error(LOG, "'%s' could not be used as a whole: the navigation layer binds no key (%s).",
					result.path, Layers.error_signature(item))
				return {}
			end
			error("invalid navigation layer: " .. Layers.error_signature(item) .. " (" .. tostring(item.detail) .. ")", 2)
		end
	end
	for _, item in ipairs(result.errors) do
		Outdated.report_in_file(result.path, entry_path(item), tostring(item.detail))
	end
	for name in pairs(result.layers) do
		if name ~= "nav" then
			Outdated.report_in_file(result.path, { "layers", name }, "the Linux engine only activates the 'nav' layer")
		end
	end
	local map = invoke(compile, result.layers.nav or {}, ctx.registry)
	local observation
	local complete = type(shared_root) == "string" and type(config_dir) == "string"
		and #sources == 3 and sources[3].path == result.path
	for _, source in ipairs(sources) do
		if type(source.path) ~= "string" or not (source.status == "ok" and type(source.bytes) == "string"
			or source.status == "absent" and source.bytes == nil) then complete = false end
	end
	local fields, plain = copy_fields(map)
	if complete and eligible and source_ports_current() and plain then
		observation = {}
		-- The weak value contains the real map, never its observation key.
		source_records[observation] = { map = map, fields = fields, sources = sources,
			shared_root = shared_root, config_dir = config_dir }
	end
	return map, observation
end

--- Captures only the original configured map and its original-load source facts.
--- Later reads compare that baseline; they never create one or install an engine.
--- @param map table Exact first return from this module's load.
--- @param observation table Exact opaque second return from the same load.
--- @param shared_root string Original shared root passed to load.
--- @param config_dir string Original configuration folder passed to load.
--- @return table|nil observation { current, sealed }; no input/output authority.
function M.capture_source_observation(map, observation, shared_root, config_dir)
	local record = source_records[observation]
	if not record or not rawequal(record.map, map) or record.shared_root ~= shared_root
		or record.config_dir ~= config_dir then return nil end
	local function sealed()
		return source_ports_current() and getmetatable(observation) == nil and next(observation) == nil
			and rawequal(source_records[observation], record) and same_fields(map, record.fields)
	end
	local function current()
		if not sealed() then return false end
		for _, source in ipairs(record.sources) do
			local bytes, status = original_read(source.path)
			if bytes ~= source.bytes or status ~= source.status or not sealed() then return false end
		end
		return sealed()
	end
	if not sealed() then return nil end
	return { current = current, sealed = sealed }
end
original_load, original_capture = M.load, M.capture_source_observation

return M
