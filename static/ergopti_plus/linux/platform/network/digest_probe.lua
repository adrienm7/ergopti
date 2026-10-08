--- platform/network/digest_probe.lua

--- Native read-only OpenSSL3 descriptor and EVP symbol admission. This does not
--- allocate digest contexts or claim a completed FD digest/installed pipeline.
local driver = assert(arg[1], "Exact installed driver root required")
assert(driver:sub(1, 1) == "/", "Absolute installed driver root required")
local source = debug.getinfo(1, "S").source:gsub("^@", "")
assert(source == driver .. "/platform/network/digest_probe.lua", "Exact native probe owner required")
assert(type(jit) == "table" and jit.os == "Linux", "Actual Linux LuaJIT required")
local projected = dofile(driver .. "/_generated/native_runtime.lua")
local runtime = type(projected) == "table" and rawget(projected, "archive_digest_runtime")
local soname = type(runtime) == "table" and rawget(runtime, "soname")
assert(type(runtime) == "table" and rawget(runtime, "schema_version") == 1
	and soname == "libcrypto.so.3",
	"Generated digest runtime descriptor unavailable")
local ffi = require("ffi")
ffi.cdef([[
	typedef struct evp_md_st EVP_MD;
	typedef struct evp_md_ctx_st EVP_MD_CTX;
	typedef struct engine_st ENGINE;
	EVP_MD_CTX *EVP_MD_CTX_new(void);
	void EVP_MD_CTX_free(EVP_MD_CTX *ctx);
	const EVP_MD *EVP_sha256(void);
	int EVP_DigestInit_ex(EVP_MD_CTX *ctx, const EVP_MD *type, ENGINE *impl);
	int EVP_DigestUpdate(EVP_MD_CTX *ctx, const void *data, size_t count);
	int EVP_DigestFinal_ex(EVP_MD_CTX *ctx, unsigned char *md, unsigned int *s);
]])
local crypto = ffi.load(soname)
for _, name in ipairs({ "EVP_MD_CTX_new", "EVP_MD_CTX_free", "EVP_sha256",
	"EVP_DigestInit_ex", "EVP_DigestUpdate", "EVP_DigestFinal_ex" }) do
	assert(crypto[name], "Required OpenSSL3 EVP symbol unavailable")
end
print("Native OpenSSL3 descriptor and EVP symbols admitted; FD digest remains separately qualified")
