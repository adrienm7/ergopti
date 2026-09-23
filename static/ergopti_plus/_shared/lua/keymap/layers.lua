--- _shared/lua/keymap/layers.lua

--- ==============================================================================
--- MODULE: Keymap Layers — Lua Loader (Shared)
--- DESCRIPTION:
--- Reads a layer file — Ergopti's _shared/keymap/layers.recommended.toml or the
--- user's layers.toml in the configuration folder — validates it against the
--- physical-key registry (_shared/data/keycodes/physical_keys.json) and the
--- layer vocabulary (_shared/keymap/layer_actions.toml), and resolves every
--- binding for one OS. The macOS and Linux drivers share this module; the
--- Windows driver implements the same contract in
--- windows/platform/remap/layers_loader.ahk and the JS gates in
--- tools/lib/keymap-layers.cjs. _shared/tests/corpus/keymap_layers/vectors.json
--- holds the three implementations to one answer.
---
--- FEATURES & RATIONALE:
--- 1. Pure: the caller injects the JSON and TOML decoders and the file reader,
---    so the module runs unchanged under Hammerspoon, the LuaJIT daemon and
---    both test harnesses.
--- 2. Errors are data: every problem is { code, layer, section, key, detail,
---    reason_key } with a stable code the corpus asserts. A file-level problem
---    (unreadable file or TOML, missing or unsupported schema_version) rejects
---    the whole file; an entry-level problem drops that entry and is reported.
--- 3. Shipped data fails fast: a registry or a vocabulary without the shape the
---    loader reads raises instead of quietly loading an empty layer.
--- 4. An OS entry replaces the `all` entry for its key even when the OS entry
---    is the invalid one: a rejected override never falls back to `all`.
--- ==============================================================================

local M = {}





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

local ACTION_ID = "^[a-z][a-z0-9_]*$"
local LAYER_ID = "^[a-z][a-z0-9_]*$"
local SECTION_ALL = "all"
local META = "_meta"
local LAYERS = "layers"
local SIGNATURE_SEPARATOR = "|"





-- ==========================
-- ==========================
-- ======= 2/ Helpers =======
-- ==========================
-- ==========================

--- Keys of a table in byte order, so reports do not depend on hash order.
--- @param t table Any table.
--- @return table keys Sorted list of the table's keys.
local function sorted_keys(t)
	local out = {}
	for k in pairs(t) do out[#out + 1] = k end
	table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
	return out
end

--- @param list table A sequence.
--- @param value any The value to find.
--- @return boolean found True when the sequence holds the value.
local function list_has(list, value)
	for _, v in ipairs(list) do
		if v == value then return true end
	end
	return false
end

--- Splits on a plain separator and KEEPS empty fields, so "a,,b" reports an
--- empty chord instead of silently reading as "a,b".
--- @param s string Text to split.
--- @param sep string Plain separator.
--- @return table parts The fields, empty ones included.
local function split_plain(s, sep)
	local out, start = {}, 1
	while true do
		local i = string.find(s, sep, start, true)
		if not i then
			out[#out + 1] = s:sub(start)
			return out
		end
		out[#out + 1] = s:sub(start, i - 1)
		start = i + #sep
	end
end

--- @return table error One error record; absent fields stay nil.
local function new_error(code, layer, section, key, detail, reason_key)
	return { code = code, layer = layer, section = section, key = key, detail = detail, reason_key = reason_key }
end

--- @param value any
--- @return boolean is_table True for a Lua table (a TOML table once decoded).
local function is_table(value)
	return type(value) == "table"
end





-- ==========================
-- ==========================
-- ======= 3/ Context =======
-- ==========================
-- ==========================

--- Builds the loader context from the decoded registry and vocabulary.
--- Raises when either lacks a field the loader reads: this is shipped data, and
--- a loader that tolerated a broken copy would resolve every layer to nothing.
--- @param registry table Decoded physical_keys.json.
--- @param vocabulary table Decoded layer_actions.toml.
--- @return table ctx The context every other function takes.
function M.new_context(registry, vocabulary)
	if not is_table(registry) or not is_table(registry.keys) then
		error("keymap.layers: the physical-key registry has no keys table", 2)
	end
	if not is_table(vocabulary) or not is_table(vocabulary._meta) then
		error("keymap.layers: the layer vocabulary has no [_meta] table", 2)
	end
	local meta = vocabulary._meta
	for _, field in ipairs({ "platforms", "modifier_order" }) do
		if not is_table(meta[field]) or #meta[field] == 0 then
			error("keymap.layers: the layer vocabulary has no [_meta]." .. field, 2)
		end
	end
	if type(meta.layers_schema_version) ~= "number" or type(meta.user_file) ~= "string" then
		error("keymap.layers: the layer vocabulary lacks layers_schema_version or user_file", 2)
	end
	for _, field in ipairs({ "primary_modifier", "call_handlers", "actions" }) do
		if not is_table(vocabulary[field]) then
			error("keymap.layers: the layer vocabulary has no [" .. field .. "] table", 2)
		end
	end
	local repeat_count = is_table(vocabulary.parameters) and vocabulary.parameters.repeat_count
	if not is_table(repeat_count) or type(repeat_count.min) ~= "number" or type(repeat_count.max) ~= "number"
			or not is_table(repeat_count.platforms) then
		error("keymap.layers: the layer vocabulary has no usable [parameters.repeat_count]", 2)
	end
	return { registry = registry, vocabulary = vocabulary, platforms = meta.platforms }
end

--- Reads and decodes the shipped registry and vocabulary under the _shared root.
--- @param opts table { shared_root, json_decode, toml_decode, read_file } where
---   read_file(path) returns the file content or raises.
--- @return table ctx The loader context.
function M.load_context(opts)
	local root = (tostring(opts.shared_root):gsub("[/\\]$", ""))
	local registry_text = opts.read_file(root .. "/data/keycodes/physical_keys.json")
	local vocabulary_text = opts.read_file(root .. "/keymap/layer_actions.toml")
	local registry = opts.json_decode(registry_text)
	local vocabulary = opts.toml_decode(vocabulary_text)
	if not is_table(vocabulary) then
		error("keymap.layers: layer_actions.toml does not decode as TOML", 2)
	end
	return M.new_context(registry, vocabulary)
end

--- @param config_dir string The configuration folder.
--- @param ctx table The loader context.
--- @return string path Where the user's layer file lives.
function M.user_file_path(config_dir, ctx)
	local dir = (tostring(config_dir):gsub("[/\\]$", ""))
	return dir .. "/" .. ctx.vocabulary._meta.user_file
end





-- ==================================
-- ==================================
-- ======= 4/ Binding grammar =======
-- ==================================
-- ==================================

--- Parses `mod+…+Key[,mod+…+Key…]` into chords with raw (unresolved) modifiers.
--- @return table|nil chords The chords, or nil with a problem.
--- @return string|nil problem Why the text is not a chord list.
local function parse_chords(text, ctx)
	local order = ctx.vocabulary._meta.modifier_order
	local chords = {}
	for _, part in ipairs(split_plain(text, ",")) do
		local tokens = split_plain(part, "+")
		local key = table.remove(tokens)
		if key == nil or key == "" then return nil, 'empty chord in "' .. text .. '"' end
		local entry = ctx.registry.keys[key]
		if not is_table(entry) or entry.kind ~= "key" then
			return nil, '"' .. key .. '" is not a keyboard key in the physical-key registry'
		end
		local seen = {}
		for _, mod in ipairs(tokens) do
			if mod ~= "primary" and not list_has(order, mod) then return nil, 'unknown modifier "' .. mod .. '"' end
			if seen[mod] then return nil, 'modifier "' .. mod .. '" named twice' end
			seen[mod] = true
		end
		chords[#chords + 1] = { mods = tokens, key = key }
	end
	return chords
end

--- Parses one binding value. Syntax only; availability on an OS comes later.
--- @return table|nil binding The parsed binding.
--- @return string|nil code The error code when the value is rejected.
--- @return string|nil detail Why.
local function parse_binding(value, ctx)
	if type(value) ~= "string" then return nil, "invalid_value_type", "a binding must be a string" end
	local colon = string.find(value, ":", 1, true)
	if not colon then
		if not value:match(ACTION_ID) or not is_table(ctx.vocabulary.actions[value]) then
			return nil, "unknown_action", '"' .. value .. '" is not a layer action'
		end
		return { type = "action", id = value }
	end
	local head, rest = value:sub(1, colon - 1), value:sub(colon + 1)
	if head == "repeat_count" then
		local p = ctx.vocabulary.parameters.repeat_count
		local n = rest:match("^[0-9]+$") and tonumber(rest)
		if not n or n < p.min or n > p.max then
			return nil, "invalid_parameter", "repeat_count takes an integer from " .. p.min .. " to " .. p.max
		end
		return { type = "repeat_count", count = n }
	end
	if head == "keystroke" then
		local chords, problem = parse_chords(rest, ctx)
		if not chords then return nil, "invalid_keystroke", problem end
		return { type = "keystroke", chords = chords }
	end
	return nil, "unknown_action", '"' .. head .. ':" is not a binding form'
end

--- Resolves raw modifiers for one OS, in modifier_order.
--- @return table|nil chords The resolved chords.
--- @return table|nil unavailable { detail, reason_key } when a modifier does not exist on the OS.
local function resolve_chords(chords, os, ctx)
	local vocabulary = ctx.vocabulary
	local restricted = is_table(vocabulary.modifiers) and vocabulary.modifiers or {}
	local out = {}
	for _, chord in ipairs(chords) do
		local mods = {}
		for _, raw in ipairs(chord.mods) do
			local mod = raw == "primary" and vocabulary.primary_modifier[os] or raw
			local rule = restricted[mod]
			if is_table(rule) and not list_has(rule.platforms, os) then
				return nil, { detail = 'modifier "' .. mod .. '" does not exist on ' .. os, reason_key = rule.reason_key }
			end
			mods[mod] = true
		end
		local ordered = {}
		for _, mod in ipairs(vocabulary._meta.modifier_order) do
			if mods[mod] then ordered[#ordered + 1] = mod end
		end
		out[#out + 1] = { mods = ordered, key = chord.key }
	end
	return out
end

--- Parses a vocabulary resolution (keystroke:/call:/none). Raises on shipped
--- data the vocabulary gate should have rejected.
local function parse_resolution(text, os, ctx)
	if text == "none" then return { kind = "none" } end
	if text:sub(1, 5) == "call:" then
		local handler = text:sub(6)
		if not list_has(ctx.vocabulary.call_handlers[os] or {}, handler) then
			error("keymap.layers: call:" .. handler .. " is not declared for " .. os)
		end
		return { kind = "call", handler = handler }
	end
	if text:sub(1, 10) == "keystroke:" then
		local chords, problem = parse_chords(text:sub(11), ctx)
		if not chords then error('keymap.layers: vocabulary resolution "' .. text .. '": ' .. problem) end
		return { kind = "keystroke", chords = chords }
	end
	error('keymap.layers: vocabulary resolution "' .. text .. '" is not keystroke:, call: or none')
end

--- Resolves one syntactically valid binding on one OS.
--- @return table|nil resolved The resolution.
--- @return table|nil unavailable { detail, reason_key } when it cannot run on the OS.
local function resolve_binding(binding, os, ctx)
	if binding.type == "repeat_count" then
		local p = ctx.vocabulary.parameters.repeat_count
		if not list_has(p.platforms, os) then
			return nil, { detail = "repeat_count does not exist on " .. os, reason_key = p.reason_key }
		end
		return { kind = "repeat_count", count = binding.count }
	end
	if binding.type == "keystroke" then
		local chords, unavailable = resolve_chords(binding.chords, os, ctx)
		if not chords then return nil, unavailable end
		return { kind = "keystroke", chords = chords, repeatable = false }
	end
	local action = ctx.vocabulary.actions[binding.id]
	local text = action[os]
	if text == nil then text = action[SECTION_ALL] end
	if text == nil then
		return nil, { detail = 'action "' .. binding.id .. '" has no resolution on ' .. os, reason_key = action.reason_key }
	end
	local res = parse_resolution(text, os, ctx)
	if res.kind == "keystroke" then
		local chords = resolve_chords(res.chords, os, ctx)
		if not chords then
			error('keymap.layers: vocabulary action "' .. binding.id .. '" uses an unavailable modifier on ' .. os)
		end
		res.chords = chords
	end
	res.repeatable = res.kind ~= "none" and action.repeatable == true
	res.action = binding.id
	return res
end





-- =======================================
-- =======================================
-- ======= 5/ Loading a layer file =======
-- =======================================
-- =======================================

--- Validates the sections of one layer and resolves its effective bindings.
--- @return table bindings key code -> resolution, for the OS.
local function load_layer(layer_id, layer, os, ctx, report)
	local sections = { SECTION_ALL }
	for _, platform in ipairs(ctx.platforms) do sections[#sections + 1] = platform end
	local parsed = {}
	for _, section in ipairs(sorted_keys(layer)) do
		local tbl = layer[section]
		if not list_has(sections, section) then
			report(new_error("unknown_layer_section", layer_id, section, nil,
				'"' .. tostring(section) .. '" is not one of ' .. table.concat(sections, ", ")))
		elseif not is_table(tbl) then
			report(new_error("invalid_value_type", layer_id, section, nil, "a layer section must be a table"))
		else
			parsed[section] = {}
			for _, code in ipairs(sorted_keys(tbl)) do
				if not is_table(ctx.registry.keys[code]) then
					report(new_error("unknown_key", layer_id, section, code,
						'"' .. tostring(code) .. '" is not in the physical-key registry'))
				else
					local binding, err_code, detail = parse_binding(tbl[code], ctx)
					if binding then parsed[section][code] = binding
					else report(new_error(err_code, layer_id, section, code, detail)) end
				end
			end
		end
	end
	-- The OS entry replaces the `all` entry for its key, even when the OS entry
	-- is the invalid one: a rejected override must not quietly fall back.
	local effective = {}
	for _, section in ipairs({ SECTION_ALL, os }) do
		if is_table(layer[section]) then
			for code in pairs(layer[section]) do
				effective[code] = { section = section, binding = parsed[section] and parsed[section][code] }
			end
		end
	end
	local out = {}
	for _, code in ipairs(sorted_keys(effective)) do
		local entry = effective[code]
		if entry.binding then
			local resolved, unavailable = resolve_binding(entry.binding, os, ctx)
			if resolved then out[code] = resolved
			else report(new_error("unavailable_on_os", layer_id, entry.section, code, unavailable.detail, unavailable.reason_key)) end
		end
	end
	return out
end

--- Loads a layer file for one OS.
--- @param text string|nil The file content, or nil when the file is absent.
--- @param os string windows | macos | linux.
--- @param ctx table From new_context() or load_context().
--- @param toml_decode function Returns the decoded table, or nil/raises on invalid TOML.
--- @return table result { ok = boolean, errors = {…}, layers = { layer id -> { key code -> resolution } } }
function M.load(text, os, ctx, toml_decode)
	if not list_has(ctx.platforms, os) then error("keymap.layers: unknown OS " .. tostring(os), 2) end
	local result = { ok = true, errors = {}, layers = {} }
	local function reject(err)
		result.errors[#result.errors + 1] = err
		result.ok = false
		result.layers = {}
		return result
	end
	local function report(err)
		result.errors[#result.errors + 1] = err
		result.ok = false
	end
	if text == nil then return result end
	local decoded_ok, doc = pcall(toml_decode, text)
	if not decoded_ok or not is_table(doc) then
		return reject(new_error("toml_invalid", nil, nil, nil, decoded_ok and "the file is not valid TOML" or tostring(doc)))
	end
	if next(doc) == nil then return result end
	local meta = doc[META]
	if not is_table(meta) or meta.schema_version == nil then
		return reject(new_error("schema_version_missing", nil, nil, nil, "[_meta].schema_version is required"))
	end
	local supported = ctx.vocabulary._meta.layers_schema_version
	if meta.schema_version ~= supported then
		return reject(new_error("schema_version_unsupported", nil, nil, nil,
			"schema_version " .. tostring(meta.schema_version) .. " is not " .. supported))
	end
	for _, key in ipairs(sorted_keys(meta)) do
		if key ~= "schema_version" then report(new_error("unknown_field", nil, META, key, "[_meta]." .. tostring(key) .. " is not a field")) end
	end
	for _, key in ipairs(sorted_keys(doc)) do
		if key ~= META and key ~= LAYERS then report(new_error("unknown_field", nil, nil, key, 'top-level "' .. tostring(key) .. '" is not a field')) end
	end
	local layers = doc[LAYERS]
	if layers == nil then layers = {} end
	if not is_table(layers) then
		return reject(new_error("invalid_value_type", nil, nil, LAYERS, '"layers" must be a table'))
	end
	for _, layer_id in ipairs(sorted_keys(layers)) do
		local layer = layers[layer_id]
		if type(layer_id) ~= "string" or not layer_id:match(LAYER_ID) then
			report(new_error("invalid_layer_id", tostring(layer_id), nil, nil, 'layer id "' .. tostring(layer_id) .. '" must be snake_case'))
		elseif not is_table(layer) then
			report(new_error("invalid_value_type", layer_id, nil, nil, "a layer must be a table"))
		else
			result.layers[layer_id] = load_layer(layer_id, layer, os, ctx, report)
		end
	end
	return result
end

--- Loads the user's layers.toml from the configuration folder. An absent file is
--- an empty layer set, never an error; an unreadable one is.
--- @param opts table { config_dir, os, ctx, toml_decode, read_file } where
---   read_file(path) returns the content, nil when the file does not exist, or
---   raises when it exists and cannot be read.
--- @return table result As load(), plus `path`.
function M.load_user_file(opts)
	local path = M.user_file_path(opts.config_dir, opts.ctx)
	local read_ok, text = pcall(opts.read_file, path)
	if not read_ok then
		local result = { ok = false, layers = {}, path = path,
			errors = { new_error("file_unreadable", nil, nil, nil, tostring(text)) } }
		return result
	end
	local result = M.load(text, opts.os, opts.ctx, opts.toml_decode)
	result.path = path
	return result
end





-- =======================================
-- =======================================
-- ======= 6/ Canonical text forms =======
-- =======================================
-- =======================================

--- The canonical text form of one resolution, shared with the AHK and JS
--- loaders: keystroke:ctrl+shift+Home, keystroke:End,Enter@repeat,
--- call:maximize_window, repeat_count:3, none.
--- @param r table A resolution.
--- @return string text
function M.format_resolution(r)
	if r.kind == "none" then return "none" end
	if r.kind == "repeat_count" then return "repeat_count:" .. tostring(r.count) end
	local suffix = r.repeatable and "@repeat" or ""
	if r.kind == "call" then return "call:" .. r.handler .. suffix end
	local parts = {}
	for _, chord in ipairs(r.chords) do
		local tokens = {}
		for _, mod in ipairs(chord.mods) do tokens[#tokens + 1] = mod end
		tokens[#tokens + 1] = chord.key
		parts[#parts + 1] = table.concat(tokens, "+")
	end
	return "keystroke:" .. table.concat(parts, ",") .. suffix
end

--- The comparable identity of one error: code|layer|section|key|reason_key,
--- absent parts empty. The detail text is for humans and is not compared.
--- @param e table An error record.
--- @return string signature
function M.error_signature(e)
	local parts = {}
	for i, field in ipairs({ "code", "layer", "section", "key", "reason_key" }) do
		parts[i] = e[field] == nil and "" or tostring(e[field])
	end
	return table.concat(parts, SIGNATURE_SEPARATOR)
end

return M
