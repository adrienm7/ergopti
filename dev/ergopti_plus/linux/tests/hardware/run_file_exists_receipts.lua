--- tests/hardware/run_file_exists_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux File Existence Receipts
--- DESCRIPTION:
--- Drives production FileSystem.exists with real permissions, symlinks, a FIFO
--- and a Unix socket. The C-module search path exposes only luv, reproducing a
--- deployed daemon without optional LuaFileSystem; no filesystem API is mocked.
--- Further children use native LuaJIT libc or actual Lua 5.4 shell metadata when
--- their C-module path excludes both stat libraries.
--- A FIFO probe runs in an owned subprocess with a bounded native deadline.
--- ==============================================================================

local uv = require("luv")
assert(uv.getuid() ~= 0, "native permission regressions must run without root privileges")
local original_cpath = package.cpath
local native_luv
for pattern in original_cpath:gmatch("[^;]+") do
	local path = pattern:gsub("%?", "luv")
	local file = io.open(path, "r")
	if file then file:close(); native_luv = path; break end
end
assert(native_luv, "fixture must locate the actually installed luv library")
package.cpath = native_luv
package.loaded.lfs = nil
assert(not pcall(require, "lfs"), "restricted native C path must exclude optional lfs")
local baseline = os.getenv("ERGOPTI_NATIVE_FILE_SYSTEM_BASELINE")
if baseline then package.preload["adapters.file_system"] = assert(loadfile(baseline)) end
local Files = require("adapters.file_system")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-exists-receipts-XXXXXX"))
local paths, directories = {}, {}
local checks, failures = 0, 0

local function write(name)
	local path = root .. "/" .. name
	local file = assert(io.open(path, "w"))
	assert(file:write("Owned native path bytes.") and file:close())
	paths[#paths + 1] = path
	return path
end

local function directory(name)
	local path = root .. "/" .. name
	assert(uv.fs_mkdir(path, 448))
	directories[#directories + 1] = path
	return path
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

--- Bounds any old production open() without hanging the fixture itself.
local function child_exists(path, cpath, runtime)
	local stdout, timer = uv.new_pipe(false), uv.new_timer()
	local exited, timed_out, output, child, status = false, false, "", nil, nil
	local program = "package.cpath=" .. string.format("%q", cpath) .. ";"
	if baseline then
		program = program .. "package.preload['adapters.file_system']=assert(loadfile("
			.. string.format("%q", baseline) .. "));"
	end
	program = program .. "if require('adapters.file_system').exists(" .. string.format("%q", path)
		.. ") then io.write('present');os.exit(0) else os.exit(1) end"
	child = assert(uv.spawn(runtime or "luajit", { args = { "-e", program }, stdio = { nil, stdout, nil } }, function(code)
		exited, status = true, code
		uv.timer_stop(timer)
		uv.close(timer)
		uv.close(child)
	end))
	assert(stdout:read_start(function(err, bytes)
		assert(not err)
		if bytes then output = output .. bytes else uv.close(stdout) end
	end))
	assert(timer:start(1000, 0, function()
		timed_out = true
		assert(uv.process_kill(child, "sigkill")) -- this fixture's exact child only.
	end))
	uv.run()
	assert(exited and not timed_out, "native existence receipt timed_out=" .. tostring(timed_out))
	assert(status == 0 or status == 1, "native child failed outside the existence contract")
	return status == 0 and output == "present"
end

for _, mode in ipairs({ 0, 64, 128 }) do
	check("native mode " .. mode .. " file exists without read permission", function()
		local path = write("unreadable-" .. mode)
		assert(uv.fs_chmod(path, mode))
		assert(Files.exists(path), "existence incorrectly required opening the file for reading")
	end)
end

check("ordinary readable native file exists", function() assert(Files.exists(write("ordinary"))) end)

check("native execute-only directory exists", function()
	local path = directory("execute-only")
	assert(uv.fs_chmod(path, 64))
	local ok, err = pcall(function() assert(Files.exists(path), "directory existence required read permission") end)
	assert(uv.fs_chmod(path, 448))
	assert(ok, err)
end)

check("native symlink to an unreadable file still exists", function()
	local target = write("link-target")
	assert(uv.fs_chmod(target, 0))
	local link = root .. "/link"
	assert(uv.fs_symlink(target, link))
	paths[#paths + 1] = link
	assert(Files.exists(link), "symlink metadata was confused with target readability")
end)

check("missing native path is absent", function() assert(Files.exists(root .. "/missing") == false) end)

check("dangling native symlink retains followed-target absence semantics", function()
	local link = root .. "/dangling"
	assert(uv.fs_symlink(root .. "/missing-target", link))
	paths[#paths + 1] = link
	assert(Files.exists(link) == false)
end)

check("native FIFO existence never waits for a writer", function()
	local fifo = root .. "/fifo"
	assert(require("adapters.shell_runner").run("mkfifo -- " .. require("adapters.shell_runner").quote(fifo)))
	paths[#paths + 1] = fifo
	assert(child_exists(fifo, native_luv), "native FIFO existence was refused")
end)

check("native Unix socket exists without opening a stream", function()
	local path = root .. "/socket"
	local socket = uv.new_pipe(false)
	assert(socket:bind(path))
	paths[#paths + 1] = path
	local ok, err = pcall(function() assert(Files.exists(path), "socket path was treated as an unreadable regular file") end)
	uv.close(socket)
	uv.run("nowait")
	assert(ok, err)
end)

check("native UTF-8 quotes and line breaks retain literal path bytes", function()
	assert(Files.exists(write("é漢-'quote\npath")))
end)

check("denied native parent remains an unprovable false receipt", function()
	local parent = directory("denied")
	local path = write("denied/child")
	assert(uv.fs_chmod(parent, 0))
	local ok, err = pcall(function() assert(Files.exists(path) == false) end)
	assert(uv.fs_chmod(parent, 448))
	assert(ok, err)
end)

check("NUL native path cannot alias a real prefix", function()
	assert(Files.exists(write("nul-prefix") .. "\0suffix") == false)
end)

for _, runtime in ipairs({ "luajit", "lua5.4" }) do
	for _, row in ipairs({
		{ name = "unreadable file", path = root .. "/unreadable-0", present = true },
		{ name = "FIFO", path = root .. "/fifo", present = true },
		{ name = "execute-only directory", path = root .. "/execute-only", present = true, mode = 64 },
		{ name = "missing path", path = root .. "/missing", present = false },
	}) do
		check("actual " .. runtime .. " metadata fallback checks " .. row.name .. " without native Lua stat libraries", function()
			if row.mode then assert(uv.fs_chmod(row.path, row.mode)) end
			local ok, err = pcall(function()
				assert(child_exists(row.path, "/nonexistent-ergopti-native-module/?.so", runtime) == row.present)
			end)
			if row.mode then assert(uv.fs_chmod(row.path, 448)) end
			assert(ok, err)
		end)
	end
end

for index = #paths, 1, -1 do
	-- Closing a native bound pipe can already unlink its owned socket path.
	local removed, _, code = uv.fs_unlink(paths[index])
	assert(removed or code == "ENOENT")
end
for index = #directories, 1, -1 do assert(uv.fs_rmdir(directories[index])) end
assert(uv.fs_rmdir(root))
package.cpath = original_cpath
print(string.format("Native file existence receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
