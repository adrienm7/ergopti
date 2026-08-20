--- tests/unit/lib/test_logger_file_sinks.lua

--- ==============================================================================
--- MODULE: Contract — the driver half of the logger, asserted as behaviour
--- DESCRIPTION:
--- The shared core (_shared/lua/logger) owns the line format, the severity
--- filter, the ring and the dedup window, and all of that is pinned by a
--- cross-driver corpus. What the core does NOT own is everything this driver
--- adds around it: the unified daily file, the errors-only mirror, the topical
--- fan-out, the level-aware flush policy, and the print() tee.
---
--- That half was guarded almost entirely by SOURCE SCANNING. A test asserting
--- that `_flush_dedup_summary` contains the substring "M.ERRORS_LOG_FILE" is not
--- checking that a suppressed error storm reaches the errors log; it is checking
--- where a line of code currently sits. The two coincide until the day the code
--- moves, at which point the grep goes red while the behaviour is untouched — and
--- the only available reading of a red test is "you broke it".
---
--- So this file states the driver-half contract in terms of what the logger DOES,
--- through its public API only. It is what makes the migration onto the shared
--- core a provable no-op instead of a diff nobody can validate: green before,
--- green after, and red the moment a sink actually stops receiving what it owes.
---
--- WHAT IS ASSERTED:
--- 1. The unified file receives the canonical "TIMESTAMP [LEVEL] [module] body".
--- 2. WARNING and ERROR are mirrored to the errors-only file; INFO and DEBUG are
---    not — that file is small on purpose, and it is the first place to look.
--- 3. A line whose tag matches a topical pattern is fanned out to that sub-file;
---    an unrouted line goes only to the unified log.
--- 4. INFO and above flush immediately; DEBUG lines do not flush per line. The
---    default level is DEBUG and DEBUG lines come off the keystroke path, so a
---    per-line fsync would land inside the event tap.
--- 5. A suppression summary carries the RIGHT COUNT and takes the same sinks as
---    the lines it stands for, errors-only mirror included.
--- 6. The print() tee captures foreign output and does not double-write the
---    Logger's own lines.
--- ==============================================================================

local helpers = require("tests.helpers")

local Logger = helpers.load_with_stubs("infra.logger")

-- Tag that matches a topical pattern in the generated routing table
-- (_generated/logger_sub_files.lua routes "[karabiner" to its own sub-file).
local ROUTED_TAG = "karabiner"

-- Tag deliberately absent from every routing pattern, so a line carrying it must
-- reach the unified log and nothing else.
local UNROUTED_TAG = "zzz_unrouted"

-- Buffered DEBUG lines the driver allows before flushing anyway. Mirrors
-- FLUSH_EVERY_N_DEBUG in infra/logger.lua; the assertions below stay strictly
-- under it so they measure the deferral, not the safety valve.
local DEBUG_FLUSH_THRESHOLD = 40

-- Identical lines emitted back to back inside the dedup window. Two suppressed
-- means the summary must read "2", which is the assertion a source scan could
-- never make: it can see that a counter is written before it is reset, but not
-- that the number is right.
local SUPPRESSED_COUNT = 2





-- =======================================
-- =======================================
-- ======= 0/ Sink Capture Harness =======
-- =======================================
-- =======================================

--- Runs `body` with io.open replaced by a recorder, and returns everything the
--- logger wrote, keyed by path, plus a flush tally per path.
---
--- Nothing touches the disk: the assertions are about which sink received which
--- bytes, and a real file would only add a temp directory to clean up. hs.fs
--- reports every file as modified today so the topical fan-out appends rather
--- than truncating — the daily-reset decision has its own dedicated test and is
--- deliberately not re-asserted here.
--- @param dir string Log directory to point the logger at for this capture.
--- @param body function Callback run with the recorder installed, receiving the
---   live (writes, flushes) tables so a test can read a tally MID-capture — the
---   flush policy is about what happens between two lines, which is unobservable
---   from a return value taken after both.
--- @return table writes Map of path → array of written strings.
--- @return table flushes Map of path → number of flush() calls.
local function capture(dir, body)
	local hs          = _G.hs
	local saved_attrs = hs.fs and hs.fs.attributes or nil
	local saved_open  = io.open
	local saved_level = Logger.current_level
	local writes      = {}
	local flushes     = {}

	-- The suite runs at WARNING, which would drop every INFO and DEBUG line
	-- before it ever reached a sink and leave these assertions measuring nothing.
	Logger.set_level("DEBUG")
	Logger.reset_dedup()

	if hs.fs then
		hs.fs.attributes = function(_path) return { modification = os.time() } end
	end

	io.open = function(path, _mode)
		local key = tostring(path)
		writes[key]  = writes[key]  or {}
		flushes[key] = flushes[key] or 0
		return {
			write = function(_self, chunk) writes[key][#writes[key] + 1] = tostring(chunk) end,
			flush = function() flushes[key] = flushes[key] + 1 end,
			close = function() end,
			read  = function() return nil end,
		}
	end

	-- Re-pointing closes the handle cached by an earlier capture. Without it the
	-- logger would keep writing into the PREVIOUS capture's recorder and every
	-- assertion after the first would read an empty table.
	Logger.init_log_path(dir, 14)

	local ok, err = pcall(body, writes, flushes)

	io.open = saved_open
	if hs.fs then hs.fs.attributes = saved_attrs end
	Logger.set_level(saved_level)
	Logger.reset_dedup()

	if not ok then error(err, 0) end
	return writes, flushes
end

--- Everything written to one path, concatenated.
--- @param writes table Result of capture().
--- @param path string Absolute path to read back.
--- @return string
local function text_of(writes, path)
	local chunks = writes[path]
	if not chunks then return "" end
	return table.concat(chunks)
end

--- True when `haystack` contains `needle` as a plain substring.
--- @param haystack string
--- @param needle string
--- @return boolean
local function has(haystack, needle)
	return haystack:find(needle, 1, true) ~= nil
end

--- Path of the topical sub-file the routed tag is expected to reach.
---
--- Derived from the unified log rather than from the directory handed to
--- init_log_path(): the logger appends "hammerspoon/logs/" to that argument, so a
--- path built from the argument alone points at a file nothing ever writes and
--- the assertion fails for a reason that has nothing to do with routing.
--- @return string
local function routed_sub_file()
	local log_dir = Logger.UNIFIED_LOG_FILE:match("^(.*/)") or ""
	return log_dir .. "ErgoptiPlus_" .. ROUTED_TAG .. ".log"
end





-- ========================================
-- ========================================
-- ======= 1/ The Unified File Sink =======
-- ========================================
-- ========================================

helpers.describe("logger file sinks — the unified daily log", function()
	helpers.it("writes the canonical TIMESTAMP [LEVEL] [module] body line", function()
		local dir = "/tmp/ergopti_sinks_unified/"
		local writes = capture(dir, function()
			Logger.info("probe_mod", "unified sink body")
		end)

		local unified = text_of(writes, Logger.UNIFIED_LOG_FILE)
		helpers.assert_true(unified ~= "",
			"the unified log received nothing at all — with no bytes captured every "
			.. "assertion in this file would be vacuous")

		-- Anchored on the line, not merely searched for: a body that landed without
		-- its level tag, or with the tag in the wrong order, is a format regression
		-- that a bare "contains the body" check would wave through.
		local matched = unified:match("(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d:%d%d%d %[INFO%] %[probe_mod%] unified sink body)")
		helpers.assert_true(matched ~= nil, string.format(
			"the unified log must carry the canonical line format shared with the AutoHotkey "
			.. "driver and the shared core — \"YYYY-MM-DD HH:MM:SS:mmm [LEVEL] [module] body\". "
			.. "Got:\n%s", unified))
	end)

	helpers.it("writes every variant, each under its own label", function()
		local dir = "/tmp/ergopti_sinks_variants/"
		local writes = capture(dir, function()
			Logger.debug("probe_mod",   "v debug")
			Logger.trace("probe_mod",   "v trace")
			Logger.done("probe_mod",    "v done")
			Logger.info("probe_mod",    "v info")
			Logger.start("probe_mod",   "v start")
			Logger.success("probe_mod", "v success")
			Logger.warn("probe_mod",    "v warn")
			Logger.error("probe_mod",   "v error")
		end)

		local unified = text_of(writes, Logger.UNIFIED_LOG_FILE)
		local expected = {
			{ "[DEBUG] [probe_mod] v debug",     "debug"   },
			{ "[TRACE] [probe_mod] v trace",     "trace"   },
			{ "[DONE] [probe_mod] v done",       "done"    },
			{ "[INFO] [probe_mod] v info",       "info"    },
			{ "[START] [probe_mod] v start",     "start"   },
			{ "[SUCCESS] [probe_mod] v success", "success" },
			{ "[WARNING] [probe_mod] v warn",    "warn"    },
			{ "[ERROR] [probe_mod] v error",     "error"   },
		}
		for _, pair in ipairs(expected) do
			helpers.assert_true(has(unified, pair[1]), string.format(
				"Logger.%s() must reach the unified file as \"%s\". A variant that renders under "
				.. "the wrong label breaks log triage silently: the line is there, and grepping "
				.. "for its level never finds it.", pair[2], pair[1]))
		end
	end)

	helpers.it("drops a line below the active level before any sink sees it", function()
		local dir = "/tmp/ergopti_sinks_filtered/"
		local writes = capture(dir, function()
			Logger.set_level("WARNING")
			Logger.info("probe_mod", "filtered out body")
			Logger.warn("probe_mod", "kept body")
		end)

		local unified = text_of(writes, Logger.UNIFIED_LOG_FILE)
		helpers.assert_true(has(unified, "kept body"),
			"a WARNING at threshold WARNING must still be written — otherwise this assertion "
			.. "pair proves only that the capture is broken")
		helpers.assert_true(not has(unified, "filtered out body"),
			"a line below the active level must never reach the file sink. Filtering after the "
			.. "write would keep the console quiet while the file grew at full volume — the "
			.. "opposite of what lowering the level is for")
	end)
end)





-- =========================================
-- =========================================
-- ======= 2/ The Errors-Only Mirror =======
-- =========================================
-- =========================================

helpers.describe("logger file sinks — the errors-only mirror", function()
	helpers.it("mirrors WARNING and ERROR, and nothing quieter", function()
		local dir = "/tmp/ergopti_sinks_errors/"
		local writes = capture(dir, function()
			Logger.debug("probe_mod", "mirror debug body")
			Logger.info("probe_mod",  "mirror info body")
			Logger.warn("probe_mod",  "mirror warn body")
			Logger.error("probe_mod", "mirror error body")
		end)

		local errors_log = text_of(writes, Logger.ERRORS_LOG_FILE)
		helpers.assert_true(errors_log ~= "",
			"the errors-only log received nothing — the mirror is the recommended first place "
			.. "to look when something goes wrong, and an empty one reads as \"no problems\"")

		helpers.assert_true(has(errors_log, "mirror warn body"),
			"a WARNING must be mirrored into the errors-only log")
		helpers.assert_true(has(errors_log, "mirror error body"),
			"an ERROR must be mirrored into the errors-only log")
		helpers.assert_true(not has(errors_log, "mirror debug body"),
			"a DEBUG line must NOT reach the errors-only log — the file's whole value is that "
			.. "it stays small enough to read end to end")
		helpers.assert_true(not has(errors_log, "mirror info body"),
			"an INFO line must NOT reach the errors-only log")
	end)

	helpers.it("keeps the mirrored line identical to the unified one", function()
		local dir = "/tmp/ergopti_sinks_mirror_shape/"
		local writes = capture(dir, function()
			Logger.error("probe_mod", "shape check body")
		end)

		local unified    = text_of(writes, Logger.UNIFIED_LOG_FILE)
		local errors_log = text_of(writes, Logger.ERRORS_LOG_FILE)

		local pattern = "(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d:%d%d%d %[ERROR%] %[probe_mod%] shape check body)"
		local from_unified = unified:match(pattern)
		local from_errors  = errors_log:match(pattern)

		helpers.assert_true(from_unified ~= nil, "the unified log must carry the full ERROR line")
		helpers.assert_true(from_errors ~= nil, "the errors-only log must carry the full ERROR line")
		helpers.assert_eq(from_errors, from_unified,
			"the two sinks must receive the SAME rendered line. A mirror that re-renders is a "
			.. "second formatter, and the moment the two disagree the errors file stops being "
			.. "usable as evidence of what the unified log says")
	end)
end)





-- ======================================
-- ======================================
-- ======= 3/ The Topical Fan-Out =======
-- ======================================
-- ======================================

helpers.describe("logger file sinks — topical fan-out", function()
	helpers.it("routes a matching line to its sub-file as well as the unified log", function()
		local dir = "/tmp/ergopti_sinks_routed/"
		local writes = capture(dir, function()
			Logger.info(ROUTED_TAG, "routed body")
		end)

		local unified = text_of(writes, Logger.UNIFIED_LOG_FILE)
		local sub     = text_of(writes, routed_sub_file())

		helpers.assert_true(has(unified, "routed body"),
			"a routed line must ALSO be written to the unified log — the sub-files are a "
			.. "filtered view, not a redirection")
		helpers.assert_true(has(sub, "routed body"), string.format(
			"the line tagged [%s] must reach %s. The topical logs exist so triage is one small "
			.. "file rather than a grep over the day's whole volume; a fan-out that stops "
			.. "matching leaves them empty and nothing reports it.", ROUTED_TAG, routed_sub_file()))
	end)

	helpers.it("leaves an unrouted line out of every sub-file", function()
		local dir = "/tmp/ergopti_sinks_unrouted/"
		local writes = capture(dir, function()
			Logger.info(UNROUTED_TAG, "unrouted body")
		end)

		helpers.assert_true(has(text_of(writes, Logger.UNIFIED_LOG_FILE), "unrouted body"),
			"the unrouted line must still reach the unified log")

		for path, _ in pairs(writes) do
			if path ~= Logger.UNIFIED_LOG_FILE and path ~= Logger.ERRORS_LOG_FILE then
				helpers.assert_true(not has(text_of(writes, path), "unrouted body"), string.format(
					"a line matching no routing pattern reached the sub-file %s. A fan-out that "
					.. "over-matches makes every topical log a copy of the main one, which costs "
					.. "the disk and destroys the reason to open them.", path))
			end
		end
	end)
end)





-- ===================================
-- ===================================
-- ======= 4/ The Flush Policy =======
-- ===================================
-- ===================================

helpers.describe("logger file sinks — level-aware flush policy", function()
	helpers.it("flushes INFO and above on every line", function()
		local dir = "/tmp/ergopti_sinks_flush_info/"
		local _, flushes = capture(dir, function()
			Logger.info("probe_mod", "flush probe one")
			Logger.info("probe_mod", "flush probe two")
			Logger.info("probe_mod", "flush probe three")
		end)

		local count = flushes[Logger.UNIFIED_LOG_FILE] or 0
		helpers.assert_true(count >= 3, string.format(
			"three INFO lines must produce at least three flushes, got %d. These are the lines "
			.. "that matter after a crash and they are rare enough to afford it — deferring them "
			.. "loses exactly the tail that explains what happened.", count))
	end)

	helpers.it("does not flush per DEBUG line", function()
		local dir = "/tmp/ergopti_sinks_flush_debug/"
		capture(dir, function(_writes, flushes)
			-- One INFO first: it flushes immediately, which zeroes the deferred-line
			-- counter, so the DEBUG burst below is measured from a known state
			-- rather than from whatever an earlier capture left behind.
			Logger.info("probe_mod", "flush baseline")
			local before = flushes[Logger.UNIFIED_LOG_FILE] or 0

			for i = 1, DEBUG_FLUSH_THRESHOLD - 1 do
				Logger.debug("probe_mod", "deferred debug line %d", i)
			end

			local after = flushes[Logger.UNIFIED_LOG_FILE] or 0
			helpers.assert_eq(after, before, string.format(
				"%d DEBUG lines under the threshold of %d must add no flush, got %d extra. The "
				.. "default level is DEBUG and DEBUG lines are emitted from the keystroke path, "
				.. "so a flush per line is a synchronous fsync inside the event tap — which is "
				.. "the one place macOS disables a tap for being unresponsive.",
				DEBUG_FLUSH_THRESHOLD - 1, DEBUG_FLUSH_THRESHOLD, after - before))
		end)
	end)

	helpers.it("flushes anyway once the deferred burst reaches the threshold", function()
		local dir = "/tmp/ergopti_sinks_flush_valve/"
		capture(dir, function(_writes, flushes)
			Logger.info("probe_mod", "valve baseline")
			local before = flushes[Logger.UNIFIED_LOG_FILE] or 0

			for i = 1, DEBUG_FLUSH_THRESHOLD do
				Logger.debug("probe_mod", "valve debug line %d", i)
			end

			local after = flushes[Logger.UNIFIED_LOG_FILE] or 0
			helpers.assert_true(after > before, string.format(
				"a burst of %d DEBUG lines must trigger the safety valve. Without it the "
				.. "deferral is unbounded, and a burst of tracing is precisely when losing the "
				.. "tail hurts most.", DEBUG_FLUSH_THRESHOLD))
		end)
	end)
end)





-- ====================================
-- ====================================
-- ======= 5/ The Dedup Summary =======
-- ====================================
-- ====================================

helpers.describe("logger file sinks — the suppression summary", function()
	helpers.it("reports the exact number of lines it swallowed", function()
		local dir = "/tmp/ergopti_sinks_dedup_count/"
		local writes = capture(dir, function()
			Logger.error("probe_mod", "storm body")
			for _ = 1, SUPPRESSED_COUNT do
				Logger.error("probe_mod", "storm body")
			end
			-- A different line closes the streak and forces the summary out.
			Logger.error("probe_mod", "streak breaker")
		end)

		local unified = text_of(writes, Logger.UNIFIED_LOG_FILE)
		local expected = string.format("%d identical lines suppressed", SUPPRESSED_COUNT)
		helpers.assert_true(has(unified, expected), string.format(
			"the summary must report %d. This is the assertion a source scan cannot make: it "
			.. "can see that the counter is written before it is reset, but not that the number "
			.. "is right — and a summary reading 0 is worse than none, because it claims nothing "
			.. "was lost. Got:\n%s", SUPPRESSED_COUNT, unified))
	end)

	helpers.it("mirrors a suppressed ERROR streak into the errors-only log", function()
		local dir = "/tmp/ergopti_sinks_dedup_mirror/"
		local writes = capture(dir, function()
			Logger.error("probe_mod", "mirrored storm")
			for _ = 1, SUPPRESSED_COUNT do
				Logger.error("probe_mod", "mirrored storm")
			end
			Logger.error("probe_mod", "mirrored breaker")
		end)

		local errors_log = text_of(writes, Logger.ERRORS_LOG_FILE)
		helpers.assert_true(has(errors_log, "identical lines suppressed"), string.format(
			"a suppressed ERROR storm must have its summary mirrored into the errors-only log. "
			.. "Without it that file shows the first occurrence and silently omits the repeat "
			.. "count, so a storm and a one-off read identically. Got:\n%s", errors_log))
		helpers.assert_true(has(errors_log, string.format("%d identical", SUPPRESSED_COUNT)),
			"the mirrored summary must carry the same count as the unified one")
	end)

	helpers.it("keeps a suppressed INFO streak out of the errors-only log", function()
		local dir = "/tmp/ergopti_sinks_dedup_info/"
		local writes = capture(dir, function()
			Logger.info("probe_mod", "quiet storm")
			for _ = 1, SUPPRESSED_COUNT do
				Logger.info("probe_mod", "quiet storm")
			end
			Logger.info("probe_mod", "quiet breaker")
		end)

		local unified    = text_of(writes, Logger.UNIFIED_LOG_FILE)
		local errors_log = text_of(writes, Logger.ERRORS_LOG_FILE)

		helpers.assert_true(has(unified, "identical lines suppressed"),
			"the INFO streak's summary must still reach the unified log — otherwise this test "
			.. "passes because nothing was suppressed at all")
		helpers.assert_true(not has(errors_log, "identical lines suppressed"),
			"an INFO suppression summary must NOT reach the errors-only log. The summary "
			.. "inherits the variant of the lines it stands for, so a mirror keyed on anything "
			.. "else would fill the triage file with routine noise")
	end)
end)





-- ==================================
-- ==================================
-- ======= 6/ The print() Tee =======
-- ==================================
-- ==================================

helpers.describe("logger file sinks — the print() tee", function()
	helpers.it("captures foreign output and does not double-write its own", function()
		-- A dedicated instance: install_runtime_error_capture() patches _G.print
		-- and the hs.timer constructors, and it is one-shot per module instance.
		local TeeLogger = helpers.load_with_stubs("infra.logger")

		local dir         = "/tmp/ergopti_sinks_tee/"
		local saved_print = _G.print
		local saved_open  = io.open
		local saved_attrs = _G.hs.fs and _G.hs.fs.attributes or nil
		local writes      = {}

		TeeLogger.set_level("DEBUG")
		TeeLogger.reset_dedup()
		if _G.hs.fs then
			_G.hs.fs.attributes = function(_path) return { modification = os.time() } end
		end
		io.open = function(path, _mode)
			local key = tostring(path)
			writes[key] = writes[key] or {}
			return {
				write = function(_self, chunk) writes[key][#writes[key] + 1] = tostring(chunk) end,
				flush = function() end,
				close = function() end,
				read  = function() return nil end,
			}
		end

		local ok, err = pcall(function()
			TeeLogger.init_log_path(dir, 14)
			TeeLogger.install_runtime_error_capture()
			print("foreign traceback line")
			TeeLogger.info("probe_mod", "logger own line")
		end)

		io.open  = saved_open
		_G.print = saved_print
		if _G.hs.fs then _G.hs.fs.attributes = saved_attrs end
		if not ok then error(err, 0) end

		local unified = text_of(writes, TeeLogger.UNIFIED_LOG_FILE)

		helpers.assert_true(has(unified, "[CONSOLE] [console] foreign traceback line"), string.format(
			"a print() from outside the Logger must be teed into the unified file. Hammerspoon "
			.. "reports its own uncaught errors by printing to a Console that cannot be exported, "
			.. "so without the tee the file log is missing exactly the diagnostics nobody can "
			.. "recover afterwards. Got:\n%s", unified))

		local occurrences = select(2, unified:gsub("logger own line", ""))
		helpers.assert_eq(occurrences, 1, string.format(
			"the Logger's own console write must appear ONCE in the file. It is already "
			.. "persisted by the file sink, so a tee that re-captures it doubles every line in "
			.. "the log — got %d copies", occurrences))
	end)
end)
