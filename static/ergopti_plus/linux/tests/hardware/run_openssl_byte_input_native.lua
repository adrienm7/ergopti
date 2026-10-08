--- static/ergopti_plus/linux/tests/hardware/run_openssl_byte_input_native.lua
--- ==============================================================================
--- MODULE: Actual Native OpenSSL Byte Input Witnesses
--- DESCRIPTION:
--- Requires the real FFI provider and exact source file supplied by its owner.
--- Independent literal digests exercise the unchanged native SHA256 ABI.
--- ==============================================================================

assert(type(arg[1]) == "string" and arg[1]:sub(1, 1) == "/", "an absolute admitted module source is required")
local ffi = require("ffi")
assert(type(ffi.copy) == "function", "the genuine provider memory-copy API is required")
local Digest = assert(loadfile(arg[1]))()
assert(Digest.available == true, "the actual OpenSSL 3 native binding is required")
local vectors = {
	{ name = "abc", input = "abc", expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
	{ name = "one zero byte", input = string.char(0), expected = "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d" },
	{ name = "empty", input = "", expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
}
local passed = 0
for _, vector in ipairs(vectors) do
	local actual, reason = Digest.sha256(vector.input)
	assert(actual == vector.expected and reason == nil, "actual native SHA256 byte input refused: " .. vector.name)
	passed = passed + 1
	print("PASS actual native SHA256 " .. vector.name)
end
assert(passed == 3, "all three independent native inputs are required")
print("SUMMARY 3 passed, 0 failed, 0 skipped")
