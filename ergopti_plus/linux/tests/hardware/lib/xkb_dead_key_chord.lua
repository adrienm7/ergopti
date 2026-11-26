--- tests/hardware/lib/xkb_dead_key_chord.lua

--- ==============================================================================
--- MODULE: Where A Keymap Types A Keysym
--- DESCRIPTION:
--- Compiles a printed keymap with libxkbcommon and prints, for each keysym
--- name given, the evdev code and the modifiers (shift, altgr) of the first
--- key and level of group 1 that produces it, as "<name> <evdev> <mods>".
--- Used by the live typing proof to find a layout's dead keys without a
--- hand-kept table. Usage: luajit xkb_dead_key_chord.lua <keymap> <name>...
--- ==============================================================================

local ffi = require("ffi")

ffi.cdef([[
	struct xkb_context; struct xkb_keymap;
	struct xkb_context *xkb_context_new(int);
	struct xkb_keymap *xkb_keymap_new_from_string(struct xkb_context *, const char *, int, int);
	uint32_t xkb_keysym_from_name(const char *, int);
	uint32_t xkb_keymap_num_levels_for_key(struct xkb_keymap *, uint32_t, uint32_t);
	int xkb_keymap_key_get_syms_by_level(struct xkb_keymap *, uint32_t, uint32_t, uint32_t, const uint32_t **);
	size_t xkb_keymap_key_get_mods_for_level(struct xkb_keymap *, uint32_t, uint32_t, uint32_t, uint32_t *, size_t);
	uint32_t xkb_keymap_mod_get_index(struct xkb_keymap *, const char *);
]])

local xkb = ffi.load("libxkbcommon.so.0")
local handle = assert(io.open(arg[1], "rb"))
local text = handle:read("*a")
handle:close()
local keymap = xkb.xkb_keymap_new_from_string(xkb.xkb_context_new(0), text, 1, 0)
assert(keymap ~= nil, "the keymap does not compile")
local SHIFT = 2 ^ xkb.xkb_keymap_mod_get_index(keymap, "Shift")
local ALTGR = 2 ^ xkb.xkb_keymap_mod_get_index(keymap, "Mod5")

local function mods_name(mask)
	if mask ~= 0 and mask ~= SHIFT and mask ~= ALTGR and mask ~= SHIFT + ALTGR then return nil end
	local names = {}
	if mask == SHIFT or mask == SHIFT + ALTGR then names[#names + 1] = "shift" end
	if mask == ALTGR or mask == SHIFT + ALTGR then names[#names + 1] = "altgr" end
	return table.concat(names, " ")
end

for index = 2, #arg do
	local wanted = xkb.xkb_keysym_from_name(arg[index], 0)
	local found = nil
	for keycode = 9, 255 do
		for level = 0, xkb.xkb_keymap_num_levels_for_key(keymap, keycode, 0) - 1 do
			local syms = ffi.new("const uint32_t *[1]")
			local count = xkb.xkb_keymap_key_get_syms_by_level(keymap, keycode, 0, level, syms)
			if count == 1 and syms[0][0] == wanted then
				local masks = ffi.new("uint32_t[8]")
				local mask_count = xkb.xkb_keymap_key_get_mods_for_level(keymap, keycode, 0, level, masks, 8)
				for slot = 0, tonumber(mask_count) - 1 do
					local name = mods_name(tonumber(masks[slot]))
					if name and not found then found = (keycode - 8) .. " " .. name end
				end
			end
		end
		if found then break end
	end
	if found then print(arg[index] .. " " .. found) end
end
