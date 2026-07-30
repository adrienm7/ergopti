--- tests/unit/meta/test_logger_sink.lua

--- ==============================================================================
--- MODULE: Logger Sink Regression Test (Linux driver)
--- DESCRIPTION:
--- Regression guard for the blocker where the Linux daemon wrote NO log anywhere.
--- `require("logger.shim")` resolves to the shared core (because _shared/lua is on
--- package.path), the core only emits through a sink injected via
--- `M.set_sink()`, and nothing ever called it. Every Logger.* call — including
--- `Logger.error("No keyboard device found")` and
--- `Logger.error("Keyboard hook failed to start — exiting.")` — landed in a
--- 200-entry ring buffer and was discarded. Meanwhile the tray offered
--- "open logs" on a directory nothing wrote to.
---
--- FEATURES & RATIONALE:
--- 1. Root cause, not symptom: the first test asserts a sink is installed on the
---    production boot path, so deleting the wiring fails here even if the sink
---    module still exists.
--- 2. Proves output, not intent: the second test emits through the REAL shared
---    core and reads the line back off disk. A test that only checked which module
---    name was required is what let the bug survive — it was a true statement
---    about a logger that logged nowhere.
--- 3. Both handles roll over: repointing only the main file leaves WARNING and
---    ERROR appended to yesterday's errors file forever, a bug the macOS driver
---    already shipped once.
--- 4. One quoting rule: the sink cannot require adapters/shell_runner (that module
---    requires the logger, so it would be a load-time cycle), so it quotes inline.
---    This pins the two implementations together.
--- 5. Portable: the behavioural tests point log_dir at an already-existing temp
---    directory, so they exercise the real write path on Linux and on the
---    Windows box where this suite is also run.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()

--- An existing, writable directory. The sink probes writability by opening a
--- file, so pointing at a directory that already exists exercises the real
--- write path without depending on `mkdir -p` semantics.
local function temp_dir()
	local d = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
	return (d:gsub("[/\\]$", ""))
end

--- Reads a whole file, or nil when it cannot be opened.
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Drops fully-commented lines from Lua source.
--- Without this every assertion below is a false green: commenting the install
--- call out leaves the searched text intact inside the comment, so the guard
--- keeps passing while the daemon logs nowhere. Verified — that is exactly how
--- the first version of this test failed to fail.
--- Line-leading `--` only: that is how code actually gets disabled, and it cannot
--- misfire on a `--` appearing inside a string literal.
--- @param src string Lua source.
--- @return string Source with commented-out lines removed.
local function strip_comment_lines(src)
	local kept = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		if not line:match("^%s*%-%-") then kept[#kept + 1] = line end
	end
	return table.concat(kept, "\n")
end

--- Removes the two log files the sink may have created for a given date.
local function cleanup(dir, date)
	os.remove(dir .. "/ErgoptiPlus_" .. date .. ".log")
	os.remove(dir .. "/ErgoptiPlus_errors_" .. date .. ".log")
end





-- ==========================================================
-- ===========================================================
-- ======= 1/ The production boot path installs a sink =======
-- ===========================================================
-- ==========================================================

helpers.describe("logger sink — production wiring", function()
	local raw   = read_file(DRIVER_ROOT .. "/ergopti_hotstrings.lua")
	local entry = raw and strip_comment_lines(raw) or nil

	helpers.it("the entry point is readable", function()
		helpers.assert_not_nil(entry, "ergopti_hotstrings.lua must be readable")
	end)

	helpers.it("the comment stripper actually removes commented code", function()
		-- Self-check: without this the three assertions below cannot fail.
		local sample = "local a = 1\n-- LoggerSink.install(Logger)\nlocal b = 2\n"
		helpers.assert_true(not strip_comment_lines(sample):find("LoggerSink", 1, true),
			"strip_comment_lines must drop a commented-out call")
	end)

	helpers.it("the entry point requires the sink module", function()
		helpers.assert_contains(entry, 'require("lib.logger_sink")',
			"the daemon must require lib.logger_sink")
	end)

	helpers.it("the entry point installs the sink", function()
		helpers.assert_contains(entry, "LoggerSink.install(",
			"requiring the sink is not enough — install() must be called")
	end)

	helpers.it("the sink is installed before the first Logger call", function()
		local install_at = entry:find("LoggerSink%.install%(")
		-- Any of the eight variants; the first one that appears must come after.
		local first_log = entry:find("Logger%.%a+%(")
		helpers.assert_not_nil(install_at, "install() call site not found")
		helpers.assert_not_nil(first_log, "no Logger.* call found in the entry point")
		helpers.assert_true(install_at < first_log,
			"install() must precede the first Logger.* call, otherwise the earliest " ..
			"lines (including boot failures) are still discarded")
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 2/ A log line actually reaches a file =======
-- =====================================================
-- =====================================================

helpers.describe("logger sink — output reaches disk", function()
	helpers.it("an info line is written to the daily file", function()
		local Sink   = helpers.load_module("lib.logger_sink")
		local Logger = helpers.load_module("logger")
		local dir    = temp_dir()
		local date   = os.date("%Y-%m-%d")

		cleanup(dir, date)
		local active = Sink.install(Logger, { log_dir = dir })
		helpers.assert_true(active, "the sink must report an active file sink for a writable dir")
		helpers.assert_true(Sink.is_file_sink_active(), "is_file_sink_active() must agree")

		Logger.info("sink_test", "marker-info-%d", 42)

		local content = read_file(dir .. "/ErgoptiPlus_" .. date .. ".log")
		Sink.uninstall(Logger)
		cleanup(dir, date)

		helpers.assert_not_nil(content, "the daily log file must exist after an info call")
		helpers.assert_contains(content, "marker-info-42",
			"the formatted line must reach the daily log file")
	end)

	helpers.it("an error line is mirrored into the errors-only file", function()
		local Sink   = helpers.load_module("lib.logger_sink")
		local Logger = helpers.load_module("logger")
		local dir    = temp_dir()
		local date   = os.date("%Y-%m-%d")

		cleanup(dir, date)
		Sink.install(Logger, { log_dir = dir })

		Logger.info("sink_test", "marker-plain")
		Logger.error("sink_test", "marker-fatal")

		local main   = read_file(dir .. "/ErgoptiPlus_" .. date .. ".log")
		local errors = read_file(dir .. "/ErgoptiPlus_errors_" .. date .. ".log")
		Sink.uninstall(Logger)
		cleanup(dir, date)

		helpers.assert_not_nil(errors, "the errors-only file must exist after an error call")
		helpers.assert_contains(errors, "marker-fatal", "ERROR must reach the errors-only file")
		helpers.assert_true(not errors:find("marker%-plain"),
			"INFO must NOT reach the errors-only file — that file exists to be short")
		helpers.assert_contains(main, "marker-fatal",
			"ERROR must also reach the daily file, not only the mirror")
	end)

	helpers.it("uninstall clears the sink so the core stops emitting", function()
		local Sink   = helpers.load_module("lib.logger_sink")
		local Logger = helpers.load_module("logger")
		local dir    = temp_dir()
		local date   = os.date("%Y-%m-%d")

		cleanup(dir, date)
		Sink.install(Logger, { log_dir = dir })
		Sink.uninstall(Logger)
		Logger.info("sink_test", "marker-after-uninstall")

		local content = read_file(dir .. "/ErgoptiPlus_" .. date .. ".log")
		cleanup(dir, date)

		helpers.assert_true(content == nil or not content:find("marker%-after%-uninstall"),
			"after uninstall the sink must not receive lines")
	end)
end)





-- ==============================================
-- ===============================================
-- ======= 3/ Rollover repoints both files =======
-- ===============================================
-- ==============================================

helpers.describe("logger sink — date rollover", function()
	helpers.it("both handles are repointed when the date changes", function()
		local src = read_file(DRIVER_ROOT .. "/lib/logger_sink.lua")
		helpers.assert_not_nil(src, "logger_sink.lua must be readable")

		-- open_handles() must assign BOTH handles; a rollover that only repoints
		-- the main file is the macOS defect this guard exists to prevent.
		local body = src:match("local function open_handles%(date%)(.-)\nend")
		helpers.assert_not_nil(body, "open_handles() not found")
		helpers.assert_contains(body, "_main_handle",
			"open_handles must repoint the main handle")
		helpers.assert_contains(body, "_errors_handle",
			"open_handles must repoint the errors handle in the SAME function")

		-- And the write path must consult the date on every line, not only at install.
		local sink_body = src:match("local function sink%(line, variant%)(.-)\nend")
		helpers.assert_not_nil(sink_body, "sink() not found")
		helpers.assert_contains(sink_body, "rollover_if_needed",
			"the sink must check for a date rollover on every write")
	end)
end)




-- =================================================
-- =================================================
-- ======= 4/ One shell-quoting rule ===============
-- =================================================
-- =================================================

helpers.describe("logger sink — quoting parity with shell_runner", function()
	helpers.it("shell_quote matches adapters/shell_runner.quote", function()
		local Sink  = helpers.load_module("lib.logger_sink")
		local Shell = helpers.load_module("adapters.shell_runner")

		local cases = {
			"/home/user/.local/share/ergopti/logs",
			"/tmp/it's here",
			"/tmp/a b c",
			"/tmp/$(whoami)",
			"/tmp/`id`",
			"",
		}
		for _, value in ipairs(cases) do
			helpers.assert_eq(Sink.shell_quote(value), Shell.quote(value),
				"quoting must match shell_runner for: " .. value)
		end
	end)
end)
