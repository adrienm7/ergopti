--- tools/lib/layout_source_export.lua

--- ==============================================================================
--- MODULE: Layout Source Export Tool Adapter
--- DESCRIPTION:
--- Runs one step of the shared export adapter (_shared/layouts/engine/
--- source_export.lua) on the JSON input read from stdin and writes its JSON
--- result: `read` gives the canonical reading of a .keylayout, `xkb` the XKB
--- conversion. It reads no layout, registry or converter assets from implicit
--- paths and writes no files: the caller owns admission and publication.
--- ==============================================================================

if #arg ~= 2 or (arg[2] ~= "read" and arg[2] ~= "xkb") then
	error("usage: lua layout_source_export.lua <shared root> <read|xkb>", 0)
end
package.path = arg[1] .. "/?.lua;" .. arg[1] .. "/?/init.lua;" .. package.path
local Json = require("core.text.engine.json")
local SourceExport = require("layouts.engine.composer.source_export")

local called, result = pcall(function()
	return SourceExport[arg[2]](assert(Json.decode(io.read("*a"))))
end)
if not called then
	io.stderr:write(tostring(result), "\n")
	os.exit(2)
end
io.write(Json.encode(result))
