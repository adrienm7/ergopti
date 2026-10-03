--- tests/hardware/run_logger_write_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Logger Write Receipts
--- DESCRIPTION:
--- Routes the real shared logger through Linux's production file sink and
--- actual /dev/full failures. Failed channels must release their descriptor,
--- report lost durability and leave the other channel available. Private
--- directories and symlinks belong exclusively to this fixture.
--- No file, logger or syscall API is mocked.
--- ==============================================================================

local uv = require("luv")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-logger-receipts-XXXXXX"))
local previous_config, previous_state = os.getenv("XDG_CONFIG_HOME"), os.getenv("XDG_STATE_HOME")
assert(uv.os_setenv("XDG_CONFIG_HOME", root .. "/config"))
assert(uv.os_setenv("XDG_STATE_HOME", root .. "/state"))
local Logger = require("logger.shim")
local Sink = require("infra.logger_sink")
local checks, failures = 0, 0
local directories = {}

local function full_descriptors()
	local count = 0
	for name in uv.fs_scandir_next, assert(uv.fs_scandir("/proc/self/fd")) do
		if uv.fs_readlink("/proc/self/fd/" .. name) == "/dev/full" then count = count + 1 end
	end
	return count
end

local baseline_full_descriptors = full_descriptors()

local function directory(name)
	local path = root .. "/" .. name
	assert(uv.fs_mkdir(path, 448))
	directories[#directories + 1] = path
	return path
end

local function read(path)
	local file = assert(io.open(path, "r"))
	local content = assert(file:read("*a"))
	assert(file:close())
	return content
end

local function paths(path)
	local dirs = require("app_dirs")
	local date = os.date("%Y-%m-%d")
	return path .. "/" .. dirs.files.unified_prefix .. date .. dirs.files.extension,
		path .. "/" .. dirs.files.errors_prefix .. date .. dirs.files.extension
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	Sink.uninstall(Logger)
	assert(full_descriptors() == baseline_full_descriptors, "fixture retained a failed descriptor")
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, size in ipairs({ 32, 65536 }) do
	check("main ENOSPC retires the descriptor for " .. size .. " bytes", function()
		local dir = directory("main-" .. size)
		local main, errors = paths(dir)
		assert(uv.fs_symlink("/dev/full", main))
		assert(Sink.install(Logger, { log_dir = dir }))
		assert(full_descriptors() == baseline_full_descriptors + 1)
		Logger.info("native-log-main-" .. size, string.rep("x", size))
		assert(not Sink.is_file_sink_active(), "failed flush/write still reports a durable main sink")
		assert(not Sink.install(Logger, { log_dir = dir }), "idempotent install concealed lost durability")
		assert(full_descriptors() == baseline_full_descriptors, "failed main descriptor remained open")
		Logger.warn("native-log-mirror-" .. size, "Surviving error channel receipt.")
		assert(read(errors):find("Surviving error channel receipt.", 1, true), "main failure disabled the healthy mirror")
	end)
	check("mirror ENOSPC preserves main durability for " .. size .. " bytes", function()
		local dir = directory("mirror-" .. size)
		local main, errors = paths(dir)
		assert(uv.fs_symlink("/dev/full", errors))
		assert(Sink.install(Logger, { log_dir = dir }))
		Logger.warn("native-log-error-" .. size, string.rep("y", size))
		assert(Sink.is_file_sink_active(), "mirror failure disabled the healthy main channel")
		assert(full_descriptors() == baseline_full_descriptors, "failed mirror descriptor remained open")
		Logger.info("native-log-survivor-" .. size, "Surviving main channel receipt.")
		assert(read(main):find("Surviving main channel receipt.", 1, true))
	end)
end

check("repoint repairs a retired main channel in the same directory", function()
	local state = directory("repaired")
	assert(uv.os_setenv("XDG_STATE_HOME", state))
	directory("repaired/ergopti_plus")
	local dir = directory("repaired/ergopti_plus/logs")
	assert(require("infra.config_paths").get_logs_dir() == dir, "repair must use the actual configured target")
	local main = paths(dir)
	assert(uv.fs_symlink("/dev/full", main))
	assert(Sink.install(Logger, { log_dir = dir }))
	Logger.info("native-log-refusal", "Force a buffered native ENOSPC before repair.")
	assert(uv.fs_unlink(main))
	assert(Sink.repoint(), "same-directory repair was refused")
	Logger.info("native-log-repaired", "Durable main channel restored.")
	assert(Sink.is_file_sink_active())
	assert(read(main):find("Durable main channel restored.", 1, true), "same-directory repoint kept the failed descriptor")
end)

check("ordinary native channels retain complete independent lines", function()
	local dir = directory("ordinary")
	assert(Sink.install(Logger, { log_dir = dir }))
	Logger.info("native-log-control", "Normal main channel receipt.")
	Logger.warn("native-log-control", "Normal mirrored channel receipt.")
	local main, errors = paths(dir)
	assert(read(main):find("Normal main channel receipt.", 1, true))
	assert(read(main):find("Normal mirrored channel receipt.", 1, true))
	assert(not read(errors):find("Normal main channel receipt.", 1, true))
	assert(read(errors):find("Normal mirrored channel receipt.", 1, true))
	assert(Sink.is_file_sink_active())
end)

for index = #directories, 1, -1 do
	local dir = directories[index]
	for name in uv.fs_scandir_next, assert(uv.fs_scandir(dir)) do assert(uv.fs_unlink(dir .. "/" .. name)) end
	assert(uv.fs_rmdir(dir))
end
assert(uv.fs_rmdir(root))
if previous_config then uv.os_setenv("XDG_CONFIG_HOME", previous_config) else uv.os_unsetenv("XDG_CONFIG_HOME") end
if previous_state then uv.os_setenv("XDG_STATE_HOME", previous_state) else uv.os_unsetenv("XDG_STATE_HOME") end
print(string.format("Native logger write receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
