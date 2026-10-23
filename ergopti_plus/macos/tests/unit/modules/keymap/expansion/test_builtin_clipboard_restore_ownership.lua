--- tests/unit/modules/keymap/expansion/test_builtin_clipboard_restore_ownership.lua

--- ==============================================================================
--- MODULE: Builtin Clipboard Restore Ownership
--- DESCRIPTION:
--- A newer native copy supersedes a completed builtin paste, including overlapping
--- successors. Exact native clear receipts retain safe rollback and recovery.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.keymap.multi_paste_fifo_fixture")
local A, B = ("A"):rep(60), ("B"):rep(60)

--- Observes the actual native FIFO, transaction completion and restore debt.
local function with_world(scenario)
	Fixture.with_world({}, function(w)
		local native_set = hs.pasteboard.setContents
		local native_write = hs.pasteboard.writeAllData
		local native_clear = hs.pasteboard.clearContents
		local native_count = hs.pasteboard.changeCount
		local scheduler = require("adapters.timer_scheduler")
		local debts = {}
		local begin = w.synthetic.begin
		w.synthetic.begin = function(owner, ...)
			local tx = begin(owner, ...)
			if owner == "clipboard_restore" then debts[#debts + 1] = tx end
			return tx
		end
		w.copy = native_set
		w.clear = native_clear
		w.count = native_count
		hs.pasteboard.changeCount = function()
			if w.count_fault == "nil" then return nil end
			if w.count_fault == "throw" then error("injected native count refusal") end
			return native_count()
		end
		hs.pasteboard.setContents = function(value)
			if w.payload_fault then
				local fault = w.payload_fault
				w.payload_fault = nil
				native_clear()
				if w.copy_during_payload then native_set("FOREIGN COPY DURING PAYLOAD REFUSAL") end
				if fault == "throw" then error("injected payload failure after native clear") end
				return false
			end
			local result = native_set(value)
			if w.postwrite_unknown then w.count_fault = "nil" end
			return result
		end
		hs.pasteboard.writeAllData = function(saved)
			if w.restore_fault then
				local fault = w.restore_fault
				w.restore_fault = nil
				w.refused_restore_before = native_count()
				native_clear()
				w.refused_restore_after = native_count()
				if fault == "throw" then error("injected restore failure after native clear") end
				return false
			end
			return native_write(saved)
		end
		function w.handoff()
			local tx = w.start(A .. "{Tab}")
			helpers.assert_nil(tx.publication, "this path must remain an ordinary builtin")
			w.advance(0.11)
			helpers.assert_true(tx.completed and tx.completion_status == "complete")
			helpers.assert_eq(#w.pastes, 1)
			helpers.assert_eq(w.pastes[1].value, A)
			helpers.assert_eq(w.restores, 0)
			return tx
		end
		function w.retired()
			local stats = w.synthetic.stats()
			helpers.assert_eq(stats.pending, 0)
			helpers.assert_eq(stats.active_transactions, 0)
			helpers.assert_eq(scheduler.activeCount(), 0)
			for _, tx in ipairs(debts) do
				helpers.assert_true(tx.completed and tx.completion_status == "complete")
				helpers.assert_eq(tx.retain_count, 0)
			end
		end
		function w.retained()
			helpers.assert_true(#debts > 0 and not debts[#debts].completed)
			helpers.assert_true(debts[#debts].retain_count > 0)
			helpers.assert_true(w.synthetic.stats().active_transactions > 0)
		end
		scenario(w)
	end)
end

helpers.describe("builtin clipboard restore follows native ownership", function()
	helpers.it("restores the exact rich snapshot from a valid zero count (builtin-restore-rich)", function()
		with_world(function(w)
			helpers.assert_eq(w.count(), 0)
			w.handoff()
			w.advance(1)
			helpers.assert_true(rawequal(w.board, w.original))
			helpers.assert_eq(w.board["public.html"], "<b>ORIGINAL</b>")
			helpers.assert_eq(w.restores, 1)
			w.retired()
		end)
	end)

	helpers.it("restores an absent original through the native void clear (builtin-restore-empty)", function()
		with_world(function(w)
			w.clear()
			hs.pasteboard.readAllData = function() return nil end
			w.handoff()
			w.advance(1)
			helpers.assert_true(next(w.board) == nil)
			helpers.assert_eq(w.restores, 0)
			helpers.assert_eq(w.count(), 3)
			w.retired()
		end)
	end)

	for _, value in ipairs({ "FOREIGN COPY", A }) do
		helpers.it("preserves a newer native copy after actual handoff: " .. value:sub(1, 8) .. " (builtin-restore-copy)", function()
			with_world(function(w)
				w.handoff()
				w.copy(value)
				local foreign, count = w.board, w.count()
				w.advance(1)
				helpers.assert_true(rawequal(w.board, foreign),
					"newer native copy must survive the old builtin restore")
				helpers.assert_eq(w.count(), count)
				helpers.assert_eq(w.restores, 0)
				w.retired()
			end)
		end)
	end

	for _, overlap in ipairs({ true, false }) do
		helpers.it("captures the newer copy for a successor, overlap=" .. tostring(overlap) .. " (builtin-restore-successor)", function()
			with_world(function(w)
				w.handoff()
				w.copy("FOREIGN SUCCESSOR ORIGINAL")
				local foreign = w.board
				if not overlap then w.advance(1) end
				local tx = w.start(B .. "{Tab}")
				w.advance(2)
				helpers.assert_true(tx.completed and tx.completion_status == "complete")
				helpers.assert_eq(#w.pastes, 2)
				helpers.assert_eq(w.pastes[2].value, B)
				helpers.assert_true(rawequal(w.board, foreign),
					"successor must restore its freshly captured foreign original")
				helpers.assert_eq(w.restores, 1)
				w.retired()
			end)
		end)
	end

	for _, fault in ipairs({ "nil", "throw" }) do
		helpers.it("retains the certificate through a transient restore count refusal: " .. fault .. " (builtin-restore-count)", function()
			with_world(function(w)
				w.handoff()
				local owned, count = w.board, w.count()
				w.count_fault = fault
				w.advance(0.24)
				helpers.assert_true(rawequal(w.board, owned),
					"unreadable restore receipt must perform no native mutation")
				helpers.assert_eq(w.count(), count)
				helpers.assert_eq(w.restores, 0)
				w.retained()
				w.count_fault = nil
				w.advance(1)
				helpers.assert_true(rawequal(w.board, w.original))
				w.retired()
			end)
		end)
	end

	for _, fault in ipairs({ "false", "throw" }) do
		helpers.it("rolls back a payload failure after its exact native clear: " .. fault .. " (builtin-restore-payload)", function()
			with_world(function(w)
				w.payload_fault = fault
				local accepted, _, consume, events = w.attempt(A)
				helpers.assert_true(not accepted and not consume)
				helpers.assert_nil(events)
				helpers.assert_eq(#w.pastes, 0)
				helpers.assert_true(rawequal(w.board, w.original))
				helpers.assert_eq(w.count(), 2)
				helpers.assert_eq(w.restores, 1)
				w.advance(1)
				w.retired()
			end)
		end)

		helpers.it("retries a restore failure after its exact native clear: " .. fault .. " (builtin-restore-retry)", function()
			with_world(function(w)
				w.handoff()
				w.restore_fault = fault
				w.advance(0.24)
				helpers.assert_true(next(w.board) == nil)
				helpers.assert_eq(w.refused_restore_after, w.refused_restore_before + 1)
				w.retained()
				w.advance(1)
				helpers.assert_true(rawequal(w.board, w.original))
				helpers.assert_eq(w.restores, 1)
				w.retired()
			end)
		end)
	end

	helpers.it("preserves a foreign copy after own clear plus another native generation (builtin-restore-delta-two)", function()
		with_world(function(w)
			w.payload_fault, w.copy_during_payload = "false", true
			local accepted, _, consume, events = w.attempt(A)
			helpers.assert_true(not accepted and not consume)
			helpers.assert_nil(events)
			helpers.assert_eq(w.count(), 2,
				"one owned clear and one foreign clear must produce two exact changes")
			helpers.assert_eq(w.board["public.utf8-plain-text"], "FOREIGN COPY DURING PAYLOAD REFUSAL",
				"a delta-two receipt must preserve the intervening foreign copy")
			local foreign, count = w.board, w.count()
			w.advance(0.24)
			local second = w.attempt(B)
			helpers.assert_true(not second)
			w.advance(0.4)
			helpers.assert_true(rawequal(w.board, foreign))
			helpers.assert_eq(w.count(), count)
			helpers.assert_eq(w.restores, 0)
			helpers.assert_eq(#w.pastes, 0)
			w.retained()
		end)
	end)

	helpers.it("keeps an unreadable postwrite receipt closed without adopting a later count (builtin-restore-postcount)", function()
		with_world(function(w)
			w.postwrite_unknown = true
			local accepted, _, consume, events = w.attempt(A)
			helpers.assert_true(not accepted and not consume,
				"an unreadable postwrite receipt must refuse publication")
			helpers.assert_nil(events)
			w.postwrite_unknown, w.count_fault = false, nil
			w.advance(0.24)
			local owned, count = w.board, w.count()
			local second = w.attempt(B)
			helpers.assert_true(not second)
			w.advance(0.4)
			helpers.assert_true(rawequal(w.board, owned))
			helpers.assert_eq(w.count(), count)
			helpers.assert_eq(w.restores, 0)
			helpers.assert_eq(#w.pastes, 0)
			w.retained()
			-- This exact debt intentionally remains closed inside the isolated native
			-- world: a later readable generation is not proof that the payload is ours.
		end)
	end)
end)
