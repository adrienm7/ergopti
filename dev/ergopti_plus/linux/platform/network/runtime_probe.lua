--- platform/network/runtime_probe.lua

--- ==============================================================================
--- MODULE: Installed Network Runtime Admission (Linux)
--- DESCRIPTION:
--- Read-only CLI for the installer and installed-layout qualification. Resolves
--- native/shared code from its own source plus the explicit shared-root argument,
--- never CWD; emits only a closed capability receipt, never settings or request
--- data. It does not call the native proxy lookup API.
--- ==============================================================================

local source = debug.getinfo(1, "S").source
local root = source:match("^@(/.+)/platform/network/runtime_probe%.lua$")
local shared = arg[1]
if not root or type(shared) ~= "string" or shared:sub(1, 1) ~= "/" or arg[2] ~= nil then
	io.stdout:write('{"ok":false,"error":"proxy-runtime-unavailable"}\n')
	os.exit(1)
end
package.path = root .. "/?.lua;" .. shared .. "/lua/?.lua;" .. package.path
local loaded, receipt = pcall(function()
	return require("platform.network.native_proxy_runtime").inspect()
end)
if not loaded then receipt = { ok = false, error = "proxy-native-unavailable" } end
local json_loaded, Json = pcall(require, "json")
if not json_loaded then
	io.stdout:write('{"ok":false,"error":"proxy-runtime-unavailable"}\n')
	os.exit(1)
end
io.stdout:write(Json.encode(receipt), "\n")
io.stdout:flush()
os.exit(receipt.ok == true and 0 or 1)
