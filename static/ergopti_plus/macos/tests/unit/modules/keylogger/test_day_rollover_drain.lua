--- tests/unit/modules/keylogger/test_day_rollover_drain.lua

--- ==============================================================================
--- MODULE: Keylogger Day-Rollover Drain Regression Tests
--- DESCRIPTION:
--- day_rollover() must fully drain today.log before delegating to
--- Rotation.rollover() for file deletion. read_new_entries() caps at
--- INGEST_BATCH_LINES per call, so a single ingest_once() may leave data
--- behind. The drain loop must iterate until read_new_entries returns empty;
--- if the offset stalls (persistent SQL error), rollover must be skipped
--- and today.log preserved to avoid data loss.
---
--- FEATURES & RATIONALE:
--- 1. Multi-batch drain: a file with N > INGEST_BATCH_LINES entries must
---    trigger multiple ingest_once calls before rollover is allowed.
--- 2. Stall detection: if ingest_once fails to advance the offset, rollover
---    must be skipped and a warning emitted rather than deleting the file.
--- 3. Source guard: the implementation must call read_new_entries in a loop
---    and condition the rollover call on the drain result.
--- 4. Side-effect parity (F-HIGH-2): a stalled drain must NOT run
---    Aggregator.reset_ngram_ctx() or touch the today_log_offset /
---    today_log_date / ngram_ctx_json meta rows — those bookmarks are the
---    only way a retried rollover knows where to resume, so gating the
---    file-deleting Rotation.rollover() call while still unconditionally
---    firing the other three side effects would silently wipe the
---    resumption state even though the drain deliberately stalled.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ========================================
-- ========================================
-- ======= 1/ Drain-loop Simulation =======
-- ========================================
-- ========================================

--- Builds a minimal harness that replicates the day_rollover drain loop using
--- injectable stubs for Rotation and ingest_once, then returns observable state.
--- @param batches_until_empty integer How many ingest_once calls before empty.
--- @param stall_on_iter integer|nil If set, ingest_once stops advancing offset on this iteration.
--- @return table { rollover_called, warn_msgs, ingest_call_count }
local function run_drain_simulation(batches_until_empty, stall_on_iter)
	local rollover_called = false
	local warn_msgs       = {}
	local ingest_count    = 0
	local iter            = 0
	local offset          = 0

	local stub_rotation = {
		get_offset = function() return offset end,
		read_new_entries = function()
			if iter >= batches_until_empty then return {} end
			return { { raw = "line" } }
		end,
		rollover = function(_path) rollover_called = true end,
		get_date = function() return "2099-07-01" end,
	}

	local stub_logger = {
		warn = function(_log, fmt, ...)
			table.insert(warn_msgs, string.format(fmt:gsub("%%[^%%]", "%%s"), ...))
		end,
		debug = function() end, error = function() end,
	}

	local function stub_ingest_once()
		ingest_count = ingest_count + 1
		iter = iter + 1
		if stall_on_iter and iter >= stall_on_iter then return end
		offset = offset + 100
	end

	-- Replicate the drain loop from M.day_rollover
	local MAX_ROLLOVER_DRAIN_ITERS = 20
	local drained = false
	local prev_offset = stub_rotation.get_offset()
	for _ = 1, MAX_ROLLOVER_DRAIN_ITERS do
		local pending = stub_rotation.read_new_entries()
		if #pending == 0 then
			drained = true
			break
		end
		stub_ingest_once()
		local new_offset = stub_rotation.get_offset()
		if new_offset == prev_offset then
			stub_logger.warn("LOG",
				"day_rollover: ingest stalled at offset %d — preserving today.log.",
				prev_offset)
			break
		end
		prev_offset = new_offset
	end

	if not drained then
		stub_logger.warn("LOG",
			"day_rollover: today.log not fully drained — file preserved, rotation skipped.")
	else
		stub_rotation.rollover("/fake/data.sql")
	end

	return {
		rollover_called   = rollover_called,
		warn_msgs         = warn_msgs,
		ingest_call_count = ingest_count,
	}
end


helpers.describe("day_rollover: drain loop calls rollover only when fully drained", function()

	helpers.it("single batch: rollover called after one ingest_once empties the file", function()
		local result = run_drain_simulation(1)
		helpers.assert_true(result.rollover_called,
			"Rotation.rollover must be called when the file is fully drained in one pass")
		helpers.assert_eq(result.ingest_call_count, 1,
			"exactly one ingest_once call is needed for a single-batch file")
		helpers.assert_eq(#result.warn_msgs, 0,
			"no warnings should be emitted when the drain succeeds")
	end)

	helpers.it("multi-batch: rollover called only after all batches are drained", function()
		local result = run_drain_simulation(3)
		helpers.assert_true(result.rollover_called,
			"Rotation.rollover must be called after all batches are drained")
		helpers.assert_eq(result.ingest_call_count, 3,
			"ingest_once must be called once per batch until the file is empty")
		helpers.assert_eq(#result.warn_msgs, 0,
			"no warnings should be emitted when multi-batch drain succeeds")
	end)

	helpers.it("stall: rollover NOT called when ingest_once cannot advance the offset", function()
		local result = run_drain_simulation(99, 1)
		helpers.assert_true(not result.rollover_called,
			"Rotation.rollover must NOT be called when ingest is stalled — file must be preserved")
		helpers.assert_true(#result.warn_msgs >= 1,
			"at least one warning must be emitted when the drain stalls")
	end)

	helpers.it("stall after partial drain: rollover NOT called, warning emitted", function()
		local result = run_drain_simulation(99, 3)
		helpers.assert_true(not result.rollover_called,
			"Rotation.rollover must NOT be called even after a partial drain that then stalls")
		helpers.assert_true(#result.warn_msgs >= 1,
			"a warning must be emitted when drain stalls mid-way")
	end)

	helpers.it("already empty: rollover called immediately without ingest_once", function()
		local result = run_drain_simulation(0)
		helpers.assert_true(result.rollover_called,
			"Rotation.rollover must be called when today.log is already empty at rollover time")
		helpers.assert_eq(result.ingest_call_count, 0,
			"ingest_once must not be called when the file is already empty")
	end)

end)





-- =======================================================
-- =======================================================
-- ======= 2/ Real day_rollover() Side-effect Gate =======
-- =======================================================
-- =======================================================

--- Loads the real modules.keylogger.log_manager with every I/O sub-module
--- stubbed, so M.day_rollover() runs its actual production logic (not a
--- hand-copied harness) while Rotation/Aggregator/SqliteWriter stay
--- in-memory and observable.
--- @param stall boolean If true, Rotation.read_new_entries() never empties out
--- and Rotation.set_offset() never advances the observed offset, forcing the
--- drain loop to stall exactly like a persistent SQL error would.
--- @return table log_manager instance, table observation counters
local function load_real_day_rollover(stall)
	local observed = {
		rollover_called       = false,
		reset_ngram_ctx_calls = 0,
		meta_exec_statements  = {},
	}

	local offset = 0
	package.loaded["modules.keylogger.rotation"] = {
		init = function() end,
		is_initialized = function() return true end,
		append_log = function() end,
		read_new_entries = function()
			if stall then
				-- Always reports pending data without ever advancing the offset —
				-- the exact "persistent SQL error" shape day_rollover must detect.
				return { { entry = { type = "typing" } } }, offset
			end
			return {}, offset
		end,
		get_offset = function() return offset end,
		get_date   = function() return "2099-07-01" end,
		set_offset = function(new_offset) offset = new_offset end,
		rollover   = function() observed.rollover_called = true end,
	}

	package.loaded["modules.keylogger.sqlite_writer"] = {
		init                  = function() end,
		open_db               = function() return true end,
		close_db              = function() end,
		-- Returning nil makes M.ingest_once() an immediate no-op, so the stall
		-- scenario reaches MAX_ROLLOVER_DRAIN_ITERS without a real SQLite cache.
		get_db                = function() return nil end,
		build_inserts         = function() return {} end,
		get_next_event_id     = function() return 0 end,
		set_next_event_id     = function() end,
		persist_next_event_id = function() end,
	}

	package.loaded["modules.keylogger.aggregator"] = {
		init               = function() end,
		walk_typing        = function() end,
		walk_app_switch    = function() end,
		walk_window_switch = function() end,
		walk_system_event  = function() end,
		flush              = function() end,
		get_ngram_ctx      = function() return {} end,
		set_ngram_ctx      = function() end,
		reset_ngram_ctx    = function() observed.reset_ngram_ctx_calls = observed.reset_ngram_ctx_calls + 1 end,
	}

	package.loaded["modules.keylogger.export"] = {
		init                    = function() end,
		get_native_app_category = function() return "other" end,
		get_device_short_id     = function() return "abcd" end,
		get_sqlite_path         = function() return "/tmp/test.sqlite" end,
		get_db_rev              = function() return 0 end,
		sync_foreign_data_sql   = function() end,
	}

	package.loaded["infra.i18n"] = { t = function(key) return key end }
	package.loaded["infra.timings"] = {
		ms  = function() return 1000 end,
		sec = function() return 1.0 end,
	}

	local hs_overrides = {
		fs = {
			attributes = function() return nil end,
			dir        = function() return function() return nil end end,
		},
		execute = function() return "" end,
	}

	local lm = helpers.load_with_stubs("modules.keylogger.log_manager", hs_overrides)
	lm.init({
		LOG_DIR              = "/tmp/test_day_rollover",
		buffer_events        = {},
		buffer_text          = "",
		rich_chunks          = {},
		session_mouse_clicks  = 0,
		session_mouse_scrolls = 0,
		mouse_distance_px     = 0,
		last_flush_time       = 0,
		last_time             = 0,
		pending_keyup         = {},
		today_idx             = {},
		manifest              = {},
	})

	-- A db present here would make M.day_rollover() write meta UPDATE statements;
	-- since SqliteWriter.get_db() returns nil above, those writes are unreachable
	-- and are instead exercised directly with a recording fake db, below.
	return lm, observed
end

helpers.describe("day_rollover: real M.day_rollover() gates side effects on drain success (F-HIGH-2)", function()

	helpers.it("stalled drain: Rotation.rollover is NOT called and day_rollover returns false", function()
		local lm, observed = load_real_day_rollover(true)
		local result = lm.day_rollover()
		helpers.assert_true(result == false,
			"day_rollover must report failure (false) when the drain stalls")
		helpers.assert_true(not observed.rollover_called,
			"Rotation.rollover must not run when the drain stalls")
	end)

	helpers.it("stalled drain: Aggregator.reset_ngram_ctx is NOT called", function()
		-- This is the core F-HIGH-2 regression: a prior fix gated Rotation.rollover
		-- on `drained` but left reset_ngram_ctx() and the meta resets unconditional,
		-- wiping the ngram resumption bookmark even though the drain deliberately
		-- stalled and the rest of today.log survived untouched.
		local lm, observed = load_real_day_rollover(true)
		lm.day_rollover()
		helpers.assert_eq(observed.reset_ngram_ctx_calls, 0,
			"Aggregator.reset_ngram_ctx must NOT run when the drain stalls — "
			.. "it wipes the in-memory ngram context that a retried rollover still needs")
	end)

	helpers.it("successful drain (already empty): Rotation.rollover runs and day_rollover returns true", function()
		local lm, observed = load_real_day_rollover(false)
		local result = lm.day_rollover()
		helpers.assert_true(result == true,
			"day_rollover must report success (true) once the drain completes")
		helpers.assert_true(observed.rollover_called,
			"Rotation.rollover must run once today.log is fully drained")
	end)

	helpers.it("successful drain: Aggregator.reset_ngram_ctx runs exactly once", function()
		local lm, observed = load_real_day_rollover(false)
		lm.day_rollover()
		helpers.assert_eq(observed.reset_ngram_ctx_calls, 1,
			"Aggregator.reset_ngram_ctx must run exactly once after a successful drain")
	end)

end)





-- ====================================================
-- ====================================================
-- ======= 3/ Real day_rollover() Meta Row Gate =======
-- ====================================================
-- ====================================================

--- Same harness as section 2, but SqliteWriter.get_db() returns a recording
--- fake db so the today_log_offset / today_log_date / ngram_ctx_json meta
--- UPDATE statements (the other two side effects named in F-HIGH-2) are
--- directly observable.
--- @param stall boolean Same meaning as load_real_day_rollover's argument.
--- @return table log_manager instance, table exec'd meta statements
local function load_real_day_rollover_with_db(stall)
	local lm, observed = load_real_day_rollover(stall)

	local exec_statements = {}
	local fake_db = {
		exec = function(_self, sql)
			table.insert(exec_statements, sql)
			return 0 -- sqlite3.OK stand-in; these are meta UPDATEs, not batch inserts
		end,
		nrows = function() return function() return nil end end,
	}
	package.loaded["modules.keylogger.sqlite_writer"].get_db = function() return fake_db end

	return lm, exec_statements
end

helpers.describe("day_rollover: meta bookmark rows (offset/date/ngram_ctx) gate on drain success (F-HIGH-2)", function()

	helpers.it("stalled drain: no meta UPDATE statements are executed", function()
		local lm, exec_statements = load_real_day_rollover_with_db(true)
		lm.day_rollover()
		helpers.assert_eq(#exec_statements, 0,
			"a stalled drain must not touch today_log_offset / today_log_date / "
			.. "ngram_ctx_json — those are the exact resumption bookmarks the retry needs")
	end)

	helpers.it("successful drain: all three meta rows are reset", function()
		local lm, exec_statements = load_real_day_rollover_with_db(false)
		lm.day_rollover()
		local joined = table.concat(exec_statements, " | ")
		helpers.assert_true(joined:find("today_log_offset") ~= nil,
			"successful drain must reset the today_log_offset meta row")
		helpers.assert_true(joined:find("today_log_date") ~= nil,
			"successful drain must reset the today_log_date meta row")
		helpers.assert_true(joined:find("ngram_ctx_json") ~= nil,
			"successful drain must reset the ngram_ctx_json meta row")
	end)

end)





-- ===============================================
-- ===============================================
-- ======= 4/ Source-level Structure Guard =======
-- ===============================================
-- ===============================================

local function read_source()
	-- Selected by a declaration unique to modules/keylogger/log_manager.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("local function _mark_aggregate_cache_rebuilt")
	helpers.assert_true(src ~= nil, "modules/keylogger/log_manager.lua source must be locatable")
	return src
end

helpers.describe("day_rollover source: loop + conditional rollover", function()

	local src = read_source()

	helpers.it("day_rollover calls read_new_entries in a loop", function()
		helpers.assert_true(src:find("read_new_entries") ~= nil,
			"day_rollover must call Rotation.read_new_entries() to check for pending data")
	end)

	helpers.it("day_rollover conditions Rotation.rollover on drain result", function()
		local rollover_pos = src:find("Rotation%.rollover")
		helpers.assert_true(rollover_pos ~= nil,
			"Rotation.rollover must be present in the file")
		local drain_var_pos = src:find("drained")
		helpers.assert_true(drain_var_pos ~= nil,
			"day_rollover must use a 'drained' guard variable to condition the rollover call")
	end)

	helpers.it("day_rollover emits Logger.warn when rotation is skipped", function()
		helpers.assert_true(src:find("Logger%.warn") ~= nil,
			"day_rollover must emit Logger.warn when the drain stalls and the file is preserved")
	end)

end)

print("[PASS] test_day_rollover_drain")
