-- tools/test/fixtures/keylayout-xkb-convert.lua

--- ==============================================================================
--- MODULE: Keylayout XKB Conversion Probe
--- DESCRIPTION:
--- Converts one .keylayout with the shared Lua converter and writes the XKB and
--- XCompose files, so test-keylayout-canonical-parity.cjs can compare them with
--- the Python converter's. Usage:
---   lua keylayout-xkb-convert.lua <_shared dir> <data dir> <file.keylayout>
---       <mac_keycodes.json> <convention> <layout id> <display name> <out dir>
---       [<index.json> <registry id>]
--- Exit status 2 and the reason on stderr when the layout is refused.
--- ==============================================================================

package.path = arg[1] .. "/lua/?.lua;" .. arg[1] .. "/lua/?/init.lua;" .. package.path
local Json = require("json")
local Keylayout = require("layouts.keylayout")
local Converter = require("layouts.xkb_converter")

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local function refuse(reason)
	io.stderr:write(tostring(reason), "\n")
	os.exit(2)
end

local data_dir, keylayout_path, keycodes_path = arg[2], arg[3], arg[4]
local convention, layout_id, display_name, out_dir = arg[5], arg[6], arg[7], arg[8]
local hints = nil
if arg[9] then
	for _, entry in ipairs(assert(Json.decode(read(arg[9]))).layouts) do
		if entry.id == arg[10] then hints = entry.xkb end
	end
end

local canonical, parse_err = Keylayout.parse(read(keylayout_path))
if not canonical then refuse(parse_err) end
local keycodes, keycodes_err = Converter.keycodes(assert(Json.decode(read(keycodes_path))), convention)
if not keycodes then refuse(keycodes_err) end
local result, err = Converter.convert(canonical, {
	keycodes = keycodes,
	keysyms = assert(Json.decode(read(data_dir .. "/key_sym.json"))).keysyms,
	template = read(data_dir .. "/xkb_symbols.txt"),
	layout_id = layout_id,
	display_name = display_name,
	hints = hints,
})
if not result then refuse(err) end
for name, text in pairs({ [layout_id .. ".xkb"] = result.symbols_text, [layout_id .. ".XCompose"] = result.compose_text }) do
	local handle = assert(io.open(out_dir .. "/" .. name, "wb"))
	handle:write(text)
	handle:close()
end
