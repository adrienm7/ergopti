--- tests/hardware/run_sqlite_private_identities.lua
--- ==============================================================================
--- MODULE: Native SQLite Identity Representation Controls
--- DESCRIPTION:
--- Models returned numeric identifier representations while retaining genuine
--- file descriptors, inode bytes and native closure on both supported ABIs.
--- ==============================================================================

local root = assert(arg[1])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;"
	.. root .. "/../_shared/lua/?/init.lua;" .. package.path
local uv = require("luv")
local path = os.tmpname()
assert(uv.fs_chmod(path, 384))
local file = assert(io.open(path, "w")); assert(file:write("native identity fixture") and file:close())
local original = {}
for _, name in ipairs({ "fs_open", "fs_fstat", "fs_lstat", "fs_stat", "fs_close" }) do original[name] = uv[name] end
local native = assert(original.fs_stat(path))
assert(require("infra.private_sqlite_file").admit(path), "actual backend identifiers must remain admissible")
local integer_abi = rawget(_G, "jit") == nil
local vectors = {
	{ "zero", 0, true }, { "negative zero", -0.0, true }, { "one", 1, true },
	{ "last unit-spaced double", 2 ^ 53 - 1, true },
	{ "rounded double boundary", 2 ^ 53, false }, { "next rounded double", 2 ^ 53 + 2, false },
	{ "wide parsed integer", tonumber("9007199254740992"), integer_abi },
	{ "wide integer successor", tonumber("9007199254740993"), integer_abi },
	{ "native maximum predecessor", tonumber("9223372036854775806"), integer_abi },
	{ "native maximum wrap", tonumber("9223372036854775807"), integer_abi },
	{ "rounded maximum float", tonumber("9223372036854775807.0"), false },
	{ "negative minimum", tonumber("-9223372036854775808"), false },
	{ "negative", -1, false }, { "fraction", 1.5, false },
	{ "NaN", 0 / 0, false }, { "infinity", math.huge, false }, { "missing", nil, false },
}
local checks = 1
local ok, failure = xpcall(function()
	for _, field in ipairs({ "dev", "ino" }) do
		for _, vector in ipairs(vectors) do
			local owned, closes = nil, 0
			local function represented(stat) stat[field] = vector[2]; return stat end
			uv.fs_open = function(...)
				local descriptor, detail, code = original.fs_open(...)
				if descriptor then owned = descriptor end
				return descriptor, detail, code
			end
			uv.fs_fstat = function(descriptor) return represented(assert(original.fs_fstat(descriptor))) end
			uv.fs_lstat = function(filename)
				local stat, detail, code = original.fs_lstat(filename)
				return stat and represented(stat), detail, code
			end
			uv.fs_stat = function(filename)
				local stat, detail, code = original.fs_stat(filename)
				return stat and represented(stat), detail, code
			end
			uv.fs_close = function(descriptor) closes = closes + 1; return original.fs_close(descriptor) end
			local private = assert(loadfile(root .. "/infra/private_sqlite_file.lua"))()
			local admitted = private.admit(path)
			for name, operation in pairs(original) do uv[name] = operation end
			assert(admitted == vector[3], field .. ": " .. vector[1] .. " must preserve exact numeric identity")
			assert(private.is_settled() and owned and closes == 1 and original.fs_fstat(owned) == nil,
				"every represented identity must retire its actual descriptor exactly once")
			local current = assert(original.fs_stat(path))
			assert(current.ino == native.ino and current.dev == native.dev and current.mode % 4096 == 384)
			checks = checks + 3
		end
	end
end, debug.traceback)
for name, operation in pairs(original) do uv[name] = operation end
assert(os.remove(path))
assert(ok, failure)
print("PASS native SQLite identity representations: " .. checks .. " checks, no failures")
