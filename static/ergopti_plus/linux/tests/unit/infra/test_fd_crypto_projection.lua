--- tests/unit/infra/test_fd_crypto_projection.lua

--- Independent actual factory-call projection controls; no native FFI credit.
local Helpers = require("tests.helpers")
local cases = {
	{ "future ABI4 identity", { archive_digest_runtime = { schema_version = 1, soname = "libcrypto.so.4" } } },
	{ "numeric old ABI1 identity", { archive_digest_runtime = { schema_version = 1, soname = "libcrypto.so.1" } } },
	{ "missing projection", {} },
	{ "missing digest descriptor", { network_runtime = {} } },
	{ "invalid descriptor type", { archive_digest_runtime = "pretend" } },
	{ "wrong schema", { archive_digest_runtime = { schema_version = 2, soname = "libcrypto.so.3" } } },
	{ "empty identity", { archive_digest_runtime = { schema_version = 1, soname = "" } } },
	{ "path identity", { archive_digest_runtime = { schema_version = 1, soname = "/tmp/libcrypto.so.3" } } },
	{ "wrong library family", { archive_digest_runtime = { schema_version = 1, soname = "libssl.so.3" } } },
	{ "old dotted ABI identity", { archive_digest_runtime = { schema_version = 1, soname = "libcrypto.so.1.1" } } },
}
Helpers.describe("infra/fd_sha256 generated native descriptor", function()
	for _, case in ipairs(cases) do
		Helpers.it(case[1] .. " refuses before native lookup", function()
			local saved = package.loaded["_generated.native_runtime"]
			local ffi_before = package.loaded["ffi"]
			local loads = 0
			package.loaded["_generated.native_runtime"] = case[2]
			package.loaded["ffi"] = { os = "Linux", cdef = function() end,
				load = function() loads = loads + 1; error("Unexpected native load") end }
			local ok, err = xpcall(function()
				local called = pcall(require("infra.fd_sha256").native)
				Helpers.assert_eq(called, false, "Malformed projection cannot construct native digest")
				Helpers.assert_eq(loads, 0, "No native library acquisition")
			end, debug.traceback)
			package.loaded["_generated.native_runtime"], package.loaded["ffi"] = saved, ffi_before
			assert(ok, err)
		end)
	end
	Helpers.it("metatable descriptor cannot fabricate fields", function()
		local saved = package.loaded["_generated.native_runtime"]
		local reads = 0
		package.loaded["_generated.native_runtime"] = { archive_digest_runtime = setmetatable({}, {
			__index = function(_, key) reads = reads + 1; return key == "schema_version" and 1 or "libcrypto.so.3" end,
		}) }
		local ok, err = xpcall(function()
			local called, refusal = pcall(require("infra.fd_sha256").native)
			Helpers.assert_eq(called, false, "No metadata getter authority")
			Helpers.assert_eq(type(refusal), "string", "Descriptor refusal has a concrete reason")
			Helpers.assert_true(refusal:find("Generated FD digest runtime descriptor unavailable", 1, true) ~= nil,
				"The raw generated descriptor is the refused capability")
			Helpers.assert_eq(reads, 0, "No foreign field probe")
		end, debug.traceback)
		package.loaded["_generated.native_runtime"] = saved
		assert(ok, err)
	end)
end)

-- These controls execute the actual native CLI chunk only through descriptor
-- refusal. Controlled jit/dofile/ffi ports give no native execution credit.
Helpers.describe("platform/network/digest_probe exact raw descriptor", function()
	for _, case in ipairs({
		{ "probe future ABI4", { schema_version = 1, soname = "libcrypto.so.4" } },
		{ "probe numeric old ABI1", { schema_version = 1, soname = "libcrypto.so.1" } },
		{ "probe metatable descriptor", nil },
	}) do
		Helpers.it(case[1] .. " refuses before FFI lookup", function()
			local root = Helpers.driver_root()
			local saved = { dofile = dofile, arg = arg, jit = jit, ffi = package.loaded["ffi"] }
			local loads, reads = 0, 0
			local descriptor = case[2] or setmetatable({}, {
				__index = function(_, key) reads = reads + 1; return key == "schema_version" and 1 or "libcrypto.so.3" end,
			})
			_G.arg, _G.jit = { root }, { os = "Linux" }
			_G.dofile = function(path)
				Helpers.assert_eq(path, root .. "/_generated/native_runtime.lua", "Exact actual projection path")
				return { archive_digest_runtime = descriptor }
			end
			package.loaded["ffi"] = { cdef = function() end,
				load = function() loads = loads + 1; return {} end }
			local ok, err = xpcall(function()
				local chunk = assert(loadfile(root .. "/platform/network/digest_probe.lua"))
				local called, refusal = pcall(chunk)
				Helpers.assert_eq(called, false, "Invalid probe descriptor cannot admit crypto")
				Helpers.assert_eq(type(refusal), "string", "Native probe refusal has a concrete reason")
				Helpers.assert_true(refusal:find("Generated digest runtime descriptor unavailable", 1, true) ~= nil,
					"The native probe refuses the raw generated descriptor")
				Helpers.assert_eq(loads, 0, "No native load authority")
				Helpers.assert_eq(reads, 0, "No metatable metadata probe")
			end, debug.traceback)
			_G.dofile, _G.arg, _G.jit, package.loaded["ffi"] = saved.dofile, saved.arg, saved.jit, saved.ffi
			assert(ok, err)
		end)
	end
end)
