--- tests/hardware/run_file_path_receipts.lua
--- Drives all five ordinary FileSystem methods against actual Linux files.
--- Embedded NUL must be refused before C APIs silently select a pathname prefix.
--- Positive controls retain literal POSIX names. No syscall is simulated.
local uv = require("luv")
local FS = require("adapters.file_system")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-paths-XXXXXX"))
local checks, failures = 0, 0
local ORIGINAL, REPLACEMENT = "protected bytes", "replacement bytes"
local methods = { "read", "write", "append", "exists", "delete" }
local nul_cases = {
	{ name = "leading", path = function(path) return "\0" .. path end },
	{ name = "middle", path = function(path) return path .. "\0.invalid" end },
	{ name = "trailing", path = function(path) return path .. "\0" end },
	{ name = "multiple", path = function(path) return path .. "\0.invalid\0" end },
}

local function write(path, bytes)
	local file = assert(io.open(path, "wb"))
	assert(file:write(bytes) and file:close())
end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	return bytes
end

local function check(name, leaf, test)
	checks = checks + 1
	local path = root .. "/" .. leaf
	write(path, ORIGINAL)
	local ok, err = xpcall(function() test(path) end, debug.traceback)
	local removed, _, code = uv.fs_unlink(path)
	assert(removed or code == "ENOENT", "owned file cleanup failed")
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, method in ipairs(methods) do
	for _, case in ipairs(nul_cases) do
		check(method .. " refuses " .. case.name .. " NUL", method .. "-" .. case.name, function(path)
			local result = FS[method](case.path(path), REPLACEMENT)
			assert(uv.fs_stat(path) and read(path) == ORIGINAL, "invalid pathname mutated its native prefix")
			if method == "read" then assert(result == nil, "invalid pathname exposed prefix bytes")
			else assert(result == false, "invalid pathname was accepted") end
		end)
	end
	for index, leaf in ipairs({ "ordinary", "literal $HOME 'quotes'", "é漢字", "line\nbreak" }) do
		check(method .. " preserves literal name " .. index, method .. "-" .. leaf, function(path)
			local result = FS[method](path, REPLACEMENT)
			if method == "read" then assert(result == ORIGINAL)
			elseif method == "write" then assert(result == true and read(path) == REPLACEMENT)
			elseif method == "append" then assert(result == true and read(path) == ORIGINAL .. REPLACEMENT)
			elseif method == "exists" then assert(result == true and read(path) == ORIGINAL)
			else assert(result == true and uv.fs_stat(path) == nil) end
		end)
	end
end

assert(uv.fs_rmdir(root))
print(string.format("Native file path receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
