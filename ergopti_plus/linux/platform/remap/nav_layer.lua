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
local Files = require("keymap.layer_editor")
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
	local ctx = Layers.load_context({
		shared_root = opts.shared_root, json_decode = Json.decode,
		toml_decode = Toml.decode, read_file = Files.read_shipped,
	})
	local result = Layers.load_user_file({
		config_dir = opts.config_dir, os = "linux", ctx = ctx,
		toml_decode = Toml.decode, read_file = Files.read_file,
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
	return M.compile(result.layers.nav or {}, ctx.registry)
end

return M
