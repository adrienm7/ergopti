--- platform/remap/nav_layer.lua

--- ==============================================================================
--- MODULE: Native Navigation Layer
--- DESCRIPTION:
--- Compiles the shared layer vocabulary into daemon-owned evdev chords. Only
--- explicitly configured bindings run; an absent file leaves every key native.
--- ==============================================================================

local M = {}
local Layers = require("keymap.layers")
local Json = require("json")
local Toml = require("toml_codec")
local Files = require("keymap.layer_editor")

local MODIFIER_KEYS = { ctrl = "ControlLeft", alt = "AltLeft", shift = "ShiftLeft", meta = "MetaLeft" }

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

--- Reads and validates the user's complete layer before publishing any binding.
--- @param opts table { shared_root, config_dir }.
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
	if not result.ok then
		local errors = {}
		for _, item in ipairs(result.errors) do errors[#errors + 1] = Layers.error_signature(item) end
		error("invalid navigation layer: " .. table.concat(errors, "; "), 2)
	end
	for name in pairs(result.layers) do
		if name ~= "nav" then error("the native engine cannot activate layer " .. name, 2) end
	end
	return M.compile(result.layers.nav or {}, ctx.registry)
end

return M
