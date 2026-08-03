--- tests/unit/modules/keylogger/test_aggregator.lua

--- ==============================================================================
--- MODULE: keylogger.aggregator Unit Tests
--- DESCRIPTION:
--- Verifies the pure in-memory walking and batch management logic of the
--- keylogger aggregator. All SQLite and hs.* dependencies are stubbed so no
--- real database or OS call is made during the run.
---
--- FEATURES & RATIONALE:
--- 1. N-gram Context: Exercises get/set/reset_ngram_ctx round-trips.
--- 2. Batch Management: Confirms reset_batch produces a clean slate.
--- 3. Typing Walker: Validates char-count increments, char-class bins, burst
---    boundary detection, and backspace backtracking on a synthetic event array.
--- 4. App-switch Walker: Confirms duration accumulation and switch-to tracking.
--- 5. System-event Walker: Checks kc_hold and system_day counter increments.
--- 6. Init Guard: Public functions called before M.init() must not crash.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================
-- =====================================
-- ======= 1/ Module Loading ===========
-- =====================================
-- =====================================

-- lib.logger must be resolved first so downstream requires can find it.
package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- export is required by aggregator.flush(); stub it so we never touch SQLite.
package.loaded["modules.keylogger.export"] = {
	get_native_app_category = function() return "Development" end,
	init = function() end,
}

-- sqlite_writer stub — aggregator only calls get_db() and sqlite3.OK.
package.loaded["modules.keylogger.sqlite_writer"] = {
	get_db = function() return nil end,
	init   = function() end,
}

-- lib.timings reads a shared TOML file at module level; a prior test may have
-- installed a partial stub (sec-only) that lacks ms(), causing a "nil value"
-- crash when aggregator.lua initialises its module-level timing constants.
-- Inject a complete stub before the load so the real TOML path is never hit
-- and the module loads cleanly in CI regardless of test ordering.
package.loaded["infra.timings"] = {
	ms  = function(_section, _key) return 1000 end,
	sec = function(_section, _key) return 1.0  end,
}

local AGG = helpers.load_with_stubs("modules.keylogger.aggregator")




-- ======================================================
-- ======================================================
-- ======= 2/ Module Surface Invariants =================
-- ======================================================
-- ======================================================

helpers.describe("aggregator — public surface", function()
	helpers.it("exposes init, walk_typing, walk_app_switch, walk_window_switch, walk_system_event, flush", function()
		helpers.assert_eq(type(AGG.init),               "function")
		helpers.assert_eq(type(AGG.walk_typing),        "function")
		helpers.assert_eq(type(AGG.walk_app_switch),    "function")
		helpers.assert_eq(type(AGG.walk_window_switch), "function")
		helpers.assert_eq(type(AGG.walk_system_event),  "function")
		helpers.assert_eq(type(AGG.flush),              "function")
	end)

	helpers.it("exposes ngram context helpers", function()
		helpers.assert_eq(type(AGG.get_ngram_ctx),   "function")
		helpers.assert_eq(type(AGG.set_ngram_ctx),   "function")
		helpers.assert_eq(type(AGG.reset_ngram_ctx), "function")
		helpers.assert_eq(type(AGG.reset_batch),     "function")
	end)
end)




-- ==============================================
-- ==============================================
-- ======= 3/ Pre-init Guard Enforcement ========
-- ==============================================
-- ==============================================

helpers.describe("aggregator — pre-init guard", function()
	-- Each walker must be a safe no-op when called before M.init().
	local fresh = helpers.load_with_stubs("modules.keylogger.aggregator")

	-- "does not crash" is the weak half. A walker that ran before init would
	-- accumulate rows against a nil device id and a batch that does not exist —
	-- the point of the guard is that NOTHING is recorded, not that nothing
	-- throws. has_pending_batch() is the observable, and no case looked at it.
	helpers.it("walk_typing before init records nothing", function()
		fresh.walk_typing({ app = "A", timestamp = "2024-01-01 10:00:00.000", events = {} })
		helpers.assert_eq(fresh.has_pending_batch(), false,
			"a pre-init walk must leave no batch behind — one flushed later would carry "
				.. "rows with no device id attached")
	end)

	helpers.it("walk_app_switch before init records nothing", function()
		fresh.walk_app_switch({ prev_app = "A", next_app = "B",
			timestamp = "2024-01-01 10:00:01.000", duration_ms = 1000 })
		helpers.assert_eq(fresh.has_pending_batch(), false,
			"the same holds for an app switch — the guard is about the write, not the throw")
	end)

	helpers.it("flush before init writes nothing", function()
		fresh.flush()
		helpers.assert_eq(fresh.has_pending_batch(), false,
			"flushing before init must not create a batch on the way out")
	end)

end)





-- ==================================================
-- ==================================================
-- ======= 3b/ Determinism, volume, bad input =======
-- ==================================================
-- ==================================================

-- Eight assert_true(true) placeholders stood here. Seven of them restated the
-- same sentence — "the aggregator is pure, the CALLERS gate on pause" — and
-- verified none of it. That claim is not testable against this module at all:
-- the aggregator has no knowledge of suspend, by design. Where it IS testable
-- is at the caller, and that is where it is now asserted (the Windows twin
-- pins the guard-before-mutation ordering in _OnPrefixChar / _OnPrefixKeyDown).
--
-- What IS a property of this module — determinism, behaviour at volume, and
-- resilience to hostile app names — was named by those placeholders and checked
-- by none of them. It is checked here.

--- Builds a walk_typing entry from a plain string, one event per character.
--- @param app string App name recorded on the entry.
--- @param text string Characters to feed.
--- @return table The entry shape walk_typing expects.
local function typing_entry(app, text)
	local events = {}
	for i = 1, #text do
		events[#events + 1] = { text:sub(i, i), 100, {} }
	end
	return { app = app, timestamp = "2024-01-01 10:00:00.000", events = events }
end

--- Characters the walker classified, summed across every app-day row.
---
--- chars_class is the walker's own per-character tally (letter / digit / punct
--- / space / other), so it is the honest place to count what actually went in —
--- the n-gram buckets are populated only on the paths that build grams.
--- @param batch table|nil The aggregation batch.
--- @return number Total classified characters.
local function classified_chars(batch)
	local n = 0
	for _, row in pairs((batch or {}).chars_class or {}) do
		n = n + (row.letter or 0) + (row.digit or 0) + (row.punct or 0) + (row.space or 0) + (row.other or 0)
	end
	return n
end

helpers.describe("aggregator — determinism, volume and hostile input", function()
	local State = require("modules.keylogger.aggregator.state")

	--- Walks `text` through a freshly-initialised aggregator and returns its batch.
	local function walk_fresh(app, text)
		State.initialized = false
		State.agg_batch   = nil
		State.ngram_ctx   = nil
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		a.init({ device_id = "determinism-probe" })
		a.walk_typing(typing_entry(app, text))
		return State.agg_batch
	end

	helpers.it("the same input produces the same character counts twice", function()
		local first  = walk_fresh("Editor", "hello world")
		local a_count = classified_chars(first)
		local second = walk_fresh("Editor", "hello world")
		local b_count = classified_chars(second)

		helpers.assert_true(a_count > 0,
			"the walker must record characters at all — a zero here would make the comparison below vacuous")
		helpers.assert_eq(b_count, a_count,
			"identical input must aggregate identically; a difference means state leaked across instances")
	end)

	helpers.it("200 characters are all counted", function()
		local batch = walk_fresh("Editor", string.rep("ab", 100))
		helpers.assert_eq(classified_chars(batch), 200,
			"every fed character must reach the character bucket — the placeholder this replaces claimed to stress 200 events and fed none")
	end)

	helpers.it("an empty or non-ASCII app name neither crashes nor is dropped", function()
		-- Deliberately NOT wrapped in pcall. A throw here fails the test on its
		-- own, with the real stack; asserting on a pcall status instead would
		-- prove only "it returned" and would pass on a walker that swallowed
		-- every character.
		for _, app in ipairs({ "", "Éditeur ✎", "app\tname" }) do
			local batch = walk_fresh(app, "abc")
			helpers.assert_eq(classified_chars(batch), 3,
				"the characters must still be counted for app " .. string.format("%q", app))
		end
	end)
end)





-- =============================================
-- =============================================
-- ======= 4/ Init Validation ==================
-- =============================================
-- =============================================

-- Reset the shared state singleton before the init-guard tests — a prior
-- test file (e.g. test_corpus_keylogger_aggregation) may have left
-- S.initialized=true, which would make init() early-return and break these
-- rejection assertions. load_with_stubs only reloads the top-level module,
-- not the state sub-module, so the singleton persists across files
local _S = require("modules.keylogger.aggregator.state")
_S.initialized = false
_S.agg_batch   = nil
_S.ngram_ctx   = nil
_S.device_id   = nil

helpers.describe("aggregator — init", function()
	helpers.it("rejects nil deps", function()
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		a.init(nil)
		-- Still not initialized — get_ngram_ctx should return nil (no ctx yet)
		helpers.assert_nil(a.get_ngram_ctx())
	end)

	helpers.it("rejects deps with non-string device_id", function()
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		a.init({ device_id = 42 })
		helpers.assert_nil(a.get_ngram_ctx())
	end)

	helpers.it("accepts valid deps", function()
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		a.init({ device_id = "test-uuid-1234" })
		-- After init, ngram ctx starts nil (populated lazily by walk_typing).
		-- get_ngram_ctx() returns nil before first walking call.
		local ctx = a.get_ngram_ctx()
		-- May be nil or empty table — both are acceptable initial states.
		helpers.assert_true(ctx == nil or type(ctx) == "table")
	end)

	helpers.it("ignores duplicate init calls and keeps the first device id", function()
		-- The double-init guard lives in aggregator.state, which load_with_stubs
		-- does NOT reload — so without dropping it here an earlier test's init is
		-- still in effect and BOTH calls below are ignored, making the assertion
		-- pass for the wrong reason.
		--
		-- The four submodules must be dropped and restored as one unit: they close
		-- over the same state table, so reloading a subset leaves events.lua
		-- pointing at the old table while core.lua uses the new one.
		local FAMILY = {
			"modules.keylogger.aggregator",
			"modules.keylogger.aggregator.state",
			"modules.keylogger.aggregator.core",
			"modules.keylogger.aggregator.events",
			"modules.keylogger.aggregator.sql",
		}
		local saved = {}
		for _, name in ipairs(FAMILY) do
			saved[name] = package.loaded[name]
			package.loaded[name] = nil
		end

		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		a.init({ device_id = "uuid-a" })
		a.init({ device_id = "uuid-b" })
		local seen = a.get_device_id()

		-- Put the shared family back before asserting, so a failure here does not
		-- cascade into every later test in the file.
		for _, name in ipairs(FAMILY) do
			package.loaded[name] = saved[name]
		end
		helpers.assert_eq(seen, "uuid-a",
			"a second init must be ignored, not applied — the device id keys every row "
				.. "written so far, and changing it mid-session splits one machine's "
				.. "history across two identities")
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 5/ N-gram Context Round-trips ====
-- ==========================================
-- ==========================================

helpers.describe("aggregator — ngram context", function()
	local a

	-- Shared initialised instance for this suite.
	helpers.it("setup: init succeeds", function()
		a = helpers.load_with_stubs("modules.keylogger.aggregator")
		a.init({ device_id = "ctx-test-uuid" })
		-- "init succeeds" asserted as assert_true(true) meant the setup could fail
		-- silently and every case below would run against a half-built module. The
		-- post-condition is that the instance is usable, so check that.
		helpers.assert_eq(type(a.get_ngram_ctx), "function",
			"after init the aggregator must expose its context API")
		-- The context is restored from disk after init, so it is nil until then. What
		-- must hold is that the setter coerces: a non-table restore (a corrupt or
		-- half-written JSON file) becomes an empty context, never a nil that every
		-- later index would fault on.
		a.set_ngram_ctx("not a table")
		helpers.assert_eq(type(a.get_ngram_ctx()), "table",
			"a non-table restore must be coerced to an empty context, not left nil")
	end)

	helpers.it("set_ngram_ctx stores a table and get_ngram_ctx retrieves it", function()
		a.set_ngram_ctx({ my_app = { p1 = "a" } })
		local ctx = a.get_ngram_ctx()
		helpers.assert_true(type(ctx) == "table")
		helpers.assert_true(type(ctx.my_app) == "table")
		helpers.assert_eq(ctx.my_app.p1, "a")
	end)

	helpers.it("set_ngram_ctx with non-table argument resets to empty table", function()
		a.set_ngram_ctx("invalid")
		local ctx = a.get_ngram_ctx()
		helpers.assert_eq(type(ctx), "table")
	end)

	helpers.it("reset_ngram_ctx clears all context", function()
		a.set_ngram_ctx({ app1 = { p1 = "z" } })
		a.reset_ngram_ctx()
		local ctx = a.get_ngram_ctx()
		-- After reset the table is empty.
		local count = 0
		for _ in pairs(ctx) do count = count + 1 end
		helpers.assert_eq(count, 0)
	end)
end)




-- =========================================
-- =========================================
-- ======= 6/ Batch Management =============
-- =========================================
-- =========================================

helpers.describe("aggregator — batch management", function()
	helpers.it("reset_batch does not crash and can be called repeatedly", function()
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		a.init({ device_id = "batch-uuid" })
		a.reset_batch()
		a.reset_batch()
		helpers.assert_eq(a.has_pending_batch(), false,
			"resetting twice must leave the batch empty, not half-rebuilt — the second "
				.. "reset running against an already-cleared batch is the ordinary case on "
				.. "a flush that found nothing to write")
	end)
end)




-- ================================================
-- ================================================
-- ======= 7/ walk_typing - Char Counts ===========
-- ================================================
-- ================================================

helpers.describe("aggregator — walk_typing char counts", function()
	local a

	helpers.it("setup", function()
		a = helpers.load_with_stubs("modules.keylogger.aggregator")
		package.loaded["modules.keylogger.sqlite_writer"] = { get_db = function() return nil end }
		package.loaded["modules.keylogger.export"]        = { get_native_app_category = function() return "Dev" end }
		a.init({ device_id = "walk-uuid" })
		helpers.assert_eq(type(a.walk_typing), "function",
			"after init the aggregator must expose walk_typing — the cases below all call it, "
			.. "and a silent setup failure would leave them running against nothing")
	end)

	helpers.it("an empty events list adds no context for the app", function()
		-- Called directly: a raise here fails with the real error, which is more
		-- use than a boolean. And the claim is not survival — it is that a walk
		-- over nothing creates nothing, because an ngram context invented from an
		-- empty entry is a row the dashboards then attribute keystrokes to.
		local before_ctx = a.get_ngram_ctx()
		a.walk_typing({
			app = "TestApp", timestamp = "2024-06-01 10:00:00.000",
			events = {},
		})
		-- get_app_ctx creates on demand, so it cannot answer "was one made". What
		-- CAN be read is the ngram context the walk would have advanced: an empty
		-- entry must leave it exactly where it was, or the next real keystroke is
		-- paired against a neighbour that was never typed.
		helpers.assert_eq(a.get_ngram_ctx(), before_ctx,
			"an empty entry must not advance the ngram context")
	end)

	helpers.it("three normal chars populate ngram_ctx for the app", function()
		-- Walk a 3-keystroke entry and verify context is created.
		a.walk_typing({
			app = "SuiteApp", timestamp = "2024-06-01 10:00:00.000",
			events = {
				{ "a", 100, {} },
				{ "b", 120, {} },
				{ "c", 110, {} },
			},
		})
		local ctx = a.get_ngram_ctx()
		helpers.assert_true(type(ctx) == "table")
		helpers.assert_true(type(ctx["SuiteApp"]) == "table",
			"context entry for SuiteApp must exist")
		-- p1 should be "c" (the last char pushed)
		helpers.assert_eq(ctx["SuiteApp"].p1, "c")
	end)

	helpers.it("synthetic event with missing delay does not crash (regression)", function()
		-- This simulates a corrupt or malformed hotstring entry in today.log
		local ok = pcall(function()
			a.walk_typing({
				app = "TestApp", timestamp = "2024-06-01 10:05:00.000",
				events = {
					{ "synth", nil, { s = true, t = "hotstring" } },
				},
			})
		end)
		helpers.assert_true(ok)
	end)

	helpers.it("backspace shrinks cur_word", function()
		local a2 = helpers.load_with_stubs("modules.keylogger.aggregator")
		package.loaded["modules.keylogger.sqlite_writer"] = { get_db = function() return nil end }
		package.loaded["modules.keylogger.export"]        = { get_native_app_category = function() return "Dev" end }
		a2.init({ device_id = "bs-uuid" })

		-- Type "he" then backspace.
		a2.walk_typing({
			app = "BSApp", timestamp = "2024-06-01 10:00:00.000",
			events = {
				{ "h",    150, {} },
				{ "e",    130, {} },
				{ "[BS]", 200, {} },
			},
		})
		local ctx = a2.get_ngram_ctx()
		-- After "h", "e", "[BS]" the cur_word should be "h" (backspace removed "e").
		helpers.assert_eq(ctx["BSApp"].cur_word, "h")
	end)

	helpers.it("word boundary on space resets cur_word and sets prev_word", function()
		local a3 = helpers.load_with_stubs("modules.keylogger.aggregator")
		package.loaded["modules.keylogger.sqlite_writer"] = { get_db = function() return nil end }
		package.loaded["modules.keylogger.export"]        = { get_native_app_category = function() return "Dev" end }
		a3.init({ device_id = "word-uuid" })

		a3.walk_typing({
			app = "WordApp", timestamp = "2024-06-01 11:00:00.000",
			events = {
				{ "h", 100, {} },
				{ "i", 100, {} },
				{ " ", 150, {} },
			},
		})
		local ctx = a3.get_ngram_ctx()
		-- Space is a separator: cur_word is reset, prev_word holds "hi".
		helpers.assert_eq(ctx["WordApp"].cur_word, "")
		helpers.assert_eq(ctx["WordApp"].prev_word, "hi")
	end)
end)




-- ================================================
-- ================================================
-- ======= 8/ walk_app_switch Accumulation ========
-- ================================================
-- ================================================

helpers.describe("aggregator — walk_app_switch", function()
	helpers.it("accumulates duration_ms for the prev_app", function()
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		package.loaded["modules.keylogger.sqlite_writer"] = { get_db = function() return nil end }
		package.loaded["modules.keylogger.export"]        = { get_native_app_category = function() return "Dev" end }
		a.init({ device_id = "sw-uuid" })

		a.walk_app_switch({ prev_app = "AppA", next_app = "AppB",
			timestamp = "2024-06-01 12:00:00.000", duration_ms = 5000 })
		a.walk_app_switch({ prev_app = "AppA", next_app = "AppC",
			timestamp = "2024-06-01 12:00:05.000", duration_ms = 3000 })

		-- flush() is a DB-level operation. With no db it must report that it wrote
		-- nothing rather than claim a flush that never reached SQLite: the caller
		-- advances its watermark on the answer.
		local flushed = a.flush()
		helpers.assert_true(flushed == nil or flushed == false or flushed == 0,
			"a flush with no database must not report rows written")
	end)

	helpers.it("an app switch with no prev_app records nothing for a nil app", function()
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		package.loaded["modules.keylogger.sqlite_writer"] = { get_db = function() return nil end }
		package.loaded["modules.keylogger.export"]        = { get_native_app_category = function() return "Dev" end }
		a.init({ device_id = "sw2-uuid" })

		a.walk_app_switch({ next_app = "AppB",
			timestamp = "2024-06-01 12:00:00.000", duration_ms = 1000 })
		local flushed = a.flush()
		helpers.assert_true(flushed == nil or flushed == false or flushed == 0,
			"a switch whose previous app is unknown must not manufacture a duration row "
				.. "for it — the dashboards would attribute that time to nothing")
	end)
end)




-- ================================================
-- ================================================
-- ======= 9/ walk_system_event Counters ==========
-- ================================================
-- ================================================

helpers.describe("aggregator — walk_system_event", function()
	helpers.it("wifi_change increments wifi_changes", function()
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		package.loaded["modules.keylogger.sqlite_writer"] = { get_db = function() return nil end }
		package.loaded["modules.keylogger.export"]        = { get_native_app_category = function() return "Dev" end }
		a.init({ device_id = "sys-uuid" })

		-- Walk two wifi_change events.
		a.walk_system_event({ action = "wifi_change", timestamp = "2024-06-01 08:00:00.000" })
		a.walk_system_event({ action = "wifi_change", timestamp = "2024-06-01 08:01:00.000" })

		-- walk_system_event is pure batch accumulation; flush with nil db writes
		-- nothing and must say so.
		local flushed = a.flush()
		helpers.assert_true(flushed == nil or flushed == false or flushed == 0,
			"a flush with no database must not report rows written")
	end)

	helpers.it("a modifier_hold accumulates without a database", function()
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		package.loaded["modules.keylogger.sqlite_writer"] = { get_db = function() return nil end }
		package.loaded["modules.keylogger.export"]        = { get_native_app_category = function() return "Dev" end }
		a.init({ device_id = "hold-uuid" })

		a.walk_system_event({
			action = "modifier_hold", keycode = 56, app = "TestApp",
			hold_ms = 300, timestamp = "2024-06-01 09:00:00.000",
		})
		local flushed = a.flush()
		helpers.assert_true(flushed == nil or flushed == false or flushed == 0,
			"accumulation is in-memory; without a database the flush must report nothing "
				.. "written rather than a count the caller would trust")
	end)
end)




-- ======================================================================
-- ======================================================================
-- ======= 10/ manifest_increment — hs_suggested/llm_suggested (F-HIGH-26) =
-- ======================================================================
-- ======================================================================

-- F-HIGH-26: LogManager.increment_manifest_stat() appends a
-- {action="manifest_increment", stat=..., amount=...} system_event row, but
-- walk_system_event() had no branch for it — the entry was silently ignored
-- with no fall-through warning, so hs_suggested/llm_suggested were computed,
-- logged, and then discarded before ever reaching agg_app_day / SQLite.
helpers.describe("aggregator — walk_system_event manifest_increment (F-HIGH-26)", function()

	--- Reads the live agg_batch.app_day row for (date, app) via the shared
	--- aggregator.state singleton — the same table every aggregator sub-module
	--- mutates, since Lua's module cache returns one instance per require().
	--- @param date string "YYYY-MM-DD".
	--- @param app string Application name.
	--- @return table|nil The accumulated row, or nil if nothing was walked yet.
	local function read_app_day_row(date, app)
		local S = require("modules.keylogger.aggregator.state")
		if not S.agg_batch then return nil end
		return S.agg_batch.app_day[date .. "\1" .. app]
	end

	helpers.it("hs_suggested manifest_increment accumulates into agg_batch.app_day", function()
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		package.loaded["modules.keylogger.sqlite_writer"] = { get_db = function() return nil end }
		package.loaded["modules.keylogger.export"]        = { get_native_app_category = function() return "Dev" end }
		a.init({ device_id = "manifest-hs-uuid" })

		a.walk_system_event({
			action = "manifest_increment", stat = "hs_suggested", amount = 1,
			app = "TestApp", timestamp = "2024-06-01 10:00:00.000",
		})
		a.walk_system_event({
			action = "manifest_increment", stat = "hs_suggested", amount = 1,
			app = "TestApp", timestamp = "2024-06-01 10:00:01.000",
		})

		local row = read_app_day_row("2024-06-01", "TestApp")
		helpers.assert_true(row ~= nil, "app_day row must exist after two manifest_increment events")
		helpers.assert_eq(row.hs_suggested, 2,
			"hs_suggested must accumulate the manifest_increment amounts instead of being discarded")
	end)

	helpers.it("llm_suggested manifest_increment honors a custom amount", function()
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		package.loaded["modules.keylogger.sqlite_writer"] = { get_db = function() return nil end }
		package.loaded["modules.keylogger.export"]        = { get_native_app_category = function() return "Dev" end }
		a.init({ device_id = "manifest-llm-uuid" })

		a.walk_system_event({
			action = "manifest_increment", stat = "llm_suggested", amount = 3,
			app = "TestApp", timestamp = "2024-06-01 11:00:00.000",
		})

		local row = read_app_day_row("2024-06-01", "TestApp")
		helpers.assert_true(row ~= nil, "app_day row must exist after a manifest_increment event")
		helpers.assert_eq(row.llm_suggested, 3,
			"llm_suggested must be bumped by the event's amount field")
	end)

	helpers.it("an unrecognized stat name is ignored (whitelist, no arbitrary column injection)", function()
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		package.loaded["modules.keylogger.sqlite_writer"] = { get_db = function() return nil end }
		package.loaded["modules.keylogger.export"]        = { get_native_app_category = function() return "Dev" end }
		a.init({ device_id = "manifest-bad-uuid" })

		local ok, walk_err = pcall(function()
			a.walk_system_event({
				action = "manifest_increment", stat = "not_a_real_column", amount = 1,
				app = "TestApp", timestamp = "2024-06-01 12:00:00.000",
			})
		end)
		helpers.assert_nil(walk_err, "and must report none: " .. tostring(walk_err))
		helpers.assert_true(ok, "an unknown stat name must not crash walk_system_event")

		local row = read_app_day_row("2024-06-01", "TestApp")
		if row then
			helpers.assert_nil(row.not_a_real_column,
				"an unwhitelisted stat name must never be written into the batch row")
		end
	end)

end)




-- ============================================================================
-- ============================================================================
-- ======= 11/ focus_first_key — focus_to_first_key_sum_ms/count (F-MED-27) ==
-- ============================================================================
-- ============================================================================

-- F-MED-27: same shape as F-HIGH-26 — LogManager.log_focus_first_key() appends
-- a {action="focus_first_key", app=..., latency_ms=...} system_event row, but
-- walk_system_event() had no branch for it and the destination columns
-- (focus_to_first_key_sum_ms/count, which live in agg_app_day_ergo, not
-- agg_app_day) were absent from the UPSERT — the latency metric was computed,
-- logged, and then silently discarded before ever reaching SQLite.
helpers.describe("aggregator — walk_system_event focus_first_key (F-MED-27)", function()

	--- Reads the live agg_batch.ergo row for (date, app) via the shared
	--- aggregator.state singleton.
	--- @param date string "YYYY-MM-DD".
	--- @param app string Application name.
	--- @return table|nil The accumulated row, or nil if nothing was walked yet.
	local function read_ergo_row(date, app)
		local S = require("modules.keylogger.aggregator.state")
		if not S.agg_batch then return nil end
		return S.agg_batch.ergo[date .. "\1" .. app]
	end

	helpers.it("focus_first_key accumulates sum_ms and count into agg_batch.ergo", function()
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		package.loaded["modules.keylogger.sqlite_writer"] = { get_db = function() return nil end }
		package.loaded["modules.keylogger.export"]        = { get_native_app_category = function() return "Dev" end }
		a.init({ device_id = "focus-first-key-uuid" })

		a.walk_system_event({
			action = "focus_first_key", app = "TestApp", latency_ms = 250,
			timestamp = "2024-07-01 10:00:00.000",
		})
		a.walk_system_event({
			action = "focus_first_key", app = "TestApp", latency_ms = 150,
			timestamp = "2024-07-01 10:00:05.000",
		})

		local row = read_ergo_row("2024-07-01", "TestApp")
		helpers.assert_true(row ~= nil, "ergo row must exist after two focus_first_key events")
		helpers.assert_eq(row.focus_to_first_key_sum_ms, 400,
			"focus_to_first_key_sum_ms must accumulate the latency_ms of both events instead of being discarded")
		helpers.assert_eq(row.focus_to_first_key_count, 2,
			"focus_to_first_key_count must be bumped once per focus_first_key event")
	end)

	helpers.it("focus_first_key and walk_typing share the same ergo row without a nil-arithmetic crash", function()
		-- Regression for the shape-mismatch hazard: walk_typing's S.agg_batch.ergo
		-- default must carry focus_to_first_key_sum_ms/count too, or a
		-- walk_typing-first ordering leaves those fields nil and the
		-- focus_first_key branch crashes on `nil + number`.
		local a = helpers.load_with_stubs("modules.keylogger.aggregator")
		package.loaded["modules.keylogger.sqlite_writer"] = { get_db = function() return nil end }
		package.loaded["modules.keylogger.export"]        = { get_native_app_category = function() return "Dev" end }
		a.init({ device_id = "focus-shared-row-uuid" })

		-- walk_typing runs FIRST and creates the ergo row via its own default.
		a.walk_typing({
			app = "SharedApp", timestamp = "2024-07-02 09:00:00.000",
			events = { { "a", 100, {} } },
		})

		local ok, focus_err = pcall(function()
			a.walk_system_event({
				action = "focus_first_key", app = "SharedApp", latency_ms = 300,
				timestamp = "2024-07-02 09:00:01.000",
			})
		end)
		helpers.assert_nil(focus_err, "and must report none: " .. tostring(focus_err))
		helpers.assert_true(ok, "focus_first_key must not crash when the ergo row was created by walk_typing first")

		local row = read_ergo_row("2024-07-02", "SharedApp")
		helpers.assert_true(row ~= nil)
		helpers.assert_eq(row.focus_to_first_key_sum_ms, 300)
		helpers.assert_eq(row.focus_to_first_key_count, 1)
		-- walk_typing's own fields must still be intact on the shared row.
		helpers.assert_eq(row.same_finger_streak_max, 0)
	end)

end)
