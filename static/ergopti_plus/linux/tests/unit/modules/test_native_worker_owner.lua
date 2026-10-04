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
