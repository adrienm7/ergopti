--- vendor/remap-runtime/manifest.lua

--- Reads the owned runtime artifact pin (ADR 011, WP5) from manifest.json, so
--- the Lua owner and the build gate read the same bytes. The digest of the
--- runtime exists only after the hosted runtime build has produced and signed
--- the artifact (tools/build/remap_runtime_publish.py writes it), and
--- platform/remap/runtime_manifest.lua refuses a manifest with any field null.
local JsonCodec = require("core.fs.adapters.json_codec")
local NativePath = require("core.fs.engine.native_path")
local source = debug.getinfo(1, "S").source:sub(2)
local directory = assert(NativePath.directory_prefix(source), "Runtime manifest directory is unavailable")
local file = assert(io.open(directory .. "manifest.json", "rb"))
local content, read_error = file:read("*a")
local closed, close_error = file:close()
assert(content, read_error)
assert(closed, close_error)
local manifest, decode_error = JsonCodec.decode(content)
assert(decode_error == nil and type(manifest) == "table", decode_error or "Invalid runtime manifest")
return manifest
