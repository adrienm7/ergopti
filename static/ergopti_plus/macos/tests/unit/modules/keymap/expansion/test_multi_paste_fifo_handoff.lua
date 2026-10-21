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
