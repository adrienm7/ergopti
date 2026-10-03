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





-- ===========================================================
-- ===========================================================
-- ======= 1/ The production boot path installs a sink =======
-- ===========================================================
-- ===========================================================

--- Uses the real sink's write/flush interface; file and console receipts are simulated.
local function with_write_receipts(channel, refusal, body)
	local Sink = helpers.load_module("infra.logger_sink")
	local dir = "/owned-logger-receipts"
	local state = { files = {}, diagnostics = {}, console = {}, failing = true }
	local logger = {}
	function logger.set_sink(callback) state.emit = callback end
	function logger.enable_repeat_collapsing() end
	function logger.disable_repeat_collapsing() end
	local original_open, original_execute = io.open, os.execute
	local original_stdout, original_stderr = io.stdout, io.stderr
	local previous_paths = package.loaded["infra.config_paths"]
	package.loaded["infra.config_paths"] = { get_logs_dir = function() return dir end }
	os.execute = function() return 0 end
	io.stdout = { write = function(_, line) state.console[#state.console + 1] = line; return true end,
		flush = function() return true end }
	io.stderr = { write = function(_, line)
		if state.diagnostics_unavailable then error("diagnostic output is closed") end
		state.diagnostics[#state.diagnostics + 1] = line
		return true
	end }
	io.open = function(path, mode)
		if path == dir .. "/.write_probe" then return { close = function() return true end } end
		if path:sub(1, #dir + 1) ~= dir .. "/" then return original_open(path, mode) end
		local kind = path:find("_errors_", 1, true) and "errors" or "main"
		local file = { writes = 0, flushes = 0, closes = 0 }
		local function receipt(stage)
			if kind == channel and state.failing and stage == refusal.stage then
				if refusal.throws then error("native " .. stage .. " threw") end
				return refusal.value, "native " .. stage .. " refused"
			end
			return true
		end
		function file.write()
			file.writes = file.writes + 1
			return receipt("write")
		end
		function file.flush()
			file.flushes = file.flushes + 1
			return receipt("flush")
		end
		function file.close() file.closes = file.closes + 1; return true end
		state.files[kind] = file
		return file
	end
	local ok, err = xpcall(function()
		helpers.assert_true(Sink.install(logger, { log_dir = dir }))
		body(Sink, state, logger)
	end, debug.traceback)
	Sink.uninstall(logger)
	io.open, os.execute = original_open, original_execute
	io.stdout, io.stderr = original_stdout, original_stderr
	package.loaded["infra.config_paths"] = previous_paths
	if not ok then error(err, 0) end
end

helpers.describe("linux-logger-write-receipts", function()
	for _, channel in ipairs({ "main", "errors" }) do
		for _, refusal in ipairs({
			{ name = "nil write", stage = "write" }, { name = "nil flush", stage = "flush" },
			{ name = "false write", stage = "write", value = false },
			{ name = "false flush", stage = "flush", value = false },
			{ name = "thrown write", stage = "write", throws = true },
			{ name = "thrown flush", stage = "flush", throws = true },
		}) do
			helpers.it("linux-logger-write-receipts: retires " .. channel .. " after " .. refusal.name, function()
				with_write_receipts(channel, refusal, function(Sink, state, logger)
					local failed = state.files[channel]
					state.emit("first native receipt", "warn")
					helpers.assert_eq(failed.closes, 1, "refusal must immediately release its exact handle")
					helpers.assert_eq(Sink.is_file_sink_active(), channel ~= "main")
					helpers.assert_eq(Sink.install(logger), channel ~= "main", "idempotent install must report current durability")
					helpers.assert_eq(#state.diagnostics, 1)
					helpers.assert_contains(state.diagnostics[1], refusal.stage)
					local attempts = failed.writes
					state.emit("second native receipt", "warn")
					helpers.assert_eq(failed.writes, attempts, "retired channel cannot be retried on every line")
					helpers.assert_eq(#state.diagnostics, 1, "the same retired channel cannot flood diagnostics")
					helpers.assert_eq(#state.console, 2)
					local healthy = state.files[channel == "main" and "errors" or "main"]
					helpers.assert_eq(healthy.writes, 2, "one refused channel must not starve the other")
					helpers.assert_eq(healthy.flushes, 2)
				end)
			end)
		end
	end
	helpers.it("linux-logger-write-receipts: closed diagnostic output cannot retain a failed owner", function()
		with_write_receipts("main", { stage = "flush" }, function(Sink, state)
			state.diagnostics_unavailable = true
			state.emit("native refusal without stderr", "warn")
			helpers.assert_true(not Sink.is_file_sink_active())
			helpers.assert_eq(state.files.main.closes, 1)
			helpers.assert_eq(state.files.errors.writes, 1)
			helpers.assert_eq(state.files.errors.flushes, 1)
		end)
	end)
	helpers.it("linux-logger-write-receipts: same-directory repoint acquires a fresh repaired owner", function()
		with_write_receipts("main", { stage = "flush" }, function(Sink, state)
			local failed = state.files.main
			state.emit("initial refusal", "info")
			state.failing = false
			helpers.assert_true(Sink.repoint())
			helpers.assert_true(state.files.main ~= failed, "repair must reopen, not retain the refused descriptor")
			helpers.assert_eq(failed.closes, 1)
			state.emit("repaired durability", "info")
			helpers.assert_true(Sink.is_file_sink_active())
			helpers.assert_eq(state.files.main.writes, 1)
			helpers.assert_eq(state.files.main.flushes, 1)
		end)
	end)
end)

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
		helpers.assert_contains(entry, 'require("infra.logger_sink")',
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

	helpers.it("the periodic callback closes due repeat streaks", function()
		-- Without a periodic flush a source that fell silent keeps its count
		-- until some unrelated line happens to arrive, possibly never.
		local body = entry:match("local on_periodic = function%(%)(.-)\n\tend\n")
		helpers.assert_not_nil(body, "the daemon's on_periodic callback was not found")
		local helper = body:match('RuntimeGuard%.call%("logger repeat flush", ([%w_]+)%)')
		helpers.assert_not_nil(helper, "on_periodic must run the periodic repeat flush under RuntimeGuard")
		helpers.assert_contains(entry, "local function " .. helper .. "() Logger.flush_repeats(false) end",
			"the periodic flush must be the non-terminal form")
	end)

	helpers.it("the exit paths close every open streak before the last line", function()
		-- Exit and crash are the last chance to emit a withheld count.
		local exiting_at = entry:find('Logger.info(LOG, "Daemon exiting.")', 1, true)
		local crash_at = entry:find('Logger.error(LOG, "Daemon terminated by an unhandled error', 1, true)
		helpers.assert_not_nil(exiting_at, "the clean-exit line was not found")
		helpers.assert_not_nil(crash_at, "the crash line was not found")
		-- A direct call, or the guarded pcall form the crash path uses.
		local terminal_flush = "()Logger%.flush_repeats[%(,]%s*true%)"
		local flushes = {}
		for at in entry:gmatch(terminal_flush) do flushes[#flushes + 1] = at end
		helpers.assert_eq(#flushes, 2, "the clean exit and the crash path each need one terminal flush")
		helpers.assert_true(flushes[1] < exiting_at and exiting_at - flushes[1] < 200,
			"the clean exit must flush right before its last line")
		helpers.assert_true(flushes[2] < crash_at and crash_at - flushes[2] < 400,
			"the crash path must flush right before its fatal line")
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 2/ A log line actually reaches a file =======
-- =====================================================
-- =====================================================

helpers.describe("logger sink — output reaches disk", function()
	helpers.it("an info line is written to the daily file", function()
		local Sink   = helpers.load_module("infra.logger_sink")
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
		local Sink   = helpers.load_module("infra.logger_sink")
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

	helpers.it("install arms repeat collapsing once and uninstall disarms it", function()
		local Sink   = helpers.load_module("infra.logger_sink")
		local Logger = helpers.load_module("logger")
		local dir    = temp_dir()
		local date   = os.date("%Y-%m-%d")

		cleanup(dir, date)
		Sink.install(Logger, { log_dir = dir })
		local armed = Logger.repeat_collapsing_enabled()
		-- A second install is the documented idempotent no-op: it must not trip
		-- the core's refusal of a second arming.
		local again_ok = pcall(Sink.install, Logger, { log_dir = dir })
		Logger.debug("sink_test", "marker-repeat-%d", 1)
		Logger.info("sink_test", "marker-between")
		Logger.debug("sink_test", "marker-repeat-%d", 2)
		local content = read_file(dir .. "/ErgoptiPlus_" .. date .. ".log")
		Sink.uninstall(Logger)
		local disarmed = not Logger.repeat_collapsing_enabled()
		cleanup(dir, date)

		helpers.assert_true(armed, "install() is this driver's logger boot and must arm repeat collapsing")
		helpers.assert_true(again_ok, "a second install() must stay a no-op")
		helpers.assert_contains(content, "marker-repeat-1", "the first occurrence must be written")
		helpers.assert_true(not content:find("marker%-repeat%-2"),
			"a repeat of the same template inside the window must be withheld")
		helpers.assert_true(disarmed, "uninstall() must disarm what install() armed")
	end)

	helpers.it("uninstall clears the sink so the core stops emitting", function()
		local Sink   = helpers.load_module("infra.logger_sink")
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





-- ===============================================
-- ===============================================
-- ======= 3/ Rollover repoints both files =======
-- ===============================================
-- ===============================================

helpers.describe("logger sink — date rollover", function()
	helpers.it("both handles are repointed when the date changes", function()
		local src = read_file(DRIVER_ROOT .. "/infra/logger_sink.lua")
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
		local Sink  = helpers.load_module("infra.logger_sink")
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
