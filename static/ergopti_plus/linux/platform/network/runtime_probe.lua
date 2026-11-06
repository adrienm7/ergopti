--- platform/network/runtime_probe.lua
-- The application-owned child is invoked directly, without a global Lua init.
local literal_driver = os.getenv("ERGOPTI_LITERAL_DRIVER_ROOT")
if literal_driver and literal_driver ~= "" then
	local literal_shared = assert(os.getenv("ERGOPTI_LITERAL_SHARED_ROOT"), "literal shared root unavailable")
	assert(loadfile(literal_driver .. "/infra/literal_module_loader.lua"))().install(literal_driver, literal_shared, os.getenv("ERGOPTI_RUNTIME_PREFIX"), os.getenv("ERGOPTI_LITERAL_DIRECT") == "1" and "child-direct" or (os.getenv("ERGOPTI_LITERAL_DAEMON") == "1" and "daemon" or nil))
end


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
if literal_driver then
	local resolver = assert(package.loaded["infra.literal_module_loader"])
	resolver.prepend({ { root, ".lua" }, { shared .. "/lua", ".lua" } })
else
	package.path = root .. "/?.lua;" .. shared .. "/lua/?.lua;" .. package.path
end
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
