--- tests/unit/infra/test_runtime_diagnostics.lua

--- ==============================================================================
--- TEST: Boot stages, runtime diagnostics and log privacy (Linux)
--- DESCRIPTION:
--- 1. Boot stages pair START with SUCCESS and name any stage left open, which
---    is the signal that tells a silent boot death from a finished boot.
--- 2. Previously silent failures (signal handlers, the WPM restore, the update
---    notifier) now log, and process exits are reported without their command.
--- 3. Privacy: a hotstring driven through the real shared engine at DEBUG level
---    leaves neither its trigger nor its replacement in the log, and the daemon's
---    match line prints lengths only.
--- ==============================================================================

local helpers = require("tests.helpers")

local describe    = helpers.describe
local it          = helpers.it
local assert_eq   = helpers.assert_eq
local assert_true = helpers.assert_true

local Logger     = require("logger")
local RuntimeLog = require("diagnostics.runtime_log")

--- Runs body with the real shared logger at DEBUG and a capturing sink.
--- @param body function
--- @return table Captured lines.
local function capture_lines(body)
	local lines = {}
	local previous_level = Logger.get_level()
	Logger.set_level(10)
	Logger.reset_dedup()
	Logger.set_sink(function(line) lines[#lines + 1] = line end)
	local ok, err = pcall(body)
	Logger.set_sink(nil)
	Logger.set_level(previous_level)
	if not ok then error(err, 0) end
	return lines
end

--- Reads the daemon entry point.
--- @return string
local function daemon_source()
	local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
	local src = fh:read("*a")
	fh:close()
	return src
end




-- ====================================
-- ====================================
-- ======= 1/ Boot stages =============
-- ====================================
-- ====================================

describe("Boot profiler: paired stages", function()
	local BootProfiler = require("infra.boot_profiler")

	it("pairs every stage with a timed SUCCESS and reports the total", function()
		BootProfiler._reset_for_test()
		local lines = capture_lines(function()
			BootProfiler.begin()
			BootProfiler.stage("config")
			BootProfiler.stage_done("config", "3 mapping(s)")
			BootProfiler.complete()
		end)
		local text = table.concat(lines, "\n")
		assert_true(text:find("[START] [BootProfile] Boot stage 'config'…", 1, true) ~= nil, text)
		assert_true(text:find("[SUCCESS] [BootProfile] Boot stage 'config' done in", 1, true) ~= nil, text)
		assert_true(text:find(": 3 mapping(s) (total", 1, true) ~= nil, text)
		assert_true(text:find("Boot complete in", 1, true) ~= nil, text)
		assert_true(type(BootProfiler.boot_ms()) == "number", "the total is frozen")
	end)

	it("names a stage that never closed", function()
		BootProfiler._reset_for_test()
		local lines = capture_lines(function()
			BootProfiler.begin()
			BootProfiler.stage("input hooks")
			BootProfiler.complete()
		end)
		local text = table.concat(lines, "\n")
		assert_true(text:find("unclosed stage(s): input hooks", 1, true) ~= nil, text)
	end)

	it("refuses a second boot owner", function()
		BootProfiler._reset_for_test()
		capture_lines(function() BootProfiler.begin() end)
		local ok = pcall(BootProfiler.begin)
		assert_eq(false, ok, "begin() twice must raise")
		BootProfiler._reset_for_test()
	end)
end)




-- ====================================
-- ====================================
-- ======= 2/ Runtime events ==========
-- ====================================
-- ====================================

describe("Runtime log: external processes and reloads", function()
	it("logs a process exit by program name only, never its arguments", function()
		local name = RuntimeLog.program_name("LANG=C xclip -selection clipboard -o <<'EOF'\nsecret\nEOF")
		assert_eq("xclip", name)
		assert_eq("notify-send", RuntimeLog.program_name("'/usr/bin/notify-send' 'Title' 'Body'"))
	end)

	it("throttles repeats per program and always reports a slow run", function()
		local now = 0
		local lines = {}
		local fake = { debug = function(_, fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end }
		local record = RuntimeLog.new_process_log(fake, "test", function() return now end)
		assert_true(record("pgrep", 1, 3), "the first run is logged")
		now = 100
		assert_eq(false, record("pgrep", 1, 3), "a quick repeat inside the window is folded")
		assert_true(record("pgrep", 0, 1500), "a slow run is always logged")
		now = 100 + RuntimeLog.PROCESS_LOG_WINDOW_MS
		assert_true(record("pgrep", 0, 2), "the window reopens")
		assert_eq(3, #lines)
		assert_true(lines[1]:find("Process 'pgrep' exited (status=1, 3 ms", 1, true) ~= nil, lines[1])
		assert_true(lines[2]:find("1 similar run(s)", 1, true) ~= nil, lines[2])
	end)

	it("names the files behind a reload by base name", function()
		assert_eq("2 file(s): a.toml, b.toml",
			RuntimeLog.describe_paths({ ["/home/u/.config/ergopti/b.toml"] = true, ["/x/a.toml"] = true }))
		assert_eq("no file recorded", RuntimeLog.describe_paths({}))
	end)
end)

describe("Runtime log: previously swallowed failures now log", function()
	local src = daemon_source()

	it("reports a signal handler that could not be installed", function()
		assert_true(src:find("Signal handler for %s could not be installed", 1, true) ~= nil,
			"install failures must be logged, not discarded by a bare pcall")
		assert_eq(nil, src:find("pcall(signal.signal, signal.SIGINT", 1, true),
			"the bare pcall that discarded the result is gone")
	end)

	it("reports a WPM restore failure", function()
		assert_true(src:find("WPM widget state could not be restored", 1, true) ~= nil)
		assert_eq(nil, src:find("\tpcall(wpm_widget.restore)", 1, true))
	end)

	it("reports an update notifier that raised", function()
		local fh = assert(io.open(helpers.driver_root() .. "/modules/updater/manager.lua", "r"))
		local updater = fh:read("*a")
		fh:close()
		assert_true(updater:find("Update-available handler raised", 1, true) ~= nil)
		assert_eq(nil, updater:find("\t\t\t\t\tpcall(on_available, release)\n", 1, true))
	end)
end)




-- ====================================
-- ====================================
-- ======= 3/ Privacy =================
-- ====================================
-- ====================================

describe("Log privacy: a fired hotstring leaves no typed text in the log", function()
	-- Distinctive enough that no other line can contain them by accident.
	local TRIGGER = "qzxtrig"
	local REPLACEMENT = "zqx private replacement text"

	it("the shared engine logs no trigger, replacement or typed character", function()
		local saved_shim = package.loaded["logger.shim"]
		local saved_engine = package.loaded["hotstring_engine"]
		-- The engine captures its logger at require time, so it is reloaded
		-- against the real logger rather than whatever stub a previous test left.
		package.loaded["logger.shim"] = Logger
		package.loaded["hotstring_engine"] = nil
		local fired = nil
		local ok, err = pcall(function()
			local lines = capture_lines(function()
				local engine = require("hotstring_engine").new()
				engine:load_mappings({ { trigger = TRIGGER, replacement = REPLACEMENT, auto_expand = true } })
				for index = 1, #TRIGGER do
					fired = engine:on_char(TRIGGER:sub(index, index)) or fired
				end
			end)
			assert_true(fired ~= nil, "the hotstring must fire, or the absence below proves nothing")
			assert_true(#lines > 0, "the engine must have logged at DEBUG, or this test is vacuous")
			local text = table.concat(lines, "\n")
			assert_eq(nil, text:find(TRIGGER, 1, true), "the trigger leaked: " .. text)
			assert_eq(nil, text:find("zqx private", 1, true), "the replacement leaked: " .. text)
			assert_eq(nil, text:find("on_char('", 1, true), "a typed character leaked: " .. text)
		end)
		package.loaded["logger.shim"] = saved_shim
		package.loaded["hotstring_engine"] = saved_engine
		if not ok then error(err, 0) end
	end)

	it("the daemon's match, undo, replay and preview lines carry no typed text", function()
		local src = daemon_source()
		assert_eq(nil, src:find("Match: trigger='%s'", 1, true), "the match line printed trigger and replacement")
		assert_eq(nil, src:find("restoring trigger '%s'", 1, true), "the undo line printed the trigger")
		assert_eq(nil, src:find("queued char '%s'", 1, true), "the replay error printed the character")
		assert_eq(nil, src:find("Preview failed for '%s'", 1, true), "the preview error printed the character")
		assert_true(src:find("Match fired (%s, trigger %d char(s)", 1, true) ~= nil,
			"the match is still logged, by length")
	end)

	it("the diagnostic snapshot redacts the home directory", function()
		local Snapshot = require("diagnostics.snapshot")
		local line = Snapshot.format({ config_dir = Snapshot.redact_home("/home/alice/.config/ergopti", "/home/alice") })
		assert_eq(nil, line:find("alice", 1, true), line)
	end)
end)
