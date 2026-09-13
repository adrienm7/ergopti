--- tests/unit/modules/keylogger/test_native_context_probe.lua

--- Ensures the native probe cannot substitute JavaScript completion for AX evidence.
local helpers = require("tests.helpers")

local function scope(callback)
	helpers.with_stub_scope({ "hs", "adapters.webview_result" }, function()
		local state = { now = 0, completed = 0, errors = {}, callbacks = {}, running = false }
		local observations, receipt = { { allowed = true } }, {}
		local timer = {}
		function timer:stop()
			if state.stop_refused then return false end
			state.running = false
			return self
		end
		_G.hs = { timer = {
			absoluteTime = function() return state.now end,
			doEvery = function(_, fn) state.poll, state.running = fn, true; return timer end,
		} }
		local view = {}
		function view:windowTitle(title) state.title = title; return self end
		function view:evaluateJavaScript(_, done)
			state.callbacks[#state.callbacks + 1] = done
			if state.refuse then done(true, { code = 0 }); return false end
			return self
		end
		local factory = assert(loadfile(helpers.driver_root() .. "../../../tools/diagnostics/hs274-context-probe.lua"))()
		local probe = factory.new(view, observations, receipt,
			function() state.completed = state.completed + 1 end,
			function(err) state.errors[#state.errors + 1] = err end)
		callback(probe, state, observations, receipt)
	end)
end

helpers.describe("native context probe ownership (hs274)", function()
	helpers.it("requires new AX observations after each successful page mutation", function()
		scope(function(probe, state, observations, receipt)
			probe.start()
			for index, allowed in ipairs({ false, true, false, true }) do
				state.callbacks[index](true, { code = 0 })
				state.poll()
				helpers.assert_eq(#receipt, index - 1, "JavaScript alone cannot prove a transition")
				observations[#observations + 1] = { allowed = allowed }
				state.poll()
				helpers.assert_eq(receipt[index].observation, index + 1)
			end
			helpers.assert_eq(state.completed, 1)
			helpers.assert_eq(state.running, false)
			state.callbacks[1](false, { code = 1 })
			state.poll()
			helpers.assert_eq(#state.errors, 0)
			helpers.assert_eq(state.completed, 1)
		end)
	end)
	helpers.it("times out missing notifications and fences late callbacks", function()
		scope(function(probe, state, _, receipt)
			probe.start()
			state.callbacks[1](true, nil)
			state.now = 2000000001
			state.poll()
			helpers.assert_eq(#state.errors, 1)
			helpers.assert_true(state.errors[1]:find("observation timed out", 1, true) ~= nil)
			state.callbacks[1](false, { code = 1 })
			state.poll()
			helpers.assert_eq(#state.errors, 1)
			helpers.assert_eq(#receipt, 0)
			helpers.assert_eq(state.running, false)
		end)
	end)
	helpers.it("rejects refused submission even after synchronous success", function()
		scope(function(probe, state)
			state.refuse = true
			probe.start()
			helpers.assert_eq(#state.errors, 1)
			helpers.assert_eq(state.completed, 0)
			helpers.assert_eq(state.running, false)
		end)
	end)
	helpers.it("retains a refused timer stop for explicit cleanup retry", function()
		scope(function(probe, state)
			probe.start()
			state.stop_refused = true
			local ok = pcall(probe.stop)
			helpers.assert_eq(ok, false)
			state.poll()
			helpers.assert_eq(state.completed, 0)
			state.stop_refused = false
			probe.stop()
			helpers.assert_eq(state.running, false)
		end)
	end)
end)
