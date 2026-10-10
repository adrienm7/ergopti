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

--- Exercises the production preparation path with explicit stdio receipts.
--- Native filesystem ownership is covered by run_logger_write_receipts.lua.
local function with_probe_receipts(failure, test)
	local Sink = helpers.load_module("infra.logger_sink")
	local previous_open, previous_popen = io.open, io.popen
	local previous_execute, previous_remove = os.execute, os.remove
	local state = { opened = {}, removed = {}, written = 0, flushed = 0, closed = 0 }
	local path = "/logger-receipts/.ergopti-log-probe-a1B2C3d4E5"
	os.execute = function() return 0 end
	io.popen = function(command)
		helpers.assert_contains(command, "mktemp --", "probe creation must be exclusive")
		if failure == "create" then return nil, "refused" end
		return { read = function() return path .. "\n" end, close = function() return true end }
	end
	io.open = function(name)
		state.opened[#state.opened + 1] = name
		if failure == "open" then return nil, "refused" end
		local handle = {}
		function handle:write(content)
			state.written = state.written + #content
			if failure == "throw" then error("native write raised") end
			if failure == "write" then return nil, "write refused" end
			return self
		end
		function handle:flush()
			state.flushed = state.flushed + 1
			if failure == "flush" then return nil, "flush refused" end
			return true
		end
		function handle:close()
			state.closed = state.closed + 1
			if failure == "close" then return nil, "close refused" end
			return true
		end
		return handle
	end
	os.remove = function(name)
		state.removed[#state.removed + 1] = name
		if failure == "remove" then return nil, "cleanup refused" end
		return true
	end
	local ok, err = xpcall(function() test(Sink, state, path) end, debug.traceback)
	io.open, io.popen = previous_open, previous_popen
	os.execute, os.remove = previous_execute, previous_remove
	if not ok then error(err, 0) end
end

helpers.describe("linux-logger-probe-receipts", function()
	for _, failure in ipairs({ "create", "open", "write", "throw", "flush", "close", "remove" }) do
		helpers.it("linux-logger-probe-receipts: refuses " .. failure .. " and retires only its owned probe", function()
			with_probe_receipts(failure, function(Sink, state, path)
				local ready, reason = Sink.prepare_dir("/logger-receipts")
				helpers.assert_eq(ready, false, "failed preparation cannot approve a logs directory")
				helpers.assert_eq(type(reason), "string")
				helpers.assert_eq(#state.removed, failure == "create" and 0 or 1)
				if failure ~= "create" then helpers.assert_eq(state.removed[1], path) end
				helpers.assert_eq(state.closed, (failure == "create" or failure == "open") and 0 or 1,
					"even a failed write must retire its descriptor")
			end)
		end)
	end

	helpers.it("linux-logger-probe-receipts: successful preparation proves write, flush, close and cleanup", function()
		with_probe_receipts(nil, function(Sink, state, path)
			helpers.assert_true(Sink.prepare_dir("/logger-receipts"))
			helpers.assert_eq(#state.opened, 1)
			helpers.assert_eq(state.opened[1], path)
			helpers.assert_true(state.written > 0, "opening an empty file cannot prove buffered durability")
			helpers.assert_eq(state.flushed, 1)
			helpers.assert_eq(state.closed, 1)
			helpers.assert_eq(#state.removed, 1)
			helpers.assert_eq(state.removed[1], path)
		end)
	end)
end)





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
		helpers.assert_true(Sink.install(logger, { log_dir = dir, redaction_context = { home = "/home/fixture-user", user = "fixture-user" } }))
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

--- Models native open receipts explicitly; chmod and FD identity are exercised
--- independently by the registered run_logger_write_receipts.lua fixture.
local function with_repoint_receipts(case, body)
	local Sink = helpers.load_module("infra.logger_sink")
	local old, target = "/owned-repoint-old", "/owned-repoint-candidate"
	local state = { phase = "initial", target = old, old = {}, candidates = {}, console = {} }
	local original_open, original_execute = io.open, os.execute
	local original_stdout, original_stderr = io.stdout, io.stderr
	local previous_paths = package.loaded["infra.config_paths"]
	local logger = { set_sink = function(callback) state.emit = callback end,
		enable_repeat_collapsing = function() end, disable_repeat_collapsing = function() end }
	package.loaded["infra.config_paths"] = { get_logs_dir = function() return state.target end }
	os.execute = function()
		if state.phase ~= "initial" and case.mode == "mkdir" then return false end
		return 0
	end
	io.stdout = { write = function(_, line) state.console[#state.console + 1] = line; return true end,
		flush = function() return true end }
	io.stderr = { write = function() return true end }
	io.open = function(path, mode)
		local is_old = path:sub(1, #old + 1) == old .. "/"
		if not is_old and path:sub(1, #target + 1) ~= target .. "/" then return original_open(path, mode) end
		local kind = path:find("_errors_", 1, true) and "errors" or "main"
		helpers.assert_eq(mode, "a")
		if is_old and state.phase ~= "initial" then return nil, "old path now refuses new opens" end
		if is_old and case.mode == "stdout" and kind == "main" then return nil, "initial main refused" end
		if not is_old and case.observe then
			helpers.assert_eq(state.old.main.closes, 0, "candidate acquisition must precede old retirement")
			helpers.assert_eq(state.old.errors.closes, 0)
		end
		if not is_old and kind == case.channel then
			if case.throws then error("simulated native open raised") end
			return case.value, "simulated native open refused"
		end
		local file = { lines = {}, closes = 0 }
		function file:write(line)
			helpers.assert_eq(self.closes, 0, "closed owners cannot receive another line")
			self.lines[#self.lines + 1] = line
			return self
		end
		function file:flush() return true end
		function file:close() self.closes = self.closes + 1; return true end
		if is_old then state.old[kind] = file else
			state.candidates[#state.candidates + 1] = { kind = kind, file = file }
		end
		return file
	end
	local ok, err = xpcall(function()
		if case.mode ~= "none" then
			helpers.assert_eq(Sink.install(logger, { log_dir = old, redaction_context = { home = "/home/fixture-user", user = "fixture-user" } }), case.mode ~= "stdout")
		end
		state.phase = "candidate"
		state.target = case.mode == "same" and old or target
		body(Sink, state, old, target)
	end, debug.traceback)
	Sink.uninstall(logger)
	io.open, os.execute = original_open, original_execute
	io.stdout, io.stderr = original_stdout, original_stderr
	package.loaded["infra.config_paths"] = previous_paths
	if not ok then error(err, 0) end
end

helpers.describe("linux-logger-repoint-owner", function()
	for _, case in ipairs({
		{ name = "nil main", channel = "main" },
		{ name = "false main", channel = "main", value = false },
		{ name = "throwing main", channel = "main", throws = true },
		{ name = "nil optional mirror", channel = "errors", success = true },
		{ name = "false optional mirror", channel = "errors", value = false, success = true },
		{ name = "throwing optional mirror", channel = "errors", throws = true, success = true },
		{ name = "successful staged pair", observe = true, success = true },
		{ name = "repeated main refusal", channel = "main", mode = "repeat" },
		{ name = "mkdir refusal", mode = "mkdir" },
		{ name = "stdout-only refusal", channel = "main", mode = "stdout" },
		{ name = "uninstalled no-op", mode = "none", success = true },
		{ name = "same-directory healthy no-op", mode = "same", success = true },
	}) do
		helpers.it("linux-logger-repoint-owner: " .. case.name, function()
			with_repoint_receipts(case, function(Sink, state, old, target)
				local attempts = case.mode == "repeat" and 2 or 1
				for _ = 1, attempts do
					local moved, reason = Sink.repoint()
					helpers.assert_eq(moved, case.success == true)
					if not moved then helpers.assert_eq(type(reason), "string") end
				end
				if case.mode == "none" then
					helpers.assert_eq(#state.candidates, 0)
					helpers.assert_eq(Sink.is_file_sink_active(), false)
					return
				end
				local switched = case.success and case.mode ~= "same"
				helpers.assert_eq(Sink.log_dir(), switched and target or old)
				helpers.assert_eq(Sink.is_file_sink_active(), case.mode ~= "stdout")
				for _, file in pairs(state.old) do helpers.assert_eq(file.closes, switched and 1 or 0) end
				for _, entry in ipairs(state.candidates) do
					helpers.assert_eq(entry.file.closes, switched and 0 or 1, "only refused provisional owners are closed")
				end
				if case.mode == "same" or case.mode == "mkdir" then helpers.assert_eq(#state.candidates, 0) end
				if case.channel == "main" then
					helpers.assert_eq(#state.candidates, attempts, "each failed main must retire its acquired partial mirror")
				end
				state.emit("line after transition", "warn")
				if not switched and case.mode ~= "stdout" then
					helpers.assert_eq(#state.old.main.lines, 1)
					helpers.assert_eq(#state.old.errors.lines, 1)
				elseif switched then
					for _, entry in ipairs(state.candidates) do helpers.assert_eq(#entry.file.lines, 1) end
				else helpers.assert_eq(#state.old.errors.lines, 0, "stdout-only state must remain stdout-only") end
			end)
		end)
	end
end)

helpers.describe("logger sink — production wiring", function()
	local raw   = read_file(DRIVER_ROOT .. "/ergopti_hotstrings.lua")
	local entry = raw and strip_comment_lines(raw) or nil

	helpers.it("linux-logger-privacy: boot refuses private admission failure without exposing its exception", function()
		local block = entry and entry:match("(local privacy_admitted[^\n]*= pcall%b()%s*if not privacy_admitted.-\nend)")
		helpers.assert_not_nil(block, "The actual bootstrap privacy admission block must be present")
		local run = assert(load("return function(LoggerSink, Logger, io, os)\n" .. block .. "\nend"))()
		for _, result in ipairs({ "true", "false", "throw", "refusal" }) do
			local calls, exits, output = 0, {}, {}
			run({ install = function()
				calls = calls + 1
				if result == "throw" then error("PRIVATE_BOOT_CANARY /home/PrivateUser", 0) end
				if result == "refusal" then return false, "PRIVATE_REFUSAL_CANARY /home/PrivateUser" end
				return result == "true"
			end }, {}, { stderr = { write = function(_, text) output[#output + 1] = text end } },
				{ exit = function(code) exits[#exits + 1] = code end })
			helpers.assert_eq(calls, 1)
			local refused = result == "throw" or result == "refusal"
			helpers.assert_eq(exits, refused and { 1 } or {})
			helpers.assert_eq(output, refused
				and { "[logger_sink] Privacy initialization refused; daemon not started.\n" } or {})
		end
	end)

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
		local active = Sink.install(Logger, { log_dir = dir, redaction_context = { home = "/home/fixture-user", user = "fixture-user" } })
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
		Sink.install(Logger, { log_dir = dir, redaction_context = { home = "/home/fixture-user", user = "fixture-user" } })

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
		Sink.install(Logger, { log_dir = dir, redaction_context = { home = "/home/fixture-user", user = "fixture-user" } })
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
		Sink.install(Logger, { log_dir = dir, redaction_context = { home = "/home/fixture-user", user = "fixture-user" } })
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

--- Runs the real install/sink with captured stdio and command dependencies.
--- Policy bytes come from the canonical file; all writable handles are in memory.
--- @param options table Controlled admission/channel failure.
--- @param body function Receives the actual sink and observed port effects.
local function with_private_log_sink(options, body)
	local policy_path = require("infra.paths").shared("modules/diagnostics/redaction.json")
	local policy = assert(read_file(policy_path))
	local saved_open, saved_execute, saved_getenv = io.open, os.execute, os.getenv
	local saved_stdout, saved_stderr = io.stdout, io.stderr
	local names = { "infra.paths", "infra.config_paths", "infra.timings", "infra.logger_sink" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local state = { main = {}, errors = {}, console = {}, diagnostics = {}, commands = 0, policy_reads = 0,
		policy_closes = 0, writable_opens = 0, environment_reads = 0 }
	local logger = { enable_repeat_collapsing = function() end, disable_repeat_collapsing = function() end }
	function logger.set_sink(callback) state.emit = callback end
	local Sink = helpers.load_module("infra.logger_sink")
	package.loaded["infra.paths"] = {
		driver_root = function() return "/owned-driver" end,
		shared_root_from = function(root)
			helpers.assert_eq(root, "/owned-driver")
			if options.missing_tree then return nil end
			return "/owned-shared"
		end,
	}
	package.loaded["infra.config_paths"] = { get_logs_dir = function() return "/home/PrivateUser/logs" end }
	package.loaded["infra.timings"] = { count = function() return 7 end }
	os.getenv = function(name)
		state.environment_reads = state.environment_reads + 1
		if options.missing_identity then return nil end
		if name == "HOME" then return "/home/PrivateUser" end
		if name == "USER" or name == "LOGNAME" then return "PrivateUser" end
	end
	os.execute = function() state.commands = state.commands + 1; return 0 end
	io.stdout = { write = function(_, line) state.console[#state.console + 1] = line; return true end,
		flush = function() return true end }
	io.stderr = { write = function(_, line) state.diagnostics[#state.diagnostics + 1] = line; return true end }
	io.open = function(path, mode)
		if mode == "rb" then
			helpers.assert_eq(path, "/owned-shared/modules/diagnostics/redaction.json")
			if options.missing_policy then return nil, "owned policy read refusal" end
			return { read = function()
				state.policy_reads = state.policy_reads + 1
				return options.invalid_policy and "{}" or policy
			end, close = function()
				state.policy_closes = state.policy_closes + 1
				return not options.policy_close_refused
			end }
		end
		helpers.assert_eq(mode, "a")
		helpers.assert_true(path:sub(1, #"/home/PrivateUser/logs/") == "/home/PrivateUser/logs/")
		state.writable_opens = state.writable_opens + 1
		if options.stdout_only then return nil, "PrivateUser cannot open /home/PrivateUser/logs" end
		local channel = path:find("_errors_", 1, true) and "errors" or "main"
		return { write = function(_, line)
			if options.write_refused == channel then return nil, "PrivateUser write refused /home/PrivateUser/logs; password=secret12345" end
			state[channel][#state[channel] + 1] = line
			return true
		end, flush = function() return true end, close = function() return true end }
	end
	local ok, err = xpcall(function() body(Sink, state, logger) end, debug.traceback)
	Sink.uninstall(logger)
	io.open, os.execute, os.getenv = saved_open, saved_execute, saved_getenv
	io.stdout, io.stderr = saved_stdout, saved_stderr
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("linux-logger-privacy", function()
	helpers.it("linux-logger-privacy: invalid logger refuses without any raw diagnostic or output authority", function()
		with_private_log_sink({}, function(Sink, state)
			local accepted, reason = Sink.install({})
			helpers.assert_eq(accepted, false)
			helpers.assert_contains(reason, "logger_sink:")
			helpers.assert_eq(state.commands + state.writable_opens, 0)
			helpers.assert_eq(#state.console + #state.main + #state.errors + #state.diagnostics, 0)
			helpers.assert_nil(state.emit)
		end)
	end)

	helpers.it("linux-logger-privacy: canonical default admission protects all outputs and is captured before emissions", function()
		with_private_log_sink({}, function(Sink, state, logger)
			helpers.assert_eq(Sink.install(logger), true)
			helpers.assert_eq(state.policy_reads, 1)
			helpers.assert_eq(state.policy_closes, 1)
			local reads, commands, opens = state.environment_reads, state.commands, state.writable_opens
			for _, variant in ipairs({ "error", "warn" }) do
				state.emit("2026-10-10 [" .. variant .. "] PrivateUser failed /home/PrivateUser/cache; PrivateUser2; password=secret12345", variant)
			end
			for _, channel in ipairs({ "main", "errors", "console" }) do
				helpers.assert_eq(#state[channel], 2)
				for _, line in ipairs(state[channel]) do
					helpers.assert_contains(line, "<user> failed ~/cache; PrivateUser2; password=<secret>")
				end
			end
			helpers.assert_eq(state.policy_reads, 1, "No per-message policy read")
			helpers.assert_eq(state.environment_reads, reads, "No per-message identity discovery")
			helpers.assert_eq(state.commands, commands)
			helpers.assert_eq(state.writable_opens, opens)
		end)
	end)

	helpers.it("linux-logger-privacy: stdout-only failure still protects the direct diagnostic and emitted error", function()
		with_private_log_sink({ stdout_only = true }, function(Sink, state, logger)
			helpers.assert_eq(Sink.install(logger), false)
			helpers.assert_eq(#state.diagnostics, 1)
			helpers.assert_contains(state.diagnostics[1], "under ~/logs")
			state.emit("PrivateUser failure /home/PrivateUser/cache", "error")
			helpers.assert_eq(state.console, { "<user> failure ~/cache" })
			helpers.assert_eq(#state.main, 0)
			helpers.assert_eq(#state.errors, 0)
		end)
	end)

	for _, channel in ipairs({ "main", "errors" }) do
		helpers.it("linux-logger-privacy: " .. channel .. " native refusal keeps the error but protects stderr", function()
			with_private_log_sink({ write_refused = channel }, function(Sink, state, logger)
				helpers.assert_eq(Sink.install(logger), true)
				state.emit("ordinary technical error", "error")
				helpers.assert_eq(#state.diagnostics, 1)
				helpers.assert_contains(state.diagnostics[1], channel .. " write/flush failed: <user> write refused ~/logs; password=<secret>")
				helpers.assert_contains(state.diagnostics[1], "channel retired")
			end)
		end)
	end

	for _, refusal in ipairs({ "missing_identity", "missing_tree", "missing_policy", "invalid_policy", "policy_close_refused" }) do
		helpers.it("linux-logger-privacy: " .. refusal .. " refuses before any output or acquisition", function()
			with_private_log_sink({ [refusal] = true }, function(Sink, state, logger)
				local ok, err = pcall(Sink.install, logger)
				helpers.assert_eq(ok, false)
				helpers.assert_contains(tostring(err), "logger_sink:")
				helpers.assert_eq(state.commands, 0)
				helpers.assert_eq(state.writable_opens, 0)
				helpers.assert_eq(#state.console + #state.main + #state.errors + #state.diagnostics, 0)
				helpers.assert_nil(state.emit)
			end)
		end)
	end

	helpers.it("linux-logger-privacy: fixture identity is cloned and duplicate install retains the first admission", function()
		with_private_log_sink({}, function(Sink, state, logger)
			local identity = { home = "/home/PrivateUser", user = "PrivateUser" }
			helpers.assert_eq(Sink.install(logger, { redaction_context = identity }), true)
			local original = state.emit
			identity.home, identity.user = "/foreign", "foreign"
			helpers.assert_eq(Sink.install(logger, { redaction_context = {} }), true)
			helpers.assert_eq(state.emit, original)
			state.emit("PrivateUser /home/PrivateUser/cache", "error")
			helpers.assert_eq(state.main, { "<user> ~/cache" })
			helpers.assert_eq(state.policy_reads, 1)
		end)
	end)
end)


helpers.describe("linux-logger-privacy metadata", function()
	helpers.it("linux-logger-privacy: actual core metadata survives account collisions and multiline message redaction", function()
		local previous = package.loaded["logger"]
		package.loaded["logger"] = nil
		local Core = require("logger")
		Core.timestamp_fn = function() return "2026-10-10 12:00:00:000" end
		local ok, err = xpcall(function()
			for _, user in ipairs({ "2026", "ERROR", "logger" }) do
				with_private_log_sink({}, function(Sink, state, logger)
					helpers.assert_eq(Sink.install(logger, { redaction_context = { home = "/home/" .. user, user = user } }), true)
					Core.set_sink(state.emit)
					local raw = Core.error("logger", "User %s failed\nsource /home/%s/cache; password=secret12345", user, user)
					local marker = " [ERROR] [logger] "
					local at = assert(raw:find(marker, 1, true), "The actual core's structured prefix is required")
					local prefix = raw:sub(1, at + #marker - 1)
					local expected = prefix .. "User <user> failed\nsource ~/cache; password=<secret>"
					for _, channel in ipairs({ "main", "errors", "console" }) do
						helpers.assert_eq(state[channel], { expected })
					end
					Core.set_sink(nil)
				end)
			end
		end, debug.traceback)
		Core.set_sink(nil)
		package.loaded["logger"] = previous
		if not ok then error(err, 0) end
	end)
end)


helpers.describe("linux-logger-privacy malformed metadata", function()
	helpers.it("linux-logger-privacy: unformatted private prefixes cannot masquerade as core metadata", function()
		with_private_log_sink({}, function(Sink, state, logger)
			helpers.assert_eq(Sink.install(logger), true)
			local suffix = " [ERROR] [logger] password=secret12345"
			local cases = {
				{ "PrivateUser /home/PrivateUser" .. suffix, "<user> ~ [ERROR] [logger] password=<secret>" },
				{ "PrivateUser 2026-10-10 12:00:00:000" .. suffix, "<user> 2026-10-10 12:00:00:000 [ERROR] [logger] password=<secret>" },
				{ "/home/PrivateUser 2026-10-10 12:00:00" .. suffix, "~ 2026-10-10 12:00:00 [ERROR] [logger] password=<secret>" },
			}
			local expected = {}
			for _, case in ipairs(cases) do
				state.emit(case[1], "error")
				expected[#expected + 1] = case[2]
			end
			for _, channel in ipairs({ "main", "errors", "console" }) do
				helpers.assert_eq(state[channel], expected)
			end
		end)
	end)
end)
