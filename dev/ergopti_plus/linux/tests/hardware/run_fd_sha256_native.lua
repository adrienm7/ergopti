--- tests/hardware/run_fd_sha256_native.lua

--- ==============================================================================
--- MODULE: Actual Retained FD SHA-256 Qualification
--- DESCRIPTION:
--- Requires actual Linux LuaJIT, libuv and OpenSSL for independent NIST vectors.
--- Unlinked FD reads and original physical retirement assertions remain intact.
--- This fixture does not establish updater, publication or install admission.
--- ==============================================================================

local self_path = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local driver_root = self_path:match("^(.*)/tests/hardware/run_fd_sha256_native%.lua$")
if not driver_root then
	assert(self_path == "tests/hardware/run_fd_sha256_native.lua", "Canonical native fixture path required")
	driver_root = "."
end
package.path = driver_root .. "/?.lua;" .. driver_root .. "/?/init.lua;"
	.. driver_root .. "/../_shared/lua/?.lua;" .. driver_root .. "/../_shared/lua/?/init.lua;" .. package.path
assert(type(jit) == "table" and jit.os == "Linux", "Actual Linux LuaJIT required for native FD digest")
assert(require("luv").os_uname().sysname == "Linux", "Actual Linux libuv required for native FD digest")

--- Actual unlinked retained-FD digest vectors. No pathname read by the worker.
local uv = require("luv")
local Digest = require("infra.fd_sha256")
local Clock = require("infra.monotonic")
local factory = Digest.native()
local vectors = {
	{ "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
	{ string.rep("a", 1000000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0" },
}
local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1; print("PASS " .. label) end
for index, vector in ipairs(vectors) do
	local path = os.tmpname()
	local fd, operation, result
	local ok, err = xpcall(function()
		fd = assert(uv.fs_open(path, "w+", 384))
		local count = assert(uv.fs_write(fd, vector[1], 0))
		check(count == #vector[1], "vector " .. index .. " native input bytes")
		assert(uv.fs_unlink(path))
		check(uv.fs_stat(path) == nil, "vector " .. index .. " pathname absent before digest")
		operation = assert(factory.start(fd, #vector[1], function() return true end, Clock.now_ms() + 15000,
			function(digest, receipt) result = { digest = digest, receipt = receipt } end))
		while not result and uv.loop_alive() do uv.run("once") end
		check(result and result.digest == vector[2] and result.receipt == nil,
			"vector " .. index .. " independent NIST SHA256")
		check(operation:is_settled(), "vector " .. index .. " read context timer retirement")
	end, debug.traceback)
	if operation and not operation:is_settled() then
		operation:cancel()
		while uv.loop_alive() do uv.run("once") end
	end
	if fd and (not operation or operation:is_settled()) then
		local closed = uv.fs_close(fd)
		check(closed ~= nil and closed ~= false, "vector " .. index .. " exact parent FD close")
		fd = nil
	end
	if not ok then error(err) end
	check(fd == nil and not uv.loop_alive(), "vector " .. index .. " no retained IO timer debt")
end
assert(checks == 12, "Independent native FD digest check floor changed")
print(string.format("%d PASS, 0 FAIL, 0 SKIP", checks))
