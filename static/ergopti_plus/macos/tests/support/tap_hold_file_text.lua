--- tests/support/tap_hold_file_text.lua

--- ==============================================================================
--- MODULE: Tap-Hold File Text Fixture
--- DESCRIPTION:
--- Lets a remap test keep stating its source in the Karabiner model (the
--- `[tap_holds]` / `[mod_combos.config.esc_tab]` layout config_karabiner.toml had)
--- while the driver reads and writes the shared tap_hold.toml
--- (_shared/tap_hold/SCHEMA.md). `file(text)` is the shared file a model text
--- becomes, stamped with the current version; `model(text)` is the model a
--- shared file reads as, without the stamp. Both go through the driver's own
--- translation (platform/remap/tap_hold_file.lua), never a second one.
---
--- An entry under an id no driver has (a retired key or combination, the
--- outdated-entry cases) has no translation: `file` writes it under the same
--- id in the shared section and `model` reads it back there, so a test can
--- still state and observe it.
--- ==============================================================================

local M = {}

local TomlCodec = require("toml_codec")
local SharedFile = require("tap_hold.shared_file")

--- The driver's translation binding, loaded fresh for the current stub scope.
local function binding()
	return require("platform.remap.tap_hold_file")
end

--- The array test of one decoded document.
local function table_test(shapes)
	return function(value) return type(value) == "table" and not (shapes and shapes.arrays[value]) end
end

-- Model section -> file section of the entries keyed by id.
local ENTRY_SECTIONS = {
	{ model = { "tap_holds", "config" }, file = { "tap_hold", "keys" } },
	{ model = { "mod_combos", "config" }, file = { "mod_combos", "config" } },
}

--- The table at a path, nil when a segment is not a table.
local function at(document, path, is_table)
	local node = document
	for _, segment in ipairs(path) do
		node = node[segment]
		if not is_table(node) then return nil end
	end
	return node
end

--- The table at a path, created on the way.
local function ensure(document, path)
	local node = document
	for _, segment in ipairs(path) do
		node[segment] = node[segment] or {}
		node = node[segment]
	end
	return node
end

--- Whether an id names nothing the context can translate.
local function untranslatable(ctx, section, id)
	if section.file[1] == "tap_hold" then return ctx.key_of_hs[id] == nil and not ctx.catalogue_ids[id] end
	return ctx.pair_of_combo[id] == nil and ctx.combo_of_pair[id] == nil
		and not (type(id) == "string" and id:find("_then_", 1, true) and (function()
			local first, second = id:match("^(.-)_then_(.+)$")
			return ctx.catalogue_ids[first] and ctx.catalogue_ids[second]
		end)())
end

--- The shared tap_hold.toml text a Karabiner model text becomes.
--- @param text string Model text (config_karabiner.toml layout).
--- @return string text Shared file text, stamped; unparseable text unchanged.
function M.file(text)
	local model, shapes = TomlCodec.decode_with_shapes(text)
	-- Bytes that do not parse are a corrupt file in any layout: written as they are.
	if type(model) ~= "table" then return text end
	local file = binding()
	local ctx, is_table = file.context(), table_test(shapes)
	local held = {}
	for index, section in ipairs(ENTRY_SECTIONS) do
		local entries = at(model, section.model, is_table)
		held[index] = {}
		for id, value in pairs(entries or {}) do
			if untranslatable(ctx, section, id) then held[index][id], entries[id] = value, nil end
		end
	end
	local document = SharedFile.from_karabiner(model, ctx, is_table)
	for index, section in ipairs(ENTRY_SECTIONS) do
		for id, value in pairs(held[index]) do ensure(document, section.file)[id] = value end
	end
	document._meta = document._meta or {}
	document._meta.schema_version = file.registry().current
	if shapes then
		-- The receipts are keyed by table: the sections carried by reference keep their spelling.
		return TomlCodec.encode_with_shapes(document, { arrays = shapes.arrays, numbers = shapes.numbers,
			strings = shapes.strings, document = document })
	end
	return TomlCodec.encode(document)
end

--- The Karabiner model a shared tap_hold.toml text reads as.
--- @param text string Shared file text.
--- @return table model Without the version stamp.
function M.model(text)
	local document, shapes = TomlCodec.decode_with_shapes(text)
	assert(type(document) == "table", "tap_hold.toml text does not parse")
	return M.model_of(document, shapes)
end

--- The Karabiner model of a decoded shared tap_hold.toml: arrays and the
--- sections carried by reference stay the decoded tables, so a test can ask
--- the shape receipt about them.
--- @param document table Decoded shared file.
--- @param shapes table|nil Its shape receipt.
--- @return table model Without the version stamp.
function M.model_of(document, shapes)
	local ctx, is_table = binding().context(), table_test(shapes)
	local model = SharedFile.to_karabiner(document, ctx, is_table)
	model._meta = nil
	for _, section in ipairs(ENTRY_SECTIONS) do
		for id, value in pairs(at(document, section.file, is_table) or {}) do
			if untranslatable(ctx, section, id) then ensure(model, section.model)[id] = value end
		end
	end
	return model
end

return M
