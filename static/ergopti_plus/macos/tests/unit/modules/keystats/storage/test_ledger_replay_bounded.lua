-- tests/unit/modules/keystats/storage/test_ledger_replay_bounded.lua

--- ==============================================================================
--- MODULE: Regression - a fresh cache replays the ledger in bounded steps (L64)
--- DESCRIPTION:
--- After a Mac reboot emptied TMPDIR, the keystats start read the whole 320 MB
--- data.sql into one string, scanned it and executed it in one call: the
--- deferred start held the main thread 138 s. The replay now runs in steps that
--- each apply complete batches of at most one read block past the budget, and
--- its persisted state resumes an interrupted replay at the last batch. The
--- applied SQL and the today.log cursor must equal one pass over the ledger.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")
local Export = helpers.load_with_stubs("modules.keystats.export")
package.loaded["modules.keystats.ledger_replay"] = nil
local LedgerReplay = require("modules.keystats.ledger_replay")

--- The cursor function of the log manager, through its test seam.
local function cursor_function()
	local saved = package.loaded["modules.keystats.log_manager"]
	package.loaded["modules.keystats.log_manager"] = nil
	local LM = helpers.load_with_stubs("modules.keystats.log_manager", {
		fs = { attributes = function() return nil end, dir = function() return function() return nil end end },
		execute = function() return "" end,
	})
	package.loaded["modules.keystats.log_manager"] = saved
	return LM._local_ledger_replay_cursor
end

--- Builds a synthetic ledger of `batches` batches with literal traps.
--- @param batches integer Batch count.
--- @param tail string Bytes appended after the last complete batch.
--- @return string ledger
local function synthetic_ledger(batches, tail)
	local parts = { "-- ergopti metrics — device test — schema_version 1\nPRAGMA foreign_keys=OFF;\n" }
	local offset = 0
	for index = 1, batches do
		if index % 400 == 0 then
			parts[#parts + 1] = string.format("\n-- === day rollover 2026-10-%02d -> 2026-10-%02d ===\n",
				index // 400, index // 400 + 1)
			offset = 0
		end
		local next_offset = offset + 100 + index % 7
		parts[#parts + 1] = string.format(
			"\n-- === ingest batch 2026-10-%02d 10:00:00.000 (offset %d -> %d, 1 entry(ies)) ===\n"
				.. "BEGIN TRANSACTION;\n"
				.. "INSERT OR IGNORE INTO events_typing VALUES ('device', %d, 'it''s -- not a comment\nCOMMIT;\n inside a literal %s');\n"
				.. "COMMIT;\n",
			index // 400 + 1, offset, next_offset, index, string.rep("x", index % 300))
		offset = next_offset
	end
	parts[#parts + 1] = tail
	return table.concat(parts)
end

--- Writes `content` to a fresh temporary file.
local function temp_file(content)
	local path = os.tmpname()
	local file = assert(io.open(path, "wb"))
	assert(file:write(content)); assert(file:close())
	return path
end

-- Allocation one step may make, in read blocks: the block, the carried
-- buffer and the applied slice. Reading the whole ledger, the L64 defect, is
-- dozens of blocks for the synthetic ledger and hundreds of MB in the field.
local STEP_ALLOCATION_BLOCKS = 6

--- Runs a replay to completion, rebuilding the state from its JSON form at
--- every step like a restart that resumes it.
---
--- Each step is measured on its own work. The garbage earlier test modules
--- left behind is collected before the step, and the collector is paused
--- during it: in a full suite a cycle over 40 MB of foreign garbage finished
--- inside one step and was charged to it (14 ms measured in the modules group,
--- 71 ms in one full single-process run, against about 0.5 ms of replay work).
--- The step's own share of collection work is bounded instead by its
--- allocation, measured over the same paused window.
local function run_replay(path, size, options)
	local applied, steps, max_cpu_ms, max_step_bytes, max_step_kb = {}, 0, 0, 0, 0
	local json = require("json")
	local state = LedgerReplay.new_state()
	while true do
		local before = state.offset
		collectgarbage("collect")
		collectgarbage("stop")
		local heap_kb = collectgarbage("count")
		local cpu = os.clock()
		local status, detail = LedgerReplay.step({
			path = path, size = size, state = state, cursor = options.cursor,
			exec = function(sql) applied[#applied + 1] = sql; return true end,
			-- Every deadline is already past: each step must stop at the first block
			-- that applied a batch, the worst case for the main-thread hold.
			clock = function() return 1 end, deadline = 0,
		})
		max_cpu_ms = math.max(max_cpu_ms, (os.clock() - cpu) * 1000)
		max_step_kb = math.max(max_step_kb, collectgarbage("count") - heap_kb)
		collectgarbage("restart")
		steps = steps + 1
		max_step_bytes = math.max(max_step_bytes, state.offset - before)
		if status ~= "more" then
			return status, detail, table.concat(applied), steps, max_cpu_ms, max_step_bytes, max_step_kb
		end
		if options.restart_each_step then state = json.decode(json.encode(state)) end
	end
end

helpers.describe("keystats: bounded local ledger replay (L64)", function()
	local cursor = cursor_function()
	local ledger = synthetic_ledger(6000, "\n-- === ingest batch 2026-10-16 10:00:00.000 (offset 0 -> 9, 1 entry(ies)) ===\n"
		.. "BEGIN TRANSACTION;\nINSERT OR IGNORE INTO events_typing VALUES ('device', 99999, 'torn');\n")
	local path = temp_file(ledger)
	local complete = Export._last_complete_batch_offset(ledger)

	helpers.it("applies exactly the complete batches and computes the one-pass cursor", function()
		local status, got, sql, steps = run_replay(path, #ledger, { cursor = cursor })
		helpers.assert_eq(status, "done")
		helpers.assert_true(steps > 10, "a " .. #ledger .. "-byte ledger must take many steps, took " .. steps)
		helpers.assert_true(sql == ledger:sub(1, complete), "the replay must apply exactly the complete batches")
		local want = cursor(ledger, complete)
		helpers.assert_eq(got.offset, want.offset, "today.log cursor offset")
		helpers.assert_eq(got.date, want.date, "today.log cursor date")
	end)

	helpers.it("keeps every step to one read block of work", function()
		local _, _, _, _, max_cpu_ms, max_step_bytes, max_step_kb = run_replay(path, #ledger, { cursor = cursor })
		helpers.assert_true(max_step_bytes <= LedgerReplay.READ_BYTES,
			"one step applied " .. max_step_bytes .. " bytes, more than one read block")
		helpers.assert_true(max_cpu_ms < 20, string.format("one step used %.1f ms of CPU (budget 20 ms)", max_cpu_ms))
		local allocation_limit_kb = STEP_ALLOCATION_BLOCKS * LedgerReplay.READ_BYTES / 1024
		helpers.assert_true(max_step_kb <= allocation_limit_kb, string.format(
			"one step allocated %.0f KB, more than %d read blocks (%.0f KB)",
			max_step_kb, STEP_ALLOCATION_BLOCKS, allocation_limit_kb))
		helpers.assert_true(#ledger > 4 * STEP_ALLOCATION_BLOCKS * LedgerReplay.READ_BYTES,
			"the synthetic ledger must dwarf the allocation bound, or a whole-ledger read would pass")
	end)

	helpers.it("resumes from its persisted state with the same result", function()
		local status, got, sql = run_replay(path, #ledger, { cursor = cursor, restart_each_step = true })
		helpers.assert_eq(status, "done")
		helpers.assert_true(sql == ledger:sub(1, complete), "a resumed replay applies each batch once, in order")
		helpers.assert_eq(got.offset, cursor(ledger, complete).offset)
	end)

	helpers.it("a rollover-only tail resets the cursor like one pass does", function()
		local rolled = synthetic_ledger(30, "\n-- === day rollover 2026-10-01 -> 2026-10-02 ===\n")
		local rolled_path = temp_file(rolled)
		local status, got = run_replay(rolled_path, #rolled, { cursor = cursor })
		os.remove(rolled_path)
		local want = cursor(rolled, Export._last_complete_batch_offset(rolled))
		helpers.assert_eq(status, "done")
		helpers.assert_eq(got.offset, want.offset)
		helpers.assert_eq(got.date, want.date)
		helpers.assert_eq(got.offset, 0, "a trailing rollover starts the new today.log at byte 0")
	end)

	helpers.it("fails closed on a ledger shorter than the replayed offset", function()
		local state = LedgerReplay.new_state()
		state.offset = #ledger + 10
		local status = LedgerReplay.step({ path = path, size = #ledger, state = state, cursor = cursor,
			exec = function() return true end, clock = function() return 1 end, deadline = 0 })
		helpers.assert_eq(status, "failed")
	end)

	helpers.it("the keystats start no longer replays synchronously", function()
		local src = assert(helpers.read_driver_unit("local function _ensure_ledger_header"))
		local init = src:sub((assert(src:find("local function _init(core_state)", 1, true))))
		helpers.assert_true(init:find("_replay_local_data_sql(", 1, true) == nil,
			"init must leave the ledger replay to the paced recovery coroutine")
		local recovery = src:match("local function _recover_aggregate_cache%(db, replay_state%)(.-)\nend\n")
		helpers.assert_true(recovery ~= nil and recovery:find("_replay_local_data_sql(db, replay_state)", 1, true) ~= nil,
			"the recovery coroutine must own the bounded replay")
	end)

	os.remove(path)
end)
