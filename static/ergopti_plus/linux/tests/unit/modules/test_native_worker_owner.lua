--- tests/unit/modules/test_native_worker_owner.lua

local helpers = require("tests.helpers")
local Worker = require("native_worker_owner")

helpers.describe("Shared native worker completion ownership", function()
	helpers.it("publishes completion only after process and physical timer retirement", function()
		local terminal, retire, closing, admission = nil, nil, nil, true
		local physically_settled = false
		local completions = {}
		local owner = Worker.new(function()
			return { executable = "fixture", arguments = {} }, function() return admission end
		end, {
			parse = function(value) return value end,
			timeout_ms = 1000, retry_ms = 10,
			complete = function(code) completions[#completions + 1] = code end,
			runner = { spawn = function(_, _, callback)
				terminal = callback
				return {
					start = function() return true end,
					isSettled = function() return physically_settled end,
					terminate = function() return false end,
					onSettled = function(callback) retire = callback; return true end,
				}
			end },
			native = {
				new_timer = function() return {} end,
				timer_start = function() return 0 end,
				timer_stop = function() return 0 end,
				close = function(_, callback) closing = callback end,
			},
		})
		helpers.assert_true(owner.run("binding"))
		terminal(0)
		helpers.assert_eq(completions, {})
		helpers.assert_true(owner.has_pending())
		physically_settled = true
		retire()
		helpers.assert_eq(completions, {})
		helpers.assert_true(owner.has_pending())
		closing()
		helpers.assert_eq(completions, { 0 })
		helpers.assert_eq(owner.has_pending(), false)
		closing(); retire(); terminal(0)
		helpers.assert_eq(completions, { 0 })
	end)
	for _, refusal in ipairs({ "false", "throw", "reentry" }) do
		helpers.it("retains external resource " .. refusal .. " until acknowledged retirement", function()
			local owner, terminal, retire, tick, refused = nil, nil, nil, nil, true
			local done, stopped = {}, nil
			owner = Worker.new(function()
				return { executable = "fixture", arguments = {} }, function() return true end
			end, {
				parse = function(value) return value end,
				timeout_ms = 1000, retry_ms = 10,
				complete = function(code) done[#done + 1] = code end,
				retire = function()
					if refused then
						if refusal == "throw" then error("closed native refusal") end
						if refusal == "reentry" then stopped = owner.stop() end
						return false
					end
					return true
				end,
				runner = { spawn = function(_, _, completed)
					terminal = completed
					return {
						start = function() return true end,
						isSettled = function() return terminal == false end,
						terminate = function() return true end,
						onSettled = function(callback) retire = callback; return true end,
					}
				end },
				native = {
					new_timer = function() return {} end,
					timer_start = function(_, _, _, callback) tick = callback; return true end,
					timer_stop = function() return true end,
					close = function(_, callback) callback(); return true end,
				},
			})
			helpers.assert_true(owner.run("binding"))
			terminal(0); terminal = false; retire()
			helpers.assert_true(owner.has_pending())
			helpers.assert_eq(done, {})
			if refusal == "reentry" then helpers.assert_eq(stopped, false) end
			refused = false; tick()
			helpers.assert_eq(owner.has_pending(), false)
			helpers.assert_eq(done, refusal == "reentry" and {} or { 0 })
		end)
	end

end)

helpers.describe("Shared native worker timer close attempt receipts", function()
	local function fixture(close)
		local state = { completions = {}, idle = 0, close_calls = {}, stopped = 0, settled = false }
		local owner
		owner = Worker.new(function()
			return { executable = "fixture", arguments = {} }, function() return true end
		end, {
			parse = function(value) return value end,
			timeout_ms = 1000, retry_ms = 10,
			complete = function(code) state.completions[#state.completions + 1] = code end,
			runner = { spawn = function(_, _, callback)
				state.completed = callback
				return {
					start = function() return true end,
					isSettled = function() return state.settled end,
					terminate = function() return false end,
					onSettled = function(callback) state.retired = callback; return true end,
				}
			end },
			native = {
				new_timer = function() return {} end,
				timer_start = function(_, _, _, callback) state.tick = callback; return 0 end,
				timer_stop = function() state.stopped = state.stopped + 1; return 0 end,
				close = function(timer, callback)
					state.close_calls[#state.close_calls + 1] = { timer = timer, callback = callback }
					return close(state, owner, callback, #state.close_calls)
				end,
			},
		})
		state.owner = owner
		helpers.assert_true(owner.run("binding"))
		owner.when_settled(function() state.idle = state.idle + 1 end)
		state.finish = function()
			state.completed(37)
			state.settled = true
			state.retired()
		end
		return state
	end

	local function refused(mode)
		if mode == "throw" then error("closed timer refusal") end
		if mode == "nil-error" then return nil, "closed timer refusal" end
		return false
	end

	for _, mode in ipairs({ "false", "nil-error", "throw" }) do
		for _, timing in ipairs({ "delayed", "synchronous" }) do
			helpers.it("retains timer debt after " .. timing .. " callback from " .. mode .. " close", function()
				local state = fixture(function(_, owner, callback, attempt)
					if attempt == 1 then
						if timing == "synchronous" then
							callback()
							helpers.assert_true(owner.has_pending(), "callback cannot precede same-call admission")
						end
						return refused(mode)
					end
					return true
				end)
				state.finish()
				helpers.assert_true(state.owner.has_pending(), "refused call retains its native timer debt")
				helpers.assert_eq(state.idle, 0)
				helpers.assert_eq(state.completions, {})
				state.close_calls[1].callback()
				helpers.assert_true(state.owner.has_pending(), "rejected callback cannot establish physical retirement")
				state.tick()
				helpers.assert_eq(#state.close_calls, 2, "poll must obtain a freshly admitted close attempt")
				helpers.assert_true(state.owner.has_pending(), "fresh admission still needs its own callback")
				helpers.assert_eq(state.completions, {})
				helpers.assert_eq(state.owner.run("successor"), false, "new acquisition cannot bypass timer debt")
				state.close_calls[2].callback()
				helpers.assert_eq(state.owner.has_pending(), false)
				helpers.assert_eq(state.completions, { 37 })
				helpers.assert_eq(state.idle, 1)
				helpers.assert_eq(state.stopped, 1)
				state.close_calls[1].callback(); state.close_calls[2].callback(); state.tick()
				helpers.assert_eq(state.completions, { 37 }, "late callbacks cannot duplicate completion")
				helpers.assert_eq(state.idle, 1)
			end)
		end
	end

	helpers.it("synchronous physical close waits for admission from that same call", function()
		local state = fixture(function(state, owner, callback)
			callback()
			helpers.assert_true(owner.has_pending(), "same call has not acknowledged admission yet")
			helpers.assert_eq(state.completions, {})
			helpers.assert_eq(state.idle, 0)
			return true
		end)
		state.finish()
		helpers.assert_eq(state.owner.has_pending(), false)
		helpers.assert_eq(state.completions, { 37 })
		helpers.assert_eq(state.idle, 1)
	end)

	helpers.it("rejected older callback cannot borrow newer accepted close admission", function()
		local state = fixture(function(_, _, _, attempt) return attempt > 1 end)
		state.finish()
		state.tick()
		helpers.assert_eq(#state.close_calls, 2)
		state.close_calls[1].callback()
		helpers.assert_true(state.owner.has_pending(), "old callback does not own the newer admission")
		helpers.assert_eq(state.completions, {})
		helpers.assert_eq(state.idle, 0)
		state.close_calls[2].callback()
		helpers.assert_eq(state.owner.has_pending(), false)
		helpers.assert_eq(state.completions, { 37 })
		helpers.assert_eq(state.idle, 1)
	end)

	helpers.it("plain nil native close admission still requires its exact delayed callback", function()
		local state = fixture(function() return nil end)
		state.finish()
		helpers.assert_true(state.owner.has_pending())
		helpers.assert_eq(state.completions, {})
		state.tick()
		helpers.assert_eq(#state.close_calls, 1, "admitted close is not submitted twice")
		state.close_calls[1].callback()
		helpers.assert_eq(state.owner.has_pending(), false)
		helpers.assert_eq(state.completions, { 37 })
	end)

	helpers.it("stale accepted close callback cannot release a successor owner", function()
		local state = fixture(function() return 0 end)
		state.finish()
		local predecessor = state.close_calls[1].callback
		predecessor()
		helpers.assert_true(state.owner.run("successor"))
		state.owner.when_settled(function() state.idle = state.idle + 1 end)
		predecessor()
		helpers.assert_true(state.owner.has_pending())
		helpers.assert_eq(state.completions, { 37 })
		helpers.assert_eq(state.idle, 1)
		state.finish()
		helpers.assert_eq(#state.close_calls, 2)
		predecessor()
		helpers.assert_true(state.owner.has_pending())
		state.close_calls[2].callback()
		helpers.assert_eq(state.owner.has_pending(), false)
		helpers.assert_eq(state.completions, { 37, 37 })
		helpers.assert_eq(state.idle, 2)
	end)
end)
