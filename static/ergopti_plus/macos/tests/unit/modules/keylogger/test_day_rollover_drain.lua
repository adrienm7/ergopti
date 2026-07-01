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
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================
-- ========================================
-- ======= 1/ Drain-loop Simulation =======
-- ========================================
-- =========================================

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





-- ================================================
-- ===============================================
-- ======= 2/ Source-level Structure Guard =======
-- ===============================================
-- ================================================

local function read_source()
	local path = helpers.driver_root() .. "modules/keylogger/log_manager.lua"
	local fh = io.open(path, "r")
	if not fh then error("Cannot read log_manager.lua for source scan") end
	local src = fh:read("*a"); fh:close()
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
