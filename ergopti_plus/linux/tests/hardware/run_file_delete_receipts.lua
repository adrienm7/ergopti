--- tests/hardware/run_file_delete_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux File Deletion Receipts
--- DESCRIPTION:
--- Exercises the production FileSystem adapter using actual unlink/rmdir,
--- chmod and symlink receipts. An inaccessible path is not proof of absence;
--- a broken symlink and an unreadable file can still be deleted. No filesystem
--- adapter or syscall is mocked. Run as an ordinary user with native lua-luv.
--- ==============================================================================

local uv = require("luv")
local FileSystem = require("adapters.file_system")
assert(uv.getuid() ~= 0, "permission regressions require an ordinary user")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-file-delete-XXXXXX"))
local files, directories = {}, { root }
local failures, checks = 0, 0

local function directory(name)
	local path = root .. "/" .. name
	assert(uv.fs_mkdir(path, 448))
	directories[#directories + 1] = path
	return path
end

local function file(path, content)
	files[#files + 1] = path
	local handle = assert(io.open(path, "w"))
	assert(handle:write(content or "retained bytes"))
	assert(handle:close())
	return path
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then
		print("PASS " .. name)
	else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

check("inaccessible existing path refuses deletion", function()
	local parent = directory("inaccessible")
	local path = file(parent .. "/artifact")
	assert(uv.fs_chmod(parent, 0))
	local removed = FileSystem.delete(path)
	assert(uv.fs_chmod(parent, 448))
	assert(removed == false, "inaccessible existing file was reported absent/deleted")
	assert(uv.fs_lstat(path), "denied deletion must retain the artifact")
end)

check("unreadable file in writable parent is deleted", function()
	local path = file(root .. "/unreadable")
	assert(uv.fs_chmod(path, 0))
	assert(FileSystem.delete(path) == true, "unlink does not require reading the file")
	assert(not uv.fs_lstat(path), "successful deletion left an unreadable file")
end)

check("broken symlink itself is deleted", function()
	local path = root .. "/broken-link"
	files[#files + 1] = path
	assert(uv.fs_symlink(root .. "/missing-target", path))
	assert(uv.fs_lstat(path) and not uv.fs_stat(path), "fixture must be a dangling symlink")
	assert(FileSystem.delete(path) == true)
	assert(not uv.fs_lstat(path), "successful deletion left the broken symlink")
end)

check("ordinary existing file is deleted", function()
	local path = file(root .. "/ordinary")
	assert(FileSystem.delete(path) == true)
	assert(not uv.fs_lstat(path))
end)

check("missing file is a proven no-op", function()
	local path = root .. "/absent"
	assert(not uv.fs_lstat(path))
	assert(FileSystem.delete(path) == true)
	assert(not uv.fs_lstat(path))
end)

check("missing parent is a proven no-op", function()
	assert(FileSystem.delete(root .. "/missing-parent/artifact") == true)
end)

check("non-directory ancestor remains an error", function()
	local path = file(root .. "/regular-ancestor")
	assert(FileSystem.delete(path .. "/artifact") == false, "ENOTDIR is not ENOENT")
	assert(uv.fs_lstat(path), "the ancestor must remain intact")
end)

check("nonempty directory refuses deletion", function()
	local path = directory("nonempty")
	local child = file(path .. "/child")
	assert(FileSystem.delete(path) == false)
	assert(uv.fs_lstat(child), "a rejected deletion must preserve its child")
end)

check("nonwritable parent refuses deletion", function()
	local parent = directory("nonwritable")
	local path = file(parent .. "/artifact")
	assert(uv.fs_chmod(parent, 365))
	local removed = FileSystem.delete(path)
	assert(uv.fs_chmod(parent, 448))
	assert(removed == false)
	assert(uv.fs_lstat(path))
end)

check("literal UTF-8 quotes and newlines are deleted exactly", function()
	local path = file(root .. "/é'\"\nartifact")
	assert(FileSystem.delete(path) == true)
	assert(not uv.fs_lstat(path))
end)

-- Restore owned modes before cleanup, including after a failed assertion.
for _, path in ipairs(directories) do assert(uv.fs_chmod(path, 448)) end
for _, path in ipairs(files) do if uv.fs_lstat(path) then assert(os.remove(path)) end end
for index = #directories, 1, -1 do assert(uv.fs_rmdir(directories[index])) end
print(string.format("Native file deletes: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
