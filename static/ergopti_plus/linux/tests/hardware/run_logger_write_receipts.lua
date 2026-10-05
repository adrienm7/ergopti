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
local restricted_directories = {}

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

local function write(path, content)
	local file = assert(io.open(path, "w"))
	assert(file:write(content))
	assert(file:close())
end

local function paths(path)
	local dirs = require("app_dirs")
	local date = os.date("%Y-%m-%d")
	return path .. "/" .. dirs.files.unified_prefix .. date .. dirs.files.extension,
		path .. "/" .. dirs.files.errors_prefix .. date .. dirs.files.extension
end

local function descriptors(path)
	local count = 0
	for name in uv.fs_scandir_next, assert(uv.fs_scandir("/proc/self/fd")) do
		if uv.fs_readlink("/proc/self/fd/" .. name) == path then count = count + 1 end
	end
	return count
end

local function configured_directory(name)
	local state = directory(name)
	directory(name .. "/ergopti_plus")
	local dir = directory(name .. "/ergopti_plus/logs")
	assert(uv.os_setenv("XDG_STATE_HOME", state))
	assert(require("infra.config_paths").get_logs_dir() == dir)
	return dir
end

local function restrict_channels(dir)
	assert(uv.getuid() ~= 0, "native permission receipts require a non-root process")
	local main, errors = paths(dir)
	assert(uv.fs_chmod(main, 256)) -- owner read, no write; acquired FDs stay writable
	assert(uv.fs_chmod(errors, 256))
	return main, errors
end

local function refuse_directory(dir)
	assert(uv.fs_chmod(dir, 320)) -- owner read/execute, no write
	restricted_directories[#restricted_directories + 1] = dir
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	Sink.uninstall(Logger)
	for _, dir in ipairs(restricted_directories) do assert(uv.fs_chmod(dir, 448)) end
	restricted_directories = {}
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

check("refused repoint keeps acquired handles after their paths become read-only", function()
	local old = directory("repoint-refused-old")
	assert(Sink.install(Logger, { log_dir = old }))
	local main, errors = restrict_channels(old)
	Logger.warn("native-repoint-before", "Acquired old channels still append after chmod.")
	assert(read(main):find("still append after chmod", 1, true))
	assert(read(errors):find("still append after chmod", 1, true))
	local target = configured_directory("repoint-refused-state")
	refuse_directory(target)
	local moved, reason = Sink.repoint()
	assert(moved == false and type(reason) == "string")
	assert(Sink.log_dir() == old and Sink.is_file_sink_active(), "refusal discarded the durable old owner")
	assert(descriptors(main) == 1 and descriptors(errors) == 1, "refusal closed an acquired old descriptor")
	Logger.warn("native-repoint-after", "Refused destination preserves both old channels.")
	assert(read(main):find("preserves both old channels", 1, true))
	assert(read(errors):find("preserves both old channels", 1, true))
end)

check("repeated refused repoints keep the same acquired native pair", function()
	local old = directory("repoint-repeated-old")
	assert(Sink.install(Logger, { log_dir = old }))
	local main, errors = restrict_channels(old)
	refuse_directory(configured_directory("repoint-repeated-state"))
	for attempt = 1, 2 do
		assert(Sink.repoint() == false)
		assert(descriptors(main) == 1 and descriptors(errors) == 1, "retry replaced the healthy old pair")
		Logger.warn("native-repoint-retry", "Old native owner remains writable after refusal " .. attempt)
		assert(read(main):find("after refusal " .. attempt, 1, true))
		assert(read(errors):find("after refusal " .. attempt, 1, true))
	end
end)

check("partial candidate is closed without retiring the old native owner", function()
	local old = directory("repoint-partial-old")
	assert(Sink.install(Logger, { log_dir = old }))
	local main, errors = restrict_channels(old)
	local target = configured_directory("repoint-partial-state")
	local candidate_main, candidate_errors = paths(target)
	write(candidate_main, "Existing refused main bytes.\n")
	assert(uv.fs_chmod(candidate_main, 256))
	assert(not uv.fs_stat(candidate_errors))
	assert(Sink.repoint() == false)
	assert(uv.fs_stat(candidate_errors).size == 0, "partial mirror was not genuinely acquired")
	assert(descriptors(candidate_errors) == 0, "partial candidate retained its append descriptor")
	assert(read(candidate_main) == "Existing refused main bytes.\n")
	assert(Sink.is_file_sink_active() and descriptors(main) == 1 and descriptors(errors) == 1,
		"partial acquisition retired the healthy old owner")
end)

check("successful repoint switches both native channels and retires the old pair", function()
	local old = directory("repoint-success-old")
	assert(Sink.install(Logger, { log_dir = old }))
	local main, errors = restrict_channels(old)
	local target = configured_directory("repoint-success-state")
	assert(Sink.repoint())
	assert(Sink.log_dir() == target and Sink.is_file_sink_active())
	assert(descriptors(main) == 0 and descriptors(errors) == 0, "successful switch retained the old pair")
	Logger.warn("native-repoint-success", "Both candidate native channels own the new line.")
	local new_main, new_errors = paths(target)
	assert(read(new_main):find("own the new line", 1, true))
	assert(read(new_errors):find("own the new line", 1, true))
	assert(not read(main):find("own the new line", 1, true))
	assert(not read(errors):find("own the new line", 1, true))
end)

check("refused optional mirror keeps successful native main repoint usable", function()
	local old = directory("repoint-mirror-old")
	assert(Sink.install(Logger, { log_dir = old }))
	local main, errors = restrict_channels(old)
	local target = configured_directory("repoint-mirror-state")
	local new_main, new_errors = paths(target)
	write(new_errors, "Existing refused mirror bytes.\n")
	assert(uv.fs_chmod(new_errors, 256))
	assert(Sink.repoint() and Sink.is_file_sink_active())
	assert(descriptors(main) == 0 and descriptors(errors) == 0)
	Logger.warn("native-repoint-mirror", "The accepted native main channel remains durable.")
	assert(read(new_main):find("remains durable", 1, true))
	assert(read(new_errors) == "Existing refused mirror bytes.\n")
	assert(descriptors(new_errors) == 0, "refused mirror acquired a native descriptor")
end)

for _, operation in ipairs({ "install", "prepare", "repoint" }) do
	check(operation .. " preserves a pre-existing native probe file", function()
		local dir
		if operation == "repoint" then
			assert(Sink.install(Logger, { log_dir = directory("probe-original") }))
			local state = directory("probe-state")
			assert(uv.os_setenv("XDG_STATE_HOME", state))
			directory("probe-state/ergopti_plus")
			dir = directory("probe-state/ergopti_plus/logs")
		else dir = directory("probe-" .. operation) end
		local path, content = dir .. "/.write_probe", "Pre-existing user-owned bytes.\n"
		write(path, content)
		if operation == "install" then assert(Sink.install(Logger, { log_dir = dir }))
		elseif operation == "prepare" then assert(Sink.prepare_dir(dir))
		else assert(Sink.repoint()) end
		assert(read(path) == content, "logger removed or changed the pre-existing file")
	end)
end

check("prepare leaves an existing native probe symlink and its target intact", function()
	local dir = directory("probe-symlink")
	local target = dir .. "/target"
	write(target, "Unrelated target bytes.\n")
	assert(uv.fs_symlink(target, dir .. "/.write_probe"))
	assert(Sink.prepare_dir(dir))
	assert(uv.fs_readlink(dir .. "/.write_probe") == target, "logger removed the unrelated symlink")
	assert(read(target) == "Unrelated target bytes.\n")
end)

check("prepare never follows a dangling native probe symlink", function()
	local dir = directory("probe-dangling")
	local target = dir .. "/missing-target"
	assert(uv.fs_symlink(target, dir .. "/.write_probe"))
	assert(Sink.prepare_dir(dir))
	assert(not uv.fs_lstat(target), "logger created an unrelated symlink target")
	assert(uv.fs_readlink(dir .. "/.write_probe") == target, "logger removed the dangling symlink")
end)

check("prepare refuses a genuinely read-only native directory", function()
	local dir = directory("probe-read-only")
	assert(uv.fs_chmod(dir, 320)) -- owner read/execute, no write
	local ok, err = pcall(function()
		local ready, reason = Sink.prepare_dir(dir)
		assert(ready == false and type(reason) == "string", "read-only directory was admitted")
	end)
	assert(uv.fs_chmod(dir, 448))
	assert(ok, err)
end)

check("prepare preserves literal quotes and line breaks and retires its private probe", function()
	local dir = directory("probe-'quoted\r\npath")
	assert(Sink.prepare_dir(dir))
	assert(uv.fs_scandir_next(assert(uv.fs_scandir(dir))) == nil, "successful preparation left a probe behind")
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
