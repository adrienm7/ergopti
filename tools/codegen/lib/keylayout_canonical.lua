-- tools/codegen/lib/keylayout_canonical.lua

--- ==============================================================================
--- MODULE: Keylayout Canonical Form for Code Generators
--- DESCRIPTION:
--- Prints the canonical form of one .keylayout as JSON so a Node code generator
--- converts what the shared reader (_shared/lua/layouts/keylayout.lua) reads,
--- instead of owning a second .keylayout reader:
--- `lua keylayout_canonical.lua <_shared dir> <file.keylayout>`.
---
--- FEATURES & RATIONALE:
--- 1. One reader: the XKB converter, the drivers and this generator share every
---    quoting, entity and modifier rule of the canonical parser.
--- 2. Fail fast: an unreadable file or a refused layout exits non-zero with the
---    parser's own message on stderr, never an empty document.
--- ==============================================================================

local shared_dir, keylayout_path = arg[1], arg[2]
if shared_dir == nil or keylayout_path == nil then
	io.stderr:write("usage: lua keylayout_canonical.lua <_shared dir> <file.keylayout>\n")
	os.exit(2)
end
package.path = shared_dir .. "/lua/?.lua;" .. shared_dir .. "/lua/?/init.lua;" .. package.path

local Json = require("json")
local Keylayout = require("layouts.keylayout")

local handle, open_error = io.open(keylayout_path, "rb")
if handle == nil then
	io.stderr:write("cannot read ", keylayout_path, ": ", tostring(open_error), "\n")
	os.exit(2)
end
local text = handle:read("*a")
handle:close()

local parsed, parse_error = Keylayout.parse(text)
if parsed == nil then
	io.stderr:write(keylayout_path, ": ", tostring(parse_error), "\n")
	os.exit(2)
end
io.write(Json.encode(parsed))
