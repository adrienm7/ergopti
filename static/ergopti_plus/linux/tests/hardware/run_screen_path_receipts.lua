--- tests/hardware/run_screen_path_receipts.lua
--- ==============================================================================
--- MODULE: Virtual X11 Screenshot Path Receipts
--- DESCRIPTION:
--- Captures the fixture's actual Xvfb display through production ScreenCapture
--- and installed maim. Native mktemp paths, PNG bytes and directory permissions
--- prove staging stays inside the exact private directory, including CR/LF.
--- This is a virtual graphical session, not physical screen or Wayland proof.
--- Run with lua-luv and maim installed, under xvfb-run -a.
--- ==============================================================================

local uv = require("luv")
local Screen = require("adapters.screen_capture")
assert(uv.getuid() ~= 0, "permission receipts require an ordinary user")
assert(os.getenv("DISPLAY"), "an owned virtual X11 display is required")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-screen-path-XXXXXX"))
local previous_runtime, previous_tmp = os.getenv("XDG_RUNTIME_DIR"), os.getenv("TMPDIR")
local checks, failures = 0, 0
local active

local function directory(name)
	local path = root .. "/" .. name
	assert(uv.fs_mkdir(path, 448))
	return path
end

local function set_environment(runtime, temporary)
	if runtime then assert(uv.os_setenv("XDG_RUNTIME_DIR", runtime)) else assert(uv.os_unsetenv("XDG_RUNTIME_DIR")) end
	if temporary then assert(uv.os_setenv("TMPDIR", temporary)) else assert(uv.os_unsetenv("TMPDIR")) end
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if active then active.cancel(); active = nil end
	uv.run()
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local function uint32(bytes, start)
	local a, b, c, d = bytes:byte(start, start + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end

local function capture(base)
	local callbacks, outcome = 0, nil
	local reason
	active, reason = Screen.capture("full", 128, function(result)
		callbacks, outcome = callbacks + 1, result
	end)
	assert(active, reason)
	uv.run()
	assert(callbacks == 1 and outcome.status == "ok", "actual screenshot did not succeed exactly once")
	assert(active.dir:sub(1, #base + 1) == base .. "/", "mktemp path was truncated outside its literal parent")
	assert(active.path == active.dir .. "/screen.png", "capture and cleanup disagree on the private image path")
	local attributes = assert(uv.fs_stat(active.dir))
	assert(attributes.type == "directory" and attributes.mode % 512 == 448, "capture directory is not mode 0700")
	local file = assert(io.open(active.path, "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	assert(bytes:sub(1, 8) == "\137PNG\r\n\26\n" and bytes:sub(13, 16) == "IHDR", "tool did not create a real PNG")
	local width, height = uint32(bytes, 17), uint32(bytes, 21)
	assert(width > 0 and height > 0)
	if outcome.scaled then assert(math.max(width, height) <= 128, "installed downscale did not constrain the actual PNG") end
	assert(not uv.loop_alive(), "capture retained native process ownership")
	assert(uv.fs_unlink(active.path))
	assert(uv.fs_rmdir(active.dir))
	active = nil
end

for _, name in ipairs({ "ordinary", "line\npart", "carriage\rpart", "quote-é'漢\npart", "tail\n" }) do
	check("literal runtime parent " .. string.format("%q", name), function()
		local base = directory(name)
		local prefix = name:match("^([^\r\n]+)")
		if prefix ~= name then directory(prefix) end -- Existing alias exposes the old wrong-directory success.
		set_environment(base, root)
		capture(base)
	end)
end

check("TMPDIR fallback preserves an embedded newline", function()
	local base = directory("fallback\npart")
	directory("fallback")
	set_environment(nil, base)
	capture(base)
end)

check("runtime directory takes precedence over a refused TMPDIR", function()
	local base = directory("precedence")
	set_environment(base, root .. "/absent-temporary")
	capture(base)
end)

check("absent runtime parent refuses without spawning a capture", function()
	set_environment(root .. "/absent-runtime", root)
	local callbacks = 0
	local handle, reason = Screen.capture("full", 128, function() callbacks = callbacks + 1 end)
	active = handle
	assert(handle == nil and type(reason) == "string", "failed mktemp was admitted")
	assert(callbacks == 0 and not uv.loop_alive(), "refused staging dispatched native capture work")
end)

check("unwritable runtime parent refuses without another directory fallback", function()
	local base = directory("unwritable")
	assert(uv.fs_chmod(base, 0))
	set_environment(base, root)
	local callbacks = 0
	local handle, reason = Screen.capture("full", 128, function() callbacks = callbacks + 1 end)
	active = handle
	assert(uv.fs_chmod(base, 448))
	assert(handle == nil and type(reason) == "string", "native EACCES was admitted")
	assert(callbacks == 0 and not uv.loop_alive())
end)

local function remove_owned_tree(path)
	local attributes = assert(uv.fs_lstat(path))
	if attributes.type ~= "directory" then assert(uv.fs_unlink(path)); return end
	assert(uv.fs_chmod(path, 448))
	for name in uv.fs_scandir_next, assert(uv.fs_scandir(path)) do remove_owned_tree(path .. "/" .. name) end
	assert(uv.fs_rmdir(path))
end

remove_owned_tree(root)
set_environment(previous_runtime, previous_tmp)
assert(not uv.loop_alive(), "fixture leaked native ownership")
print(string.format("Virtual X11 screen path receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
