--- _shared/lua/test/tap_hold_copy_check_contract.lua

--- Shared regressions for the tap-hold copy check, replayed by the macOS and
--- Linux suites against a fake clipboard counter and a fake clock.
--- @param helpers table Driver test helpers.
--- @param CopyCheck table The shared copy check module.
return function(helpers, CopyCheck)
	--- A fake world: a clipboard whose counter moves only when an application
	--- copies, timers that fire when the test advances the clock, and the
	--- reports the checker made.
	--- @param options table|nil { copies_on_send = { [n] = true }, refuse_send = boolean }
	--- @return table world
	local function world(options)
		options = options or {}
		local w = { now = 0, counter = 41, content = "same text", timers = {}, reports = {}, sends = 0, reads = 0 }
		local checker = CopyCheck.new({
			verify_ms = 250,
			read_counter = function()
				w.reads = w.reads + 1
				if w.unreadable then return nil end
				return w.counter
			end,
			send_copy = function()
				w.sends = w.sends + 1
				if options.refuse_send then return false end
				-- The application copies the same text again: the content does not
				-- change, the counter does.
				if options.copies_on_send and options.copies_on_send[w.sends] then w.counter = w.counter + 1 end
				return true
			end,
			after = function(delay_ms, callback)
				local timer = { at = w.now + delay_ms, callback = callback }
				w.timers[#w.timers + 1] = timer
				return timer
			end,
			cancel = function(timer) timer.cancelled = true end,
			report = function(outcome, detail) w.reports[#w.reports + 1] = { outcome = outcome, detail = detail } end,
		})
		w.checker = checker
		function w.advance(ms)
			w.now = w.now + ms
			local fired = true
			while fired do
				fired = false
				for index, timer in ipairs(w.timers) do
					if not timer.cancelled and timer.at <= w.now then
						table.remove(w.timers, index)
						timer.callback()
						fired = true
						break
					end
				end
			end
		end
		return w
	end

	helpers.describe("tap-hold copy check (tap-copy-verified)", function()
		helpers.it("a copy that moved the counter is verified without a retry (tap-copy-verified)", function()
			local w = world()
			helpers.assert_eq(w.checker:start(w.counter, "left_shift"), true)
			-- The application copies the same text: the content is unchanged.
			w.counter = w.counter + 1
			helpers.assert_eq(w.reads, 0, "start never reads the counter itself: the wait is a timer")
			w.advance(249)
			helpers.assert_eq(#w.reports, 0, "nothing is judged before the wait has passed")
			w.advance(1)
			helpers.assert_eq(#w.reports, 1)
			helpers.assert_eq(w.reports[1].outcome, CopyCheck.COPIED)
			helpers.assert_eq(w.sends, 0, "a copy that landed is never sent again")
			helpers.assert_eq(w.content, "same text", "the counter decided, not the content")
			helpers.assert_eq(w.checker:is_pending(), false)
		end)

		helpers.it("a copy that landed only on the retry is reported as such (tap-copy-verified)", function()
			local w = world({ copies_on_send = { [1] = true } })
			w.checker:start(w.counter, "left_shift")
			w.advance(250)
			helpers.assert_eq(w.sends, 1, "an unchanged counter sends the copy once more")
			helpers.assert_eq(#w.reports, 0, "the retry is judged after its own wait")
			w.advance(250)
			helpers.assert_eq(#w.reports, 1)
			helpers.assert_eq(w.reports[1].outcome, CopyCheck.COPIED_ON_RETRY)
			helpers.assert_eq(w.reports[1].detail.attempts, 2)
			helpers.assert_eq(CopyCheck.is_failure(w.reports[1].outcome), false)
		end)

		helpers.it("a copy that never landed is a failure after one retry (tap-copy-verified)", function()
			local w = world()
			w.checker:start(w.counter, "left_shift")
			w.advance(250)
			w.advance(250)
			w.advance(1000)
			helpers.assert_eq(w.sends, CopyCheck.RETRIES, "exactly one retry")
			helpers.assert_eq(#w.reports, 1)
			helpers.assert_eq(w.reports[1].outcome, CopyCheck.NOT_COPIED)
			helpers.assert_eq(w.reports[1].detail.source, "left_shift")
			helpers.assert_eq(w.reports[1].detail.waited_ms, 500)
			helpers.assert_eq(CopyCheck.is_failure(w.reports[1].outcome), true, "the driver warns the user")
		end)

		helpers.it("a refused retry keystroke is a failure too (tap-copy-verified)", function()
			local w = world({ refuse_send = true })
			w.checker:start(w.counter, "left_shift")
			w.advance(250)
			helpers.assert_eq(w.reports[1].outcome, CopyCheck.RETRY_REFUSED)
			helpers.assert_eq(CopyCheck.is_failure(w.reports[1].outcome), true)
		end)

		helpers.it("an unreadable counter is reported, never taken for a failed copy (tap-copy-verified)", function()
			local w = world()
			helpers.assert_eq(w.checker:start(nil, "left_shift"), false)
			helpers.assert_eq(w.reports[1].outcome, CopyCheck.COUNTER_UNREADABLE)
			helpers.assert_eq(#w.timers, 0)
			local later = world()
			later.checker:start(later.counter, "left_shift")
			later.unreadable = true
			later.advance(250)
			helpers.assert_eq(later.reports[1].outcome, CopyCheck.COUNTER_UNREADABLE)
			helpers.assert_eq(later.sends, 0, "no retry on a counter that cannot be read")
			helpers.assert_eq(CopyCheck.is_failure(later.reports[1].outcome), false)
		end)

		helpers.it("a newer copy supersedes a pending check and its retry (tap-copy-verified)", function()
			local w = world()
			w.checker:start(w.counter, "left_shift")
			w.advance(100)
			w.checker:start(w.counter, "left_shift")
			helpers.assert_eq(w.reports[1].outcome, CopyCheck.SUPERSEDED)
			w.counter = w.counter + 1
			w.advance(250)
			helpers.assert_eq(#w.reports, 2)
			helpers.assert_eq(w.reports[2].outcome, CopyCheck.COPIED)
			helpers.assert_eq(w.sends, 0, "the superseded check never retried")
		end)

		helpers.it("stop abandons the pending check silently (tap-copy-verified)", function()
			local w = world()
			w.checker:start(w.counter, "left_shift")
			w.checker:stop()
			w.advance(1000)
			helpers.assert_eq(#w.reports, 0)
			helpers.assert_eq(w.sends, 0)
		end)

		helpers.it("a replaced counter read cannot retry or finish its successor", function()
			local callbacks, reports, sends, checker, replace = {}, {}, 0, nil, true
			checker = CopyCheck.new({ verify_ms = 250,
				read_counter = function()
					if replace then replace = false; checker:stop(); checker:start(41, "new") end
					return 41
				end,
				send_copy = function() sends = sends + 1; return true end,
				after = function(_, fn) callbacks[#callbacks + 1] = fn; return {} end,
				cancel = function() end,
				report = function(outcome) reports[#reports + 1] = outcome end })
			checker:start(41, "old"); callbacks[1]()
			helpers.assert_eq(sends, 0)
			helpers.assert_eq(#reports, 0)
			helpers.assert_eq(checker:is_pending(), true)
			callbacks[2](); helpers.assert_eq(sends, 1)
		end)

		for _, result in ipairs({ false, true }) do
			helpers.it("a replaced retry cannot finish or arm its successor: " .. tostring(result), function()
				local callbacks, reports, sends, checker = {}, {}, 0, nil
				checker = CopyCheck.new({ verify_ms = 250, read_counter = function() return 41 end,
					send_copy = function()
						sends = sends + 1
						if sends == 1 then checker:stop(); checker:start(41, "new"); return result end
						return true
					end,
					after = function(_, fn) callbacks[#callbacks + 1] = fn; return {} end,
					cancel = function() end,
					report = function(outcome) reports[#reports + 1] = outcome end })
				checker:start(41, "old"); callbacks[1]()
				helpers.assert_eq(#reports, 0)
				helpers.assert_eq(#callbacks, 2, "only the successor owns a timer")
				helpers.assert_eq(checker:is_pending(), true)
				callbacks[2](); helpers.assert_eq(sends, 2)
			end)
		end

		helpers.it("a timer returned after replacement is cancelled, without replacing the new timer", function()
			local callbacks, cancelled, checker, first = {}, {}, nil, true
			checker = CopyCheck.new({ verify_ms = 250, read_counter = function() return 41 end,
				send_copy = function() return true end,
				after = function(_, fn)
					local handle = {}; callbacks[#callbacks + 1] = fn
					if first then first = false; checker:stop(); checker:start(41, "new") end
					return handle
				end,
				cancel = function(handle) cancelled[handle] = true end,
				report = function() end })
			helpers.assert_eq(checker:start(41, "old"), false)
			helpers.assert_eq(checker:is_pending(), true)
			local count = 0; for _ in pairs(cancelled) do count = count + 1 end
			helpers.assert_eq(count, 1, "the retired timer must be cancelled")
		end)

		helpers.it("a superseded report cannot overwrite a newer check", function()
			local callbacks, reports, checker, replace = {}, {}, nil, true
			checker = CopyCheck.new({ verify_ms = 250, read_counter = function() return 41 end,
				send_copy = function() return true end,
				after = function(_, fn) callbacks[#callbacks + 1] = fn; return {} end,
				cancel = function() end,
				report = function(outcome, detail)
					reports[#reports + 1] = { outcome = outcome, source = detail.source }
					if outcome == CopyCheck.SUPERSEDED and replace then
						replace = false; checker:start(41, "newest")
					end
				end })
			checker:start(41, "old")
			helpers.assert_eq(checker:start(41, "middle"), false)
			helpers.assert_eq(reports[1].outcome, CopyCheck.SUPERSEDED)
			callbacks[2]()
			helpers.assert_eq(checker:is_pending(), true, "newest check owns its retry")
		end)

		helpers.it("counter exceptions settle without a retry", function()
			local callbacks, reports = {}, {}
			local checker = CopyCheck.new({ verify_ms = 250,
				read_counter = function() error("counter refused") end,
				send_copy = function() error("must not retry") end,
				after = function(_, fn) callbacks[#callbacks + 1] = fn; return {} end,
				report = function(outcome) reports[#reports + 1] = outcome end })
			checker:start(41, "tap"); callbacks[1]()
			helpers.assert_eq(reports[1], CopyCheck.COUNTER_UNREADABLE)
			helpers.assert_eq(checker:is_pending(), false)
		end)

		helpers.it("timer exceptions settle as refused", function()
			local reports = {}
			local checker = CopyCheck.new({ verify_ms = 250, read_counter = function() return 41 end,
				send_copy = function() return true end, after = function() error("timer refused") end,
				report = function(outcome) reports[#reports + 1] = outcome end })
			helpers.assert_eq(checker:start(41, "tap"), false)
			helpers.assert_eq(reports[1], CopyCheck.TIMER_REFUSED)
			helpers.assert_eq(checker:is_pending(), false)
		end)

		helpers.it("a refused timer is reported instead of hanging (tap-copy-verified)", function()
			local reports = {}
			local checker = CopyCheck.new({
				verify_ms = 250,
				read_counter = function() return 1 end,
				send_copy = function() return true end,
				after = function() return nil end,
				report = function(outcome) reports[#reports + 1] = outcome end,
			})
			helpers.assert_eq(checker:start(1, "left_shift"), false)
			helpers.assert_eq(reports[1], CopyCheck.TIMER_REFUSED)
			helpers.assert_eq(checker:is_pending(), false)
		end)
	end)
end
