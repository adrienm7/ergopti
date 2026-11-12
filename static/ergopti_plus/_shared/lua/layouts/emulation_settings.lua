--- _shared/lua/layouts/emulation_settings.lua

--- ==============================================================================
--- MODULE: Layout Emulation Settings (Shared)
--- DESCRIPTION:
--- Reads, from one parsed config.toml, the [layout] settings the layout
--- emulation decides with, the way the Windows emulation reads them
--- (KeylayoutEmulation_SelectedId, MasterGateDesiredFeatures, LayoutRowSwitches,
--- NumberRowEffectiveMode): which layout is emulated, which of its layers, on
--- which rows, and the number-row options. macOS and Linux pass the result to
--- layouts/keylayout_emulation.lua.
---
--- FEATURES & RATIONALE:
--- 1. One source for defaults: an absent or outdated leaf reads as its manifest
---    default through the caller's reader, never a literal here.
--- 2. A leaf in another shape is outdated configuration for that leaf alone:
---    reported through the caller's sink and read as its default.
--- 3. The layout emulated is `emulated_layout` when set, else the registry copy
---    of the built-in Ergopti layout (LayoutManager_ActiveId): Ergopti+ for the
---    ergopti_plus variant, Ergopti for "ergopti" and "none" (no helper overlay).
---    The .keylayout is the one description every driver types.
--- 4. An enum leaf written in another case (`ergopti_variant = "Ergopti_Plus"`)
---    takes its manifest spelling, as Windows' loader admits it (CFX-001).
--- ==============================================================================

local ConfigKeys = require("config_keys")
local ConfigOutdated = require("config_outdated")
local ManifestData = require("features.manifest_data")
local NumberRowPolicy = require("layout.number_row_policy")
local RowsPolicy = require("layout.layout_rows_policy")
local TableUtil = require("table_util")

local M = {}

--- The registry layout each built-in Ergopti variant types.
M.VARIANT_LAYOUTS = { none = "ergopti", ergopti = "ergopti", ergopti_plus = "ergopti_plus" }

local KEY = ConfigKeys.KEY

-- The manifest entry of each enum leaf, by path, for its canonical spelling.
local ENUM_ENTRIES = {}
for _, entry in ipairs(ManifestData.features) do
	if entry.type == "enum" and type(entry.path) == "string" then ENUM_ENTRIES[entry.path] = entry end
end
local LEAF = ConfigKeys.LEAF

local function boolean(value)
	if type(value) == "boolean" then return true end
	return false, "the value is not a boolean"
end

local function layout_id(value)
	if type(value) == "string" and (value == "" or value:match("^[a-z][a-z0-9_]*$")) then return true end
	return false, "the value is not a layout id"
end

local function variant(value)
	if M.VARIANT_LAYOUTS[value] ~= nil then return true end
	return false, "the value is not none, ergopti or ergopti_plus"
end

local function number_row(value)
	if NumberRowPolicy.mode(value) ~= nil then return true end
	return false, "the value is not native, digits or symbols"
end

-- Every leaf read, with its validator.
M.LEAVES = {
	{ name = "emulated_layout", path = KEY.LAYOUT_EMULATED_LAYOUT, valid = layout_id },
	{ name = "variant", path = KEY.LAYOUT_ERGOPTI_VARIANT, valid = variant },
	{ name = "base", path = KEY.LAYOUT_ERGOPTI_BASE, valid = boolean },
	{ name = "alt_gr", path = KEY.LAYOUT_ERGOPTI_ALT_GR, valid = boolean },
	{ name = "emulate_number_row", path = KEY.LAYOUT_EMULATE_NUMBER_ROW, valid = boolean },
	{ name = "emulate_top_row", path = KEY.LAYOUT_EMULATE_TOP_ROW, valid = boolean },
	{ name = "emulate_home_row", path = KEY.LAYOUT_EMULATE_HOME_ROW, valid = boolean },
	{ name = "emulate_bottom_row", path = KEY.LAYOUT_EMULATE_BOTTOM_ROW, valid = boolean },
	{ name = "number_row", path = KEY.LAYOUT_DIRECT_ACCESS_DIGITS, valid = number_row },
	{ name = "edges", path = KEY.LAYOUT_NUMBER_ROW_REORDER_EDGES, valid = boolean },
}

--- Resolves the emulation settings from one parsed configuration, without effects.
--- @param config table Parsed config.toml.
--- @param default_for function (path) -> the manifest default.
--- @param report function|nil (segments, detail) Called for an outdated leaf.
--- @return table settings { id = registry id|nil, base, alt_gr, layout = { emulate_<row> },
---   number_row, edges }
function M.resolve(config, default_for, report)
	if type(config) ~= "table" then error("The emulation settings need a parsed configuration.") end
	if type(default_for) ~= "function" then error("The emulation settings need the manifest defaults.") end
	local values = {}
	for _, leaf in ipairs(M.LEAVES) do
		local section, key = leaf.path:match("^([^.]+)%.([^.]+)$")
		local node = config[section]
		-- Not `and node[key] or nil`: a stored false must survive the read.
		local value = nil
		if type(node) == "table" then value = ConfigOutdated.canonical_enum_value(ENUM_ENTRIES[leaf.path], node[key]) end
		if value ~= nil then
			local valid, detail = leaf.valid(value)
			if not valid then
				if report then report({ section, key }, detail) end
				value = nil
			end
		end
		if value == nil then value = default_for(leaf.path) end
		local valid, detail = leaf.valid(value)
		if not valid then error("The manifest default of " .. leaf.path .. " is invalid: " .. detail) end
		values[leaf.name] = value
	end
	local layout = {}
	for _, row in ipairs(RowsPolicy.IDS) do layout["emulate_" .. row] = values["emulate_" .. row] end
	local id = values.emulated_layout ~= "" and values.emulated_layout or M.VARIANT_LAYOUTS[values.variant]
	return { id = id, base = values.base, alt_gr = values.alt_gr, layout = layout,
		number_row = values.number_row, edges = values.edges }
end

--- Whether the settings emulate anything: a layout and at least one of its layers.
--- @param settings table M.resolve's result.
--- @return boolean
function M.active(settings)
	return type(settings) == "table" and settings.id ~= nil and (settings.base == true or settings.alt_gr == true)
end

--- The paths a menu switch of the emulation writes directly.
M.SWITCHES = {
	[KEY.LAYOUT_ERGOPTI_BASE] = "base", [KEY.LAYOUT_ERGOPTI_ALT_GR] = "alt_gr",
	[KEY.LAYOUT_EMULATE_NUMBER_ROW] = LEAF.EMULATE_NUMBER_ROW, [KEY.LAYOUT_EMULATE_TOP_ROW] = LEAF.EMULATE_TOP_ROW,
	[KEY.LAYOUT_EMULATE_HOME_ROW] = LEAF.EMULATE_HOME_ROW, [KEY.LAYOUT_EMULATE_BOTTOM_ROW] = LEAF.EMULATE_BOTTOM_ROW,
}

--- The value of one switch in resolved settings.
--- @param settings table M.resolve's result.
--- @param path string One of M.SWITCHES.
--- @return boolean
function M.switch_value(settings, path)
	local name = M.SWITCHES[path]
	if name == nil then error("Not a layout emulation switch: " .. tostring(path)) end
	if name == "base" or name == "alt_gr" then return settings[name] == true end
	return settings.layout[name] == true
end

--- The leaves a layout choice writes, as the onboarding choice and the Windows
--- layout manager (_LayMgrWeb_SelectionOperations) write them.
--- @param choice string "none", "ergopti", "ergopti_plus" or a registry id.
--- @return table|nil values path -> value; nil for an invalid choice.
function M.choice_values(choice)
	if choice == "none" then
		return { [KEY.LAYOUT_EMULATED_LAYOUT] = "", [KEY.LAYOUT_ERGOPTI_BASE] = false,
			[KEY.LAYOUT_ERGOPTI_VARIANT] = "none" }
	end
	if choice == "ergopti" or choice == "ergopti_plus" then
		return { [KEY.LAYOUT_EMULATED_LAYOUT] = "", [KEY.LAYOUT_ERGOPTI_BASE] = true,
			[KEY.LAYOUT_ERGOPTI_VARIANT] = choice }
	end
	if type(choice) ~= "string" or not choice:match("^[a-z][a-z0-9_]*$") then return nil end
	return { [KEY.LAYOUT_EMULATED_LAYOUT] = choice, [KEY.LAYOUT_ERGOPTI_BASE] = true }
end

--- Sparse write operations for path -> value, in a stable order.
--- @param values table path -> value.
--- @param sparse_operation function The manifest reader's sparse_operation.
--- @return table operations
function M.operations(values, sparse_operation)
	local operations = {}
	for _, path in ipairs(TableUtil.sorted_keys(values)) do operations[#operations + 1] = sparse_operation(path, values[path]) end
	return operations
end

--- The .keylayout a driver emulates for a registry id: the installed copy when
--- the layout manager installed it (it may be newer than the app), the composer
--- folder's copy of a source stored for the emulation alone, else the copy the
--- app ships. A layout neither installed nor shipped cannot be emulated.
--- @param id string Registry id.
--- @param ports table { installed = id -> installed entry, read_installed = function(id) -> text|nil, err,
---   shipped = function(id) -> { entry, text }|nil, err, composer_id = string|nil,
---   read_emulation = function() -> decoded emulation table|nil, err (the composed layout's),
---   read_composed = function() -> { text, convention }|nil, err (the composed layout stored for
---   the emulation alone, read while it is not installed) }
--- @return table|nil source { id, text, convention, composer, emulation }
--- @return string|nil err Why it cannot be read.
function M.source(id, ports)
	if type(id) ~= "string" or id == "" then error("An emulation source needs a layout id.") end
	local composer = ports.composer_id ~= nil and ports.composer_id == id
	local entry = type(ports.installed) == "table" and ports.installed[id] or nil
	if entry ~= nil then
		local text, err = ports.read_installed(id)
		if type(text) ~= "string" then return nil, err or ("the installed copy of " .. id .. " is unreadable") end
		local result = { id = id, text = text, convention = entry.keycode_convention, composer = composer }
		-- The composed layout of a layout source carries the emulation table of the
		-- records its .keylayout leaves out (layouts/source_emulation.lua).
		if composer and type(ports.read_emulation) == "function" then
			local table_, emulation_err = ports.read_emulation()
			if emulation_err ~= nil then return nil, emulation_err end
			result.emulation = table_
		end
		return result, nil
	end
	-- A source stored for the emulation alone is not installed: its copy lives in
	-- the composer folder (layouts/composer.lua store).
	if composer and type(ports.read_composed) == "function" then
		local composed, composed_err = ports.read_composed()
		if composed_err ~= nil then return nil, composed_err end
		if composed ~= nil then
			local result = { id = id, text = composed.text, convention = composed.convention, composer = true }
			if type(ports.read_emulation) == "function" then
				local table_, emulation_err = ports.read_emulation()
				if emulation_err ~= nil then return nil, emulation_err end
				result.emulation = table_
			end
			return result, nil
		end
	end
	local shipped, err = ports.shipped(id)
	if type(shipped) ~= "table" then return nil, err or ("the layout " .. id .. " is neither installed nor shipped") end
	return { id = id, text = shipped.text, convention = shipped.entry.keycode_convention, composer = composer }, nil
end

return M
