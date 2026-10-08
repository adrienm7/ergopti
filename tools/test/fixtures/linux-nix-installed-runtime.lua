--- tools/test/fixtures/linux-nix-installed-runtime.lua
--- Qualification-only LUA_INIT: the genuine generated Nix wrapper supplies paths.
local out = assert(os.getenv("ERGOPTI_NIX_PACKAGE_ROOT"), "Exact Nix package required")
assert(out:match("^/nix/store/[a-z0-9]+%-[^/]+$"), "Nix package identity required")
assert(type(jit) == "table" and jit.os == "Linux", "Genuine Linux LuaJIT required")
local native_path = os.getenv("LUA_CPATH")
if native_path ~= nil then
 for component in native_path:gmatch("[^;]+") do
  assert(component:match("^/nix/store/"), "Every explicit native Lua path must come from the package closure")
 end
end
local uv = require("luv")
local Paths = require("infra.paths")
assert(Paths.driver_root() == out .. "/lib/ergopti", "Exact installed driver root required")
assert(Paths.shared_root() == out .. "/lib/ergopti/_shared", "Exact installed shared root required")
assert(uv.exepath():match("^/nix/store/"), "Packaged interpreter required")
for _, name in ipairs({ "spawn", "new_timer", "new_pipe", "fs_open", "fs_read", "fs_close", "fs_stat", "hrtime" }) do
 assert(type(uv[name]) == "function", "Actual native luv port required")
end
local ffi = require("ffi")
ffi.cdef("unsigned int ergopti_archive_publication_abi_version(void);")
local backend = ffi.load(out .. "/lib/ergopti/bin/libergopti_archive_publication.so")
assert(backend.ergopti_archive_publication_abi_version() == 1, "Actual installed C ABI required")
local native = require("platform.network.native_proxy_runtime").inspect()
assert(native.ok == true and native.acknowledgement == "native-runtime" and native.schema_available == true,
 "Actual supported native GIO schema/backend required")
local digest = require("infra.openssl_digest")
assert(digest.available == true, "Actual native libcrypto required")
assert(digest.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "Independent NIST digest required")
local count = 0
uv.walk(function() count = count + 1 end)
assert(count == 0, "No native handle debt permitted")
for _, label in ipairs({ "installed shared root", "packaged LuaJIT and luv", "installed C backend ABI", "native GIO backend and compiled schema", "native OpenSSL NIST SHA256" }) do
 io.stdout:write("PASS ", label, "\n")
end
io.stdout:flush()
os.exit(0)
