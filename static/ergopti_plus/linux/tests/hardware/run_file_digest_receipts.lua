--- tests/hardware/run_file_digest_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux File Digest Receipts
--- DESCRIPTION:
--- Drives the production FileDigest with actual GNU sha256sum, libuv, literal
--- filenames and permission failures. Known SHA-256 vectors independently check
--- the result; no process API or command output is simulated.
--- ==============================================================================

local uv = require("luv")
local Digest = require("adapters.file_digest")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-digest-XXXXXX"))
local directories, files = { root }, {}
local checks, failures = 0, 0
local ABC_SHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
local EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

--- Creates one owned directory using native filesystem receipts.
local function mkdir(path)
	assert(uv.fs_mkdir(path, 448))
	directories[#directories + 1] = path
	return path
end

--- Produces an existing-parent path of an exact byte length within NAME_MAX.
local function long_path(length)
	local parent = mkdir(root .. "/case-" .. tostring(length))
	while length - #parent - 1 > 200 do
		parent = mkdir(parent .. "/" .. string.rep("d", 180))
	end
	local path = parent .. "/" .. string.rep("f", length - #parent - 1)
	assert(#path == length)
	return path
end

--- Writes actual fixture bytes, retaining their path for exact cleanup.
local function write(path, bytes)
	local file = assert(io.open(path, "wb"))
	assert(file:write(bytes))
	assert(file:close())
	files[#files + 1] = path
end

--- Waits for a real subprocess receipt and verifies complete handle retirement.
local function hash(path)
	local value, err, callbacks = nil, nil, 0
	assert(Digest.sha256(path, { timeout_ms = 2000 }, function(result, failure)
		value, err, callbacks = result, failure, callbacks + 1
	end), "native hashing dispatch refused")
	local deadline = uv.hrtime() + 5000000000
	repeat
		uv.run("nowait")
		uv.sleep(1)
	until not uv.loop_alive() or uv.hrtime() >= deadline
	assert(not uv.loop_alive(), "digest leaked live native handles")
	assert(callbacks == 1 and not Digest.isActive(), "digest completion ownership did not retire")
	return value, err
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, length in ipairs({ 957, 958, 1106, 3500 }) do
	check("hashes a real " .. length .. "-byte absolute path", function()
		local path = long_path(length)
		write(path, "abc")
		local value, err = hash(path)
		assert(value == ABC_SHA256 and err == nil, tostring(err or value))
	end)
end

for index, name in ipairs({ "ordinary", "literal $HOME 'quotes'", "é漢字", "line\nbreak", "back\\slash" }) do
	check("hashes literal filename case " .. index, function()
		local path = root .. "/" .. name
		write(path, "abc")
		local value, err = hash(path)
		assert(value == ABC_SHA256 and err == nil, tostring(err or value))
	end)
end

check("hashes the independent empty-file vector", function()
	local path = root .. "/empty"
	write(path, "")
	local value, err = hash(path)
	assert(value == EMPTY_SHA256 and err == nil, tostring(err or value))
end)

check("rejects a missing file with its native diagnostic", function()
	local value, err = hash(root .. "/missing")
	assert(value == nil and type(err) == "string" and err:find("missing", 1, true), tostring(err))
end)

check("rejects an unreadable file with its native diagnostic", function()
	assert(uv.getuid() ~= 0, "permission regression must run without root privileges")
	local path = root .. "/unreadable"
	write(path, "abc")
	assert(uv.fs_chmod(path, 0))
	local value, err = hash(path)
	assert(value == nil and type(err) == "string" and err:find("unreadable", 1, true), tostring(err))
end)

assert(Digest.cancel())
uv.run("nowait")
for index = #files, 1, -1 do assert(uv.fs_unlink(files[index])) end
for index = #directories, 1, -1 do assert(uv.fs_rmdir(directories[index])) end
print(string.format("Native file digest receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
