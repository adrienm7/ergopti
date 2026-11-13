--- tests/support/tap_hold_file_text.lua

--- ==============================================================================
--- MODULE: Tap-Hold File Text Fixture
--- DESCRIPTION:
--- Lets a remap test keep stating its source in the Karabiner model (the
--- `[tap_holds]` / `[mod_combos.config.esc_tab]` layout config_karabiner.toml had)
--- while the driver reads and writes the shared tap_hold.toml
--- (_shared/tap_hold/data/SCHEMA.md) and the config.toml beside it, which holds the
--- manifest's tap-hold rows (`[tap_holds]` enabled, sticky_timeout_ms,
--- lone_modifier_tap_max_ms and `[mod_combos]`). `file(text)` is the pair a
--- model text becomes (tap_hold.toml stamped with the current version, then the
--- config.toml rows or nil); `model(text, config_text)` is the model a pair
--- reads as, without the stamp. Both go through the driver's own translation
--- (platform/remap/tap_hold_file.lua), never a second one; `write_config`,
--- `read_config` and `remove_config` reach the config.toml beside a path.
---
--- An entry under an id no driver has (a retired key or combination, the
--- outdated-entry cases) has no translation: `file` writes it under the same
--- id in the shared section and `model` reads it back there, so a test can
--- still state and observe it.
--- ==============================================================================

local M = {}

local TomlCodec = require("core.text.engine.toml_codec")
local SharedFile = require("tap_hold.engine.shared_file")

--- The driver's translation binding, loaded fresh for the current stub scope.
local function binding()
	return require("platform.remap.tap_hold_file")
end

--- The array test of one decoded document.
local function table_test(shapes)
	return function(value) return type(value) == "table" and not (shapes and shapes.arrays[value]) end
end

-- The [tap_holds] leaves config.toml keeps.
local CONFIG_TAP_HOLD_LEAVES = { "enabled", "sticky_timeout_ms", "lone_modifier_tap_max_ms" }

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

--- Whether a key id names nothing the context can translate.
local function untranslatable_key(ctx, id)
	return ctx.key_of_hs[id] == nil and not ctx.catalogue_ids[id]
end

--- The config.toml beside a tap_hold.toml path, as the driver resolves it.
--- @param path string
--- @return string
function M.config_path(path)
	return require("keyboard.engine.runtime.config").config_toml_path_for(path)
end

--- Writes, or with nil removes, the config.toml beside a tap_hold.toml path.
--- @param path string The tap_hold.toml path.
--- @param text string|nil
function M.write_config(path, text)
	local target = M.config_path(path)
	if text == nil then os.remove(target) return end
	local fh = assert(io.open(target, "wb")); assert(fh:write(text)); assert(fh:close())
end

--- The config.toml beside a tap_hold.toml path, nil when absent.
--- @param path string
--- @return string|nil
function M.read_config(path)
	local fh = io.open(M.config_path(path), "rb")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

--- A tap_hold.toml path in a directory of its own, so the config.toml the driver
--- reads beside it belongs to this test alone: beside os.tmpname() it would be
--- one shared file of the scratch directory, read and written by every test.
--- @return string path The tap_hold.toml path; the file does not exist yet.
function M.private_path()
	local lfs = require("lfs")
	local stem = os.tmpname()
	os.remove(stem)
	local dir = stem .. ".d"
	assert(lfs.mkdir(dir), "cannot create the private fixture directory " .. dir)
	return dir .. "/tap_hold.toml"
end

--- Removes a private_path() directory and everything a test left in it.
--- @param path string What private_path() returned.
function M.remove_private(path)
	local lfs = require("lfs")
	local dir = assert(path:match("^(.*)/tap_hold%.toml$"), "not a private fixture path: " .. tostring(path))
	for entry in lfs.dir(dir) do
		if entry ~= "." and entry ~= ".." then os.remove(dir .. "/" .. entry) end
	end
	assert(lfs.rmdir(dir), "cannot remove the private fixture directory " .. dir)
end

--- Removes the config.toml beside a path and the backups a scope wrote of it.
--- @param path string
function M.remove_config(path)
	os.remove(M.config_path(path))
end

--- The pair of texts a Karabiner model text becomes.
--- @param text string Model text (config_karabiner.toml layout).
--- @return string text Shared tap_hold.toml text, stamped; unparseable text unchanged.
--- @return string|nil config_text The config.toml rows, nil when the model holds none.
function M.file(text)
	local model, shapes = TomlCodec.decode_with_shapes(text)
	-- Bytes that do not parse are a corrupt file in any layout: written as they are.
	if type(model) ~= "table" then return text end
	local file = binding()
	local ctx, is_table = file.context(), table_test(shapes)
	-- The config.toml rows: the owned [tap_holds] leaves and the whole
	-- [mod_combos], each pair under its shared id (an untranslatable id as is).
	local config = {}
	local tap_holds = is_table(model.tap_holds) and model.tap_holds or nil
	if tap_holds then
		for _, leaf in ipairs(CONFIG_TAP_HOLD_LEAVES) do
			if tap_holds[leaf] ~= nil then ensure(config, { "tap_holds" })[leaf] = tap_holds[leaf] end
			tap_holds[leaf] = nil
		end
	end
	if model.mod_combos ~= nil then
		local combos = model.mod_combos
		if is_table(combos) then
			local out = {}
			for field, value in pairs(combos) do out[field] = value end
			if is_table(combos.config) then
				out.config = {}
				for id, entry in pairs(combos.config) do out.config[ctx.pair_of_combo[id] or id] = entry end
			end
			combos = out
		end
		config.mod_combos = combos
		model.mod_combos = nil
	end
	local held = {}
	for id, value in pairs(at(model, { "tap_holds", "config" }, is_table) or {}) do
		if untranslatable_key(ctx, id) then held[id], model.tap_holds.config[id] = value, nil end
	end
	local document = SharedFile.new_file(model, ctx, is_table)
	for id, value in pairs(held) do ensure(document, { "tap_hold", "keys" })[id] = value end
	document._meta = document._meta or {}
	document._meta.schema_version = file.registry().current
	local function encode(doc)
		if shapes then
			-- The receipts are keyed by table: the sections carried by reference keep their spelling.
			return TomlCodec.encode_with_shapes(doc, { arrays = shapes.arrays, numbers = shapes.numbers,
				strings = shapes.strings, document = doc })
		end
		return TomlCodec.encode(doc)
	end
	return encode(document), next(config) ~= nil and encode(config) or nil
end

--- The Karabiner model a pair of texts reads as.
--- @param text string Shared file text.
--- @param config_text string|nil The config.toml beside it.
--- @return table model Without the version stamp.
function M.model(text, config_text)
	local document, shapes = TomlCodec.decode_with_shapes(text)
	assert(type(document) == "table", "tap_hold.toml text does not parse")
	local config, config_shapes
	if config_text ~= nil then
		config, config_shapes = TomlCodec.decode_with_shapes(config_text)
		assert(type(config) == "table", "config.toml text does not parse")
	end
	return M.model_of(document, shapes, config, config_shapes)
end

--- The Karabiner model the pair of files at a tap_hold.toml path reads as,
--- with an array test over both shape receipts.
--- @param path string The tap_hold.toml path; its config.toml may be absent.
--- @return table model Without the version stamp.
--- @return function is_array(value) -> boolean True for an array of either file.
function M.decode_pair(path)
	local fh = assert(io.open(path, "rb"))
	local text = fh:read("*a")
	fh:close()
	local document, shapes = TomlCodec.decode_with_shapes(text)
	assert(type(document) == "table", "tap_hold.toml text does not parse")
	local config, config_shapes
	local config_text = M.read_config(path)
	if config_text ~= nil then
		config, config_shapes = TomlCodec.decode_with_shapes(config_text)
		assert(type(config) == "table", "config.toml text does not parse")
	end
	local function is_array(value)
		return (shapes and shapes.arrays[value]) == true or (config_shapes and config_shapes.arrays[value]) == true
	end
	return M.model_of(document, shapes, config, config_shapes), is_array
end

--- The Karabiner model of a decoded pair: arrays and the sections carried by
--- reference stay the decoded tables, so a test can ask the shape receipt
--- about them.
--- @param document table Decoded shared file.
--- @param shapes table|nil Its shape receipt.
--- @param config table|nil Decoded config.toml.
--- @param config_shapes table|nil Its shape receipt.
--- @return table model Without the version stamp.
function M.model_of(document, shapes, config, config_shapes)
	local ctx, is_table = binding().context(), table_test(shapes)
	local model = SharedFile.to_karabiner(document, ctx, is_table)
	model._meta = nil
	for id, value in pairs(at(document, { "tap_hold", "keys" }, is_table) or {}) do
		if untranslatable_key(ctx, id) then ensure(model, { "tap_holds", "config" })[id] = value end
	end
	if config ~= nil then
		local config_is_table = table_test(config_shapes)
		local part = SharedFile.config_to_karabiner(config, ctx, config_is_table)
		if part.tap_holds ~= nil then
			for leaf, value in pairs(part.tap_holds) do ensure(model, { "tap_holds" })[leaf] = value end
		end
		model.mod_combos = part.mod_combos
		for id, value in pairs(at(config, { "mod_combos", "config" }, config_is_table) or {}) do
			if ctx.combo_of_pair[id] == nil and not (type(id) == "string" and id:find("_then_", 1, true)) then
				ensure(model, { "mod_combos", "config" })[id] = value
			end
		end
	end
	return model
end

return M
