--- tests/hardware/run_file_watch_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux File Watch Activation Receipts
--- DESCRIPTION:
--- Drives the production source-file watcher using real inotify and chmod.
--- Activation refusals cannot remain registered as armed handles. Readable
--- directories must still deliver debounced Lua changes and release ownership.
--- No syscall is mocked; no TOML, personal menu or keyboard is exercised.
--- ==============================================================================

local uv = require("luv")
local Watchers = require("infra.file_watchers")
assert(uv.getuid() ~= 0, "permission receipts require an ordinary user")
local root = assert(uv.fs_mkdtemp("/var/tmp/ergopti-watch-receipts-XXXXXX"))
local checks, failures = 0, 0
local directories, files = {}, {}

local function pump(milliseconds)
	local deadline = uv.hrtime() + milliseconds * 1000000
	repeat
		uv.run("nowait")
		Watchers.pump()
		uv.sleep(1)
	until uv.hrtime() >= deadline
	uv.run("nowait")
	Watchers.pump()
end

local function handles()
	local count, active = 0, 0
	uv.walk(function(handle)
		if uv.handle_get_type(handle) == "fs_event" then
			count = count + 1
			if uv.is_active(handle) then active = active + 1 end
		end
	end)
	return count, active
end

local function directory(name)
	local path = root .. "/" .. name
	assert(uv.fs_mkdir(path, 448))
	directories[#directories + 1] = path
	return path
end

local function write(path)
	files[path] = true
	local file = assert(io.open(path, "w"))
	assert(file:write("return 'changed source'\n"))
	assert(file:close())
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	for _, path in ipairs(directories) do assert(uv.fs_chmod(path, 448)) end
	Watchers.stop()
	uv.run("nowait")
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, mode in ipairs({ 0, 64, 192 }) do
	check("refused native activation retires mode " .. mode, function()
		local path = directory("denied-" .. mode)
		assert(uv.fs_chmod(path, mode))
		local probe = assert(uv.new_fs_event())
		local result, _, code = uv.fs_event_start(probe, path, {}, function() end)
		uv.close(probe)
		uv.run("nowait")
		assert(result == nil and code == "EACCES", "fixture must produce real inotify permission refusal")
		local reloads = 0
		Watchers.start({ base_dir = path, on_reload = function() reloads = reloads + 1 end })
		pump(5)
		assert(handles() == 0, "refused inotify activation was retained as an armed handle")
		assert(reloads == 0, "refused activation must publish no reload")
	end)
end

check("native Lua creation delivers exactly one debounced reload", function()
	local path = directory("readable")
	local reloads = 0
	Watchers.start({ base_dir = path, on_reload = function() reloads = reloads + 1 end })
	local count, active = handles()
	assert(count == 1 and active == 1, "readable directory did not arm an active inotify handle")
	write(path .. "/created.lua")
	pump(700)
	assert(reloads == 1, "real Lua creation did not produce exactly one debounced reload")
end)

check("native source watcher ignores non-Lua files", function()
	local path = directory("filtered")
	local reloads = 0
	Watchers.start({ base_dir = path, on_reload = function() reloads = reloads + 1 end })
	assert(handles() == 1)
	write(path .. "/ignored.txt")
	pump(700)
	assert(reloads == 0, "non-Lua event bypassed the production source filter")
end)

check("native stop releases handles and prevents pending reloads", function()
	local path = directory("stopped")
	local reloads = 0
	Watchers.start({ base_dir = path, on_reload = function() reloads = reloads + 1 end })
	write(path .. "/pending.lua")
	pump(10)
	Watchers.stop()
	uv.run("nowait")
	assert(handles() == 0, "stopped inotify handle remains owned")
	pump(700)
	assert(reloads == 0, "pending reload survived explicit stop")
end)

check("native watcher restarts after a permission refusal is repaired", function()
	local path = directory("repaired")
	local reloads = 0
	assert(uv.fs_chmod(path, 0))
	Watchers.start({ base_dir = path, on_reload = function() reloads = reloads + 100 end })
	Watchers.stop()
	uv.run("nowait")
	assert(uv.fs_chmod(path, 448))
	Watchers.start({ base_dir = path, on_reload = function() reloads = reloads + 1 end })
	local count, active = handles()
	assert(count == 1 and active == 1)
	write(path .. "/repaired.lua")
	pump(700)
	assert(reloads == 1, "repaired watcher did not resume real native delivery")
end)

for path in pairs(files) do assert(uv.fs_unlink(path)) end
for index = #directories, 1, -1 do assert(uv.fs_rmdir(directories[index])) end
assert(uv.fs_rmdir(root))
assert(handles() == 0 and not uv.loop_alive(), "fixture leaked native ownership")
print(string.format("Native file watch receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
