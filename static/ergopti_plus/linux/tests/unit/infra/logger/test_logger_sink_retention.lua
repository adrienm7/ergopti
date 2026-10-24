--- tests/unit/infra/logger/test_logger_sink_retention.lua

--- ==============================================================================
--- MODULE: Log Retention Purge Without find
--- DESCRIPTION:
--- The logger sink deletes rolled log files past the retention window at
--- install and at every date rollover, in this process.
---
--- ROOT CAUSE ENCODED:
--- The purge forked `find <dir> -maxdepth 1 -type f -name '<prefix>*.log'
--- -mtime +N -delete` once per prefix: two forks at every daemon start (measured
--- with `ergopti_hotstrings.lua --help`, before any boot stage) and two more on
--- the logging path itself at each midnight rollover. The in-process sweep must
--- delete exactly what find deleted and nothing else: only regular files directly
--- in the folder, never a link or a folder, named by either glob, older than
--- N + 1 whole days.
---
--- FEATURES & RATIONALE:
--- 1. Differential: the expected deletions are what GNU find selects with the
---    same expressions over the same folder, before the sink runs.
--- 2. No fork: a rollover purge spawns nothing, and an install forks only its
---    folder creation.
--- 3. Never fatal: a folder the kernel refuses to list is reported on stderr and
---    the sink keeps logging.
--- ==============================================================================

local helpers = require("tests.helpers")
local Shell = require("adapters.shell_runner")

local ON_WINDOWS = package.config:sub(1, 1) == "\\"
local DAY = 86400

--- A logger double exposing only the core's sink contract.
--- @return table logger
local function fake_logger()
	local logger = {}
	function logger.set_sink(callback) logger.emit = callback end
	function logger.enable_repeat_collapsing() end
	function logger.disable_repeat_collapsing() end
	return logger
end

--- The privacy identity the sink admits before any output.
local IDENTITY = { home = "/home/fixture-user", user = "fixture-user" }

--- Creates an empty file and sets its modification time (and the link's own
--- time for a symbolic link).
--- @param path string
--- @param age number Seconds before now.
local function aged(path, age)
	local stamp = "@" .. tostring(os.time() - age)
	assert(Shell.run("touch -h -d " .. Shell.quote(stamp) .. " " .. Shell.quote(path)))
end

--- Builds a log folder whose entries straddle the retention window.
--- @param days number Retention days.
--- @return string dir
local function fixture(days)
	local dir = os.tmpname()
	os.remove(dir)
	assert(Shell.run("mkdir -p " .. Shell.quote(dir .. "/ErgoptiPlus_folder.log")))
	local old, recent = (days + 1) * DAY + 3600, (days + 1) * DAY - 3600
	local files = {
		["ErgoptiPlus_2026-01-01.log"] = old, ["ErgoptiPlus_errors_2026-01-01.log"] = old,
		["ErgoptiPlus_hotstrings.log"] = old, ["ErgoptiPlus_.log"] = old, ["ErgoptiPlus_2026-01-02.log"] = recent,
		["ErgoptiPlus_errors_2026-01-02.log"] = recent, ["ErgoptiPlus_2026-01-01.log.bak"] = old,
		["other_2026-01-01.log"] = old, [".ErgoptiPlus_hidden.log"] = old, ["ErgoptiPlus_line\nbreak.log"] = old,
		["ErgoptiPlus_ancient.log"] = 400 * DAY,
	}
	for name, age in pairs(files) do
		local file = assert(io.open(dir .. "/" .. name, "w")); assert(file:close())
		aged(dir .. "/" .. name, age)
	end
	local target = dir .. "/ErgoptiPlus_2026-01-01.log"
	assert(Shell.run("ln -s " .. Shell.quote(target) .. " " .. Shell.quote(dir .. "/ErgoptiPlus_link.log")))
	aged(dir .. "/ErgoptiPlus_link.log", old)
	aged(dir .. "/ErgoptiPlus_folder.log", old)
	return dir
end

--- Every name in a folder, sorted.
--- @param dir string
--- @return table names
local function names(dir)
	local list = {}
	for _, entry in ipairs(assert(require("infra.native_directory").entries(dir))) do list[#list + 1] = entry.name end
	table.sort(list)
	return list
end

--- The files GNU find deletes with the sink's former command lines.
--- @param dir string
--- @param days number
--- @return table set
local function find_selection(dir, days)
	local selected = {}
	for _, prefix in ipairs({ "ErgoptiPlus_", "ErgoptiPlus_errors_" }) do
		local pipe = assert(io.popen(string.format("find %s -maxdepth 1 -type f -name %s -mtime +%d -print0",
			Shell.quote(dir), Shell.quote(prefix .. "*.log"), days)))
		for path in pipe:read("*a"):gmatch("([^%z]+)%z") do selected[path:sub(#dir + 2)] = true end
		pipe:close()
	end
	return selected
end

--- Counts io.popen and os.execute calls and their commands while body runs.
--- @param body function
--- @return table commands
local function forks_during(body)
	local commands = {}
	local popen, execute = io.popen, os.execute
	io.popen = function(command, ...) commands[#commands + 1] = command; return popen(command, ...) end
	os.execute = function(command, ...) commands[#commands + 1] = command; return execute(command, ...) end
	local ok, err = pcall(body)
	io.popen, os.execute = popen, execute
	if not ok then error(err, 0) end
	return commands
end




-- ==========================================
-- ==========================================
-- ======= 1/ Same deletions as find ========
-- ==========================================
-- ==========================================

helpers.describe("log retention purge deletes what find deleted", function()
	helpers.it("removes only the aged regular files named by either glob, at install, without find", function()
		if ON_WINDOWS then print("  SKIP native POSIX purge: Windows has no GNU find or symbolic links here"); return end
		local days = require("infra.timings").count("logger", "retention_days")
		local dir = fixture(days)
		local Sink = helpers.load_module("infra.logger_sink")
		local logger = fake_logger()
		local ok, err = pcall(function()
			local before = names(dir)
			local expected_deleted = find_selection(dir, days)
			helpers.assert_true(expected_deleted["ErgoptiPlus_ancient.log"] and expected_deleted["ErgoptiPlus_line\nbreak.log"]
				and not expected_deleted["ErgoptiPlus_link.log"], "the fixture straddles find's selection")
			local commands = forks_during(function()
				helpers.assert_eq(Sink.install(logger, { log_dir = dir, redaction_context = IDENTITY }), true)
			end)
			for _, command in ipairs(commands) do
				helpers.assert_true(command:match("^mkdir %-p ") ~= nil, "install forks only its folder creation: " .. command)
			end
			local expected = {}
			for _, name in ipairs(before) do if not expected_deleted[name] then expected[#expected + 1] = name end end
			-- Today's pair, opened by the install, was never a candidate.
			local today = os.date("%Y-%m-%d")
			for _, name in ipairs({ "ErgoptiPlus_" .. today .. ".log", "ErgoptiPlus_errors_" .. today .. ".log" }) do
				local listed = false
				for _, kept in ipairs(expected) do listed = listed or kept == name end
				if not listed then expected[#expected + 1] = name end
			end
			table.sort(expected)
			helpers.assert_eq(names(dir), expected)
		end)
		Sink.uninstall(logger)
		assert(Shell.run("rm -rf -- " .. Shell.quote(dir)))
		if not ok then error(err, 0) end
	end)

	helpers.it("purges at a date rollover with zero io.popen or os.execute", function()
		if ON_WINDOWS then print("  SKIP native POSIX purge: Windows has no GNU find or symbolic links here"); return end
		local days = require("infra.timings").count("logger", "retention_days")
		local dir = os.tmpname()
		os.remove(dir)
		assert(Shell.run("mkdir -p " .. Shell.quote(dir)))
		local Sink = helpers.load_module("infra.logger_sink")
		local logger = fake_logger()
		local stdout, date = io.stdout, os.date
		local ok, err = pcall(function()
			helpers.assert_eq(Sink.install(logger, { log_dir = dir, redaction_context = IDENTITY }), true)
			local stale = dir .. "/ErgoptiPlus_2026-01-01.log"
			local file = assert(io.open(stale, "w")); assert(file:close())
			aged(stale, (days + 2) * DAY)
			io.stdout = { write = function() return true end, flush = function() return true end }
			-- The next line belongs to another day: the sink rolls over and purges.
			os.date = function(format, ...)
				if format == "%Y-%m-%d" then return "2099-01-01" end
				return date(format, ...)
			end
			local commands = forks_during(function() logger.emit("2099-01-01 00:00:00:000 [INFO] [probe] rollover", "info") end)
			os.date, io.stdout = date, stdout
			helpers.assert_eq(commands, {}, "the rollover purge forks nothing")
			helpers.assert_nil(io.open(stale, "r"), "the aged file was purged at the rollover")
		end)
		os.date, io.stdout = date, stdout
		Sink.uninstall(logger)
		assert(Shell.run("rm -rf -- " .. Shell.quote(dir)))
		if not ok then error(err, 0) end
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 2/ Never fatal ===================
-- ==========================================
-- ==========================================

helpers.describe("log retention purge reports a refused folder and keeps logging", function()
	helpers.it("writes one redacted stderr line when the folder cannot be listed", function()
		local dir = os.tmpname()
		os.remove(dir)
		assert(Shell.run("mkdir -p " .. Shell.quote(dir)))
		local uv = require("luv")
		local refusing = setmetatable({
			fs_opendir = function() return nil, "EIO: i/o error", "EIO" end,
		}, { __index = uv })
		local previous = package.loaded["infra.native_directory"]
		local Walker = helpers.load_module_with_dependency("infra.native_directory", "luv", refusing)
		package.loaded["infra.native_directory"] = Walker
		local Sink = helpers.load_module("infra.logger_sink")
		package.loaded["infra.native_directory"] = previous
		local logger = fake_logger()
		local stderr = io.stderr
		local reported = {}
		io.stderr = { write = function(_, text) reported[#reported + 1] = text; return true end }
		local ok, err = pcall(function()
			helpers.assert_eq(Sink.install(logger, { log_dir = dir, redaction_context = IDENTITY }), true,
				"a refused purge never degrades the file sink")
		end)
		io.stderr = stderr
		Sink.uninstall(logger)
		helpers.load_module("infra.logger_sink")
		assert(Shell.run("rm -rf -- " .. Shell.quote(dir)))
		if not ok then error(err, 0) end
		helpers.assert_eq(#reported, 1)
		helpers.assert_true(reported[1]:find("retention purge could not list", 1, true) ~= nil
			and reported[1]:find("EIO", 1, true) ~= nil, reported[1])
	end)
end)
