--- vendor/karabiner-elements/manifest.lua

--- Reads the package pin shared by repository onboarding and the macOS builder.
--- Keep package identity in manifest.json so both launch modes select identical bytes.
local JsonCodec = require("adapters.json_codec")
local source = debug.getinfo(1, "S").source:sub(2)
local directory = assert(source:match("^(.*[/\\])"), "Karabiner manifest directory is unavailable")
local file = assert(io.open(directory .. "manifest.json", "rb"))
local content, read_error = file:read("*a")
local closed, close_error = file:close()
assert(content, read_error)
assert(closed, close_error)
local manifest, decode_error = JsonCodec.decode(content)
assert(decode_error == nil and type(manifest) == "table", decode_error or "Invalid Karabiner manifest")
return manifest
