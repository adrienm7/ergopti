-- tools/test/fixtures/keylayout-rows-apply.lua

--- ==============================================================================
--- MODULE: Keylayout Number-Row Options Probe
--- DESCRIPTION:
--- Applies the number-row options to one .keylayout with the shared Lua editor
--- (layouts/keylayout_rows.lua) the macOS driver installs layouts with, so
--- test-keylayout-row-options.cjs can convert the result and compare it with the
--- Linux converter's own application of the options. Usage:
---   lua keylayout-rows-apply.lua <_shared dir> <file.keylayout> <mac_keycodes.json>
---       <convention> <order> <edges> <out.keylayout> <report.json> [<new name>]
--- Also prints the keyboard id of each further argument after the eighth one's
--- name, one per line, when ERGOPTI_KEYBOARD_IDS is set to a "|"-separated list.
--- Exit status 2 and the reason on stderr when the layout is refused.
--- ==============================================================================

package.path = arg[1] .. "/lua/?.lua;" .. arg[1] .. "/lua/?/init.lua;" .. package.path
local Json = require("json")
local Rows = require("layouts.keylayout_rows")

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local function write(path, text)
	local handle = assert(io.open(path, "wb"))
	handle:write(text)
	handle:close()
end

local function refuse(reason)
	io.stderr:write(tostring(reason), "\n")
	os.exit(2)
end

if os.getenv("ERGOPTI_KEYBOARD_IDS") then
	for name in os.getenv("ERGOPTI_KEYBOARD_IDS"):gmatch("[^|]+") do io.write(Rows.keyboard_id(name), "\n") end
	os.exit(0)
end

local codes, codes_err = Rows.key_codes(assert(Json.decode(read(arg[3]))), arg[4])
if not codes then refuse(codes_err) end
local result, err = Rows.apply(read(arg[2]), { order = arg[5], edges = arg[6] == "true" }, codes)
if not result then refuse(err) end
local text = result.text
if arg[9] then
	local renamed, rename_err = Rows.rename(text, arg[9])
	if not renamed then refuse(rename_err) end
	text = renamed
end
write(arg[7], text)
write(arg[8], Json.encode({ changed = result.changed, report = result.report }))
