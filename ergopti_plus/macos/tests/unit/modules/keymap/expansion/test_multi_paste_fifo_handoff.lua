--- tests/unit/modules/keymap/expansion/test_multi_paste_fifo_handoff.lua

--- ==============================================================================
--- MODULE: Multi-Paste FIFO Handoff Ownership
--- DESCRIPTION:
--- Proves clipboard segments follow actual output handoff behind Terminal deletions.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.keymap.multi_paste_fifo_fixture")
local A, B, C = ("A"):rep(60), ("B"):rep(60), ("C"):rep(60)

--- Verifies exact clipboard payloads and the shared settle interval at each handoff.
local function assert_segments(world, expected)
	helpers.assert_eq(#world.pastes, #expected)
	helpers.assert_eq(#world.writes, #expected)
	for index, value in ipairs(expected) do
		helpers.assert_eq(world.pastes[index].value, value)
		if index > 1 then
			helpers.assert_true(world.writes[index].at - world.pastes[index - 1].at >= 0.079999,
				"next payload must wait for the preceding real paste handoff and settle")
		end
	end
	world.assert_retired()
end

helpers.describe("multi-paste follows actual FIFO handoff", function()
	helpers.it("keeps two clipboard segments healthy in a normal editor (multi-fifo-editor)", function()
		Fixture.with_world({}, function(w)
			w.start(A .. "{Enter}" .. B)
			w.advance(3)
			assert_segments(w, { A, B })
		end)
	end)

	helpers.it("keeps two clipboard segments behind paced Terminal deletes (multi-fifo-terminal)", function()
		Fixture.with_world({ terminal = true }, function(w)
			w.start(A .. "{Enter}" .. B)
			w.advance(3)
			assert_segments(w, { A, B })
		end)
	end)

	helpers.it("serializes three payloads and intervening key batches (multi-fifo-three)", function()
		Fixture.with_world({ terminal = true }, function(w)
			w.start(A .. "{Enter}" .. B .. "{Tab}" .. C)
			w.advance(3)
			assert_segments(w, { A, B, C })
			helpers.assert_true(table.concat(w.keys, ","):find("v,return,v,tab,v", 1, true) ~= nil)
		end)
	end)

	helpers.it("keeps the first payload while Terminal still owns its prefix (multi-fifo-wait)", function()
		Fixture.with_world({ terminal = true }, function(w)
			w.start(A .. "{Enter}" .. B)
			w.advance(0.2)
			helpers.assert_eq(#w.writes, 1)
			helpers.assert_eq(#w.pastes, 0)
			w.advance(3)
			assert_segments(w, { A, B })
		end)
	end)

	helpers.it("cancels after the first handoff without publishing the successor (multi-fifo-cancel)", function()
		Fixture.with_world({ terminal = true }, function(w)
			local tx = w.start(A .. "{Enter}" .. B)
			w.advance(0.30)
			helpers.assert_true(w.synthetic.cancel(tx))
			w.advance(3)
			helpers.assert_eq(#w.writes, 1)
			helpers.assert_eq(#w.pastes, 1)
			helpers.assert_eq(w.pastes[1].value, A)
			helpers.assert_true(table.concat(w.native.logs, "\n"):find(
				"Ordered synthetic transaction release failed", 1, true) == nil)
			w.assert_retired()
		end)
	end)

	for _, terminal in ipairs({ "cancel", "fail" }) do
		helpers.it("keeps dispatched clipboard data through " .. terminal .. " grace (multi-fifo-cancel-grace)", function()
			Fixture.with_world({ terminal = true }, function(w)
				local tx = w.start(A .. "{Enter}" .. B)
				w.advance(0.30)
				helpers.assert_eq(#w.pastes, 1)
				helpers.assert_true(w.synthetic[terminal](tx, "unit clipboard handoff revoked"))
				w.advance(0.31)
				helpers.assert_eq(w.restores, 0,
					"retirement must not replace a payload the receiving application can still read")
				helpers.assert_eq(w.board["public.utf8-plain-text"], A)
				w.advance(3)
				helpers.assert_eq(#w.pastes, 1, "the waiting second segment must not escape retirement")
				helpers.assert_eq(tx.completion_status, terminal == "cancel" and "cancelled" or "failed")
				w.assert_retired()
			end)
		end)
	end

	helpers.it("adopts a handoff before reentrant terminal rollback (multi-fifo-inline-cancel-grace)", function()
		Fixture.with_world({}, function(w)
			local tx = w.synthetic.begin("unit.inline-paste-retirement", "action")
			w.synthetic.retain(tx)
			w.synthetic.seal(tx)
			local retired = false
			w.synthetic.on_dispatched(tx, function(_, _, status)
				if status == "dispatched" then retired = w.synthetic.cancel(tx) end
			end)
			local emit = w.synthetic.emit_key_stroke
			w.synthetic.emit_key_stroke = function(...)
				local accepted, batch = emit(...)
				w.advance(0.01)
				return accepted, batch
			end
			w.synthetic.with_transaction(tx, function()
				require("modules.keymap.utils").emit_text(A)
			end)
			helpers.assert_true(retired and tx.completed)
			helpers.assert_eq(tx.completion_status, "cancelled")
			helpers.assert_eq(#w.pastes, 1)
			helpers.assert_eq(w.restores, 0,
				"terminal delivery before the emitter receipt must preserve the dispatched payload")
			helpers.assert_eq(w.board["public.utf8-plain-text"], A)
			w.advance(3)
			w.assert_retired()
		end)
	end)

	helpers.it("preserves cancellation grace after restore timer refusal (multi-fifo-cancel-timer-grace)", function()
		Fixture.with_world({ terminal = true }, function(w)
			local tx = w.start(A .. "{Enter}" .. B)
			w.advance(0.30)
			helpers.assert_eq(#w.pastes, 1)
			w.native.fail_next_timer_new = true
			helpers.assert_true(w.synthetic.cancel(tx))
			w.advance(0.31)
			helpers.assert_eq(w.restores, 0)
			helpers.assert_eq(w.board["public.utf8-plain-text"], A,
				"a refused restoration timer must not shorten the dispatched paste interval")
			helpers.assert_true(table.concat(w.native.logs, "\n"):find(
				"Clipboard restore could not be armed after Cmd+V handoff", 1, true) ~= nil,
				"the injected allocation refusal must reach the restore timer")
			w.advance(3)
			w.assert_retired()
		end)
	end)

	helpers.it("bounds persistent restore refusals until a later retry (multi-fifo-persistent-timer-grace)", function()
		Fixture.with_world({ terminal = true }, function(w)
			local tx = w.start(A .. "{Enter}" .. B)
			w.advance(0.30)
			helpers.assert_eq(#w.pastes, 1)
			local native_new = hs.timer.new
			local restore_delay = require("infra.timings").sec("debounce", "clipboard_restore_ms")
			local attempts, refusing = 0, true
			hs.timer.new = function(delay, ...)
				if refusing and delay == restore_delay then
					attempts = attempts + 1
					-- Bound the broken implementation too: it burns this entire budget
					-- in one lifecycle drain instead of retaining honest cleanup debt.
					if attempts <= 8 then return nil end
				end
				return native_new(delay, ...)
			end
			helpers.assert_true(w.synthetic.cancel(tx))
			w.advance(0.31)
			helpers.assert_eq(w.restores, 0)
			helpers.assert_eq(w.board["public.utf8-plain-text"], A)
			helpers.assert_true(attempts > 0 and attempts <= 2,
				"a pending host interval must not spin in immediate recovery: " .. tostring(attempts))
			w.advance(3)
			helpers.assert_true(w.synthetic.stats().active_transactions > 0,
				"unarmed restoration must retain its exact original snapshot and drain debt")
			refusing = false
			w.standalone(B)
			w.advance(6)
			helpers.assert_eq(#w.pastes, 2)
			helpers.assert_eq(w.pastes[2].value, B)
			helpers.assert_eq(w.restores, 2,
				"the later producer must settle the retained original before its own fresh borrow")
			helpers.assert_true(helpers.deep_equal(w.board, w.original))
			helpers.assert_eq(w.synthetic.stats().active_transactions, 0)
			helpers.assert_eq(w.synthetic.stats().pending, 0)
			helpers.assert_eq(require("adapters.timer_scheduler").activeCount(), 0)
		end)
	end)

	for _, refuse_timer in ipairs({ false, true }) do
		helpers.it("retains reentrant cancellation recovery before a successor, timer refusal="
			.. tostring(refuse_timer) .. " (multi-fifo-inline-recovery-grace)", function()
			Fixture.with_world({}, function(w)
				local tx = w.synthetic.begin("unit.inline-paste-recovery", "action")
				w.synthetic.retain(tx)
				w.synthetic.seal(tx)
				w.synthetic.on_dispatched(tx, function(_, _, status)
					if status == "dispatched" then helpers.assert_true(w.synthetic.cancel(tx)) end
				end)
				local native_new = hs.timer.new
				local restore_delay = require("infra.timings").sec("debounce", "clipboard_restore_ms")
				local refusing, attempts = refuse_timer, 0
				hs.timer.new = function(delay, ...)
					if refusing and delay == restore_delay then
						attempts = attempts + 1
						if attempts <= 8 then return nil end
					end
					return native_new(delay, ...)
				end
				local emit = w.synthetic.emit_key_stroke
				w.synthetic.emit_key_stroke = function(...)
					local accepted, batch = emit(...)
					w.advance(0.01)
					return accepted, batch
				end
				w.synthetic.with_transaction(tx, function()
					require("modules.keymap.utils").emit_text(A)
				end)
				helpers.assert_true(tx.completed and tx.completion_status == "cancelled")
				local successor_ok = pcall(w.standalone, B)
				helpers.assert_true(not successor_ok,
					"a reentrant terminal's retained recovery must refuse a successor during host grace")
				helpers.assert_eq(#w.writes, 1)
				helpers.assert_eq(#w.pastes, 1)
				helpers.assert_eq(w.board["public.utf8-plain-text"], A)
				w.advance(3)
				refusing = false
				w.synthetic.emit_key_stroke = emit
				w.standalone(B)
				w.advance(6)
				helpers.assert_eq(#w.pastes, 2)
				helpers.assert_eq(w.pastes[2].value, B)
				helpers.assert_eq(w.restores, 2)
				helpers.assert_true(helpers.deep_equal(w.board, w.original))
				helpers.assert_eq(w.synthetic.stats().active_transactions, 0)
				helpers.assert_eq(require("adapters.timer_scheduler").activeCount(), 0)
			end)
		end)
	end

	helpers.it("preserves committed Terminal output when cancellation is refused (multi-fifo-cancel-refused)", function()
		Fixture.with_world({ terminal = true }, function(w)
			local tx = w.start(A .. "{Enter}" .. B)
			w.advance(0.1)
			helpers.assert_eq(w.synthetic.cancel(tx), false)
			w.advance(3)
			assert_segments(w, { A, B })
		end)
	end)

	helpers.it("fails the exact transaction without emitting the waiting segment (multi-fifo-fail)", function()
		Fixture.with_world({ terminal = true }, function(w)
			local tx = w.start(A .. "{Enter}" .. B)
			w.advance(0.1)
			helpers.assert_true(w.synthetic.fail(tx, "unit producer revoked"))
			w.advance(3)
			helpers.assert_eq(#w.writes, 1)
			helpers.assert_eq(#w.pastes, 1)
			helpers.assert_eq(w.pastes[1].value, A)
			w.assert_retired()
		end)
	end)
	helpers.it("keeps exact receipts for synchronous refusal inside paced completion (multi-fifo-inline-receipt)", function()
		Fixture.with_world({ terminal = true }, function(w)
			local tx = w.start(A)
			local observed = false
			w.synthetic.on_dispatched(tx, function(_, _, status)
				if status ~= "dispatched" then return end
				local successor = w.synthetic.begin("unit.inline-receipt", "action")
				local seen
				w.synthetic.on_dispatched(successor, function(_, batch, result) seen = { batch, result } end)
				w.native.fail_next_do_after = true
				local accepted, batch = w.synthetic.emit_key_stroke({}, "x", 0, successor)
				helpers.assert_eq(accepted, false)
				helpers.assert_not_nil(seen, "owned paced completion must expose the pre-return refusal")
				helpers.assert_true(rawequal(seen[1], batch))
				helpers.assert_eq(seen[2], "failed")
				observed = true
			end)
			w.advance(3)
			helpers.assert_true(observed)
			assert_segments(w, { A })
		end)
	end)

	helpers.it("owns standalone token output without an ambient transaction (multi-fifo-standalone)", function()
		Fixture.with_world({}, function(w)
			local epoch = w.synthetic.current_action_epoch()
			local count, echo, logical, fence = w.standalone(A .. "{Enter}" .. B)
			helpers.assert_eq(count, 121)
			helpers.assert_eq(echo, "\r")
			helpers.assert_eq(logical, A .. "\r" .. B)
			helpers.assert_true(fence > 0)
			w.advance(3)
			helpers.assert_true(not rawequal(w.synthetic.current_action_epoch(), epoch),
				"standalone token output must retain its historical action authority")
			assert_segments(w, { A, B })
		end)
	end)

	helpers.it("waits for a retained standalone FIFO trigger before changing payload (multi-fifo-standalone-held)", function()
		Fixture.with_world({}, function(w)
			w.native.deliver_trigger = false
			w.standalone(A .. "{Enter}" .. B)
			w.advance(0.10)
			helpers.assert_eq(#w.writes, 1)
			helpers.assert_eq(#w.pastes, 0)
			helpers.assert_not_nil(w.native.last_trigger)
			w.native.deliver_trigger = true
			w.native.deliver_posted_trigger()
			w.advance(3)
			assert_segments(w, { A, B })
		end)
	end)

	helpers.it("retires an ordered timer whose first native stop refuses (multi-fifo-stop-refused)", function()
		Fixture.with_world({ terminal = true }, function(w)
			w.native.options.timer_stop_failures_by_call = { [1] = 1 }
			w.start(A .. "{Enter}" .. B)
			w.advance(3)
			assert_segments(w, { A, B })
			local diagnostic = table.concat(w.native.logs, "\n")
			helpers.assert_true(diagnostic:find("cleanup remains pending", 1, true) ~= nil)
		end)
	end)

	helpers.it("does not mistake an earlier Return batch for the retained paste (multi-fifo-exact-batch)", function()
		Fixture.with_world({ terminal = true }, function(w)
			w.on_key = function(event)
				if event.key == "return" then w.native.deliver_trigger = false end
			end
			w.start(A .. "{Enter}" .. B .. "{Tab}" .. C)
			w.advance(0.56)
			helpers.assert_eq(#w.writes, 2)
			helpers.assert_eq(#w.pastes, 1)
			helpers.assert_not_nil(w.native.last_trigger)
			w.native.deliver_trigger = true
			w.native.deliver_posted_trigger()
			w.advance(3)
			assert_segments(w, { A, B, C })
		end)
	end)

end)
