--- tests/unit/modules/keymap/expansion/test_builtin_clipboard_snapshot_acquisition.lua

--- ==============================================================================
--- MODULE: Builtin Clipboard Snapshot Acquisition
--- DESCRIPTION:
--- A native snapshot belongs to the builtin only while its generation stays
--- stable through capture and admission. A refused inline paste also retires its
--- pre-acquired follower owner before a healthy successor can run.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.keymap.multi_paste_fifo_fixture")
local A, B = ("A"):rep(60), ("B"):rep(60)

--- Runs an actual public expansion around native-shaped snapshot observations.
local function with_world(scenario)
	Fixture.with_world({}, function(w)
		local native_write, native_set = hs.pasteboard.writeAllData, hs.pasteboard.setContents
		local native_clear, native_count = hs.pasteboard.clearContents, hs.pasteboard.changeCount
		local scheduler = require("adapters.timer_scheduler")
		local original, foreign = {}, {
			["public.utf8-plain-text"] = "FOREIGN INITIAL COPY",
			["public.html"] = "<i>FOREIGN INITIAL COPY</i>",
		}
		for uti, bytes in pairs(w.original) do original[uti] = bytes end
		local debts = {}
		local reads, writes, restores, clears, begins = 0, 0, 0, 0, 0
		local function copy_foreign()
			helpers.assert_true(native_write(w.same_copy and original or foreign))
		end
		w.copy = copy_foreign
		w.original_bytes, w.foreign_bytes = original, foreign
		w.native_count = native_count
		w.native_empty = function() native_clear() end
		w.clipboard_activity = function()
			return { reads = reads, writes = writes, restores = restores, clears = clears, begins = begins }
		end
		w.empty = function() native_clear(); w.empty_snapshot = true end
		hs.pasteboard.changeCount = function()
			local refused = w.count_stage == "before"
				or w.count_stage == "after" and reads > 0 and writes == 0
			if refused then
				if w.count_fault == "nil" then return nil end
				if w.count_fault == "throw" then error("injected snapshot count refusal") end
				if w.count_fault == "infinite" then return math.huge end
			end
			return native_count()
		end
		hs.pasteboard.readAllData = function()
			reads = reads + 1
			if w.copy_at == "during-read" then copy_foreign() end
			local captured = {}
			for uti, bytes in pairs(w.board) do captured[uti] = bytes end
			if w.copy_at == "after-read" then copy_foreign() end
			if w.empty_snapshot then return nil end
			return captured
		end
		hs.pasteboard.setContents = function(value)
			writes = writes + 1
			return native_set(value)
		end
		hs.pasteboard.writeAllData = function(saved)
			restores = restores + 1
			return native_write(saved)
		end
		hs.pasteboard.clearContents = function()
			clears = clears + 1
			return native_clear()
		end
		local begin = w.synthetic.begin
		w.synthetic.begin = function(owner, ...)
			if owner == "clipboard_restore" then
				begins = begins + 1
				if w.copy_at == "debt" then copy_foreign() end
			end
			local tx = begin(owner, ...)
			if owner == "clipboard_restore" then debts[#debts + 1] = tx end
			return tx
		end
		function w.retired()
			local stats = w.synthetic.stats()
			helpers.assert_eq(stats.pending, 0)
			helpers.assert_eq(stats.active_transactions, 0)
			helpers.assert_eq(scheduler.activeCount(), 0)
			for _, debt in ipairs(debts) do
				helpers.assert_true(debt.completed and debt.completion_status == "complete")
				helpers.assert_eq(debt.retain_count, 0)
			end
		end
		function w.healthy(expected)
			local tx = w.start(A .. "{Tab}")
			helpers.assert_nil(tx.publication)
			w.advance(1)
			helpers.assert_true(tx.completed and tx.completion_status == "complete")
			helpers.assert_eq(writes, 1)
			helpers.assert_eq(restores, w.empty_snapshot and 0 or 1)
			helpers.assert_eq(clears, w.empty_snapshot and 1 or 0)
			helpers.assert_eq(#w.pastes, 1)
			helpers.assert_eq(w.pastes[1].value, A)
			helpers.assert_true(table.concat(w.keys, ","):find("v,tab", 1, true) ~= nil)
			helpers.assert_true(helpers.deep_equal(w.board, expected))
			w.retired()
		end
		function w.refused(expected, expected_reads, expected_begins)
			local accepted, tx, consume, events = w.attempt(A .. "{Tab}")
			helpers.assert_true(not accepted and not consume,
				"unstable or unknown snapshot acquisition must refuse the public replacement")
			helpers.assert_nil(events)
			helpers.assert_eq(reads, expected_reads,
				"unknown initial ownership must refuse before reading any snapshot")
			helpers.assert_eq(begins, expected_begins,
				"a refused capture must acquire no clipboard drain debt before validation")
			helpers.assert_eq(writes, 0)
			helpers.assert_eq(restores, 0)
			helpers.assert_eq(clears, 0)
			w.advance(1)
			helpers.assert_true(tx.completed and tx.completion_status == "cancelled",
				"the refused inline paste must cancel its exact public producer")
			helpers.assert_eq(tx.retain_count, 0)
			helpers.assert_eq(#w.pastes, 0)
			helpers.assert_eq(#w.keys, 0,
				"neither CmdV, Delete prefix nor the pre-acquired Tab follower may escape refusal")
			helpers.assert_true(helpers.deep_equal(w.board, expected))
			w.retired()
			w.copy_at, w.count_stage, w.count_fault, w.same_copy = nil, nil, nil, nil
			local successor = w.start(B .. "{Tab}")
			w.advance(2)
			helpers.assert_true(successor.completed and successor.completion_status == "complete")
			helpers.assert_eq(#w.pastes, 1)
			helpers.assert_eq(w.pastes[1].value, B)
			helpers.assert_true(helpers.deep_equal(w.board, expected),
				"the healthy successor must capture the preserved clipboard, never a rejected snapshot")
			w.retired()
		end
		scenario(w)
	end)
end

helpers.describe("builtin clipboard snapshot requires stable native acquisition", function()
	helpers.it("accepts a healthy rich snapshot from native count zero (builtin-snapshot-rich)", function()
		with_world(function(w) w.healthy(w.original_bytes) end)
	end)

	helpers.it("accepts a healthy absent snapshot (builtin-snapshot-empty)", function()
		with_world(function(w) w.empty(); w.healthy({}) end)
	end)

	helpers.it("accepts a native empty-table snapshot after clearContents (builtin-snapshot-native-empty)", function()
		with_world(function(w)
			w.native_empty()
			helpers.assert_eq(w.native_count(), 1)
			local tx = w.start(A .. "{Tab}")
			helpers.assert_nil(tx.publication)
			w.advance(1)
			helpers.assert_true(tx.completed and tx.completion_status == "complete")
			local activity = w.clipboard_activity()
			helpers.assert_eq(activity.reads, 1)
			helpers.assert_eq(activity.writes, 1)
			helpers.assert_eq(activity.restores, 0)
			helpers.assert_eq(activity.clears, 1)
			helpers.assert_eq(activity.begins, 1)
			helpers.assert_eq(w.native_count(), 3)
			helpers.assert_eq(#w.pastes, 1)
			helpers.assert_eq(w.pastes[1].value, A)
			helpers.assert_true(table.concat(w.keys, ","):find("v,tab", 1, true) ~= nil)
			helpers.assert_true(type(w.board) == "table" and next(w.board) == nil)
			w.retired()
		end)
	end)

	helpers.it("captures a foreign copy already present before acquisition (builtin-snapshot-foreign-before)", function()
		with_world(function(w) w.copy(); w.healthy(w.foreign_bytes) end)
	end)

	for _, point in ipairs({ "during-read", "after-read", "debt" }) do
		helpers.it("refuses a foreign copy during acquisition: " .. point .. " (builtin-snapshot-foreign)", function()
			with_world(function(w)
				w.copy_at = point
				w.refused(w.foreign_bytes, 1, point == "debt" and 1 or 0)
			end)
		end)
	end

	helpers.it("refuses an identical-byte copy whose generation changed (builtin-snapshot-identical)", function()
		with_world(function(w)
			w.copy_at, w.same_copy = "after-read", true
			w.refused(w.original_bytes, 1, 0)
		end)
	end)

	for _, stage in ipairs({ "before", "after" }) do
		for _, fault in ipairs({ "nil", "throw" }) do
			helpers.it("refuses " .. fault .. " native count " .. stage .. " capture (builtin-snapshot-count)", function()
				with_world(function(w)
					w.count_stage, w.count_fault = stage, fault
					w.refused(w.original_bytes, stage == "before" and 0 or 1, 0)
				end)
			end)
		end
	end

	helpers.it("refuses a nonfinite initial native count (builtin-snapshot-invalid)", function()
		with_world(function(w)
			w.count_stage, w.count_fault = "before", "infinite"
			w.refused(w.original_bytes, 0, 0)
		end)
	end)
end)
