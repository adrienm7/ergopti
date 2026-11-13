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
--- Also prints the keyboard id of each name read from stdin, one per line, when
--- ERGOPTI_KEYBOARD_IDS is "1": stdin carries the exact UTF-8 bytes, which a
--- Windows environment value does not (the C runtime hands Lua the ANSI page).
--- Exit status 2 and the reason on stderr when the layout is refused.
--- ==============================================================================

package.path = arg[1] .. "/?.lua;" .. arg[1] .. "/?/init.lua;" .. package.path
local Json = require("core.text.engine.json")
local Rows = require("layouts.engine.composer.keylayout_rows")

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

if os.getenv("ERGOPTI_KEYBOARD_IDS") == "1" then
	for name in io.read("*a"):gmatch("[^\n]+") do io.write(Rows.keyboard_id(name), "\n") end
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
