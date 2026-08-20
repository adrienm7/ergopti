--- tests/unit/adapters/test_http_client_timeout_transaction.lua

--- ==============================================================================
--- MODULE: HttpClient Timeout Transaction Regression Tests
--- DESCRIPTION:
--- Exercises the HttpClient timeout as one exact asynchronous capability. A
--- request must not reach the network unless its timeout timer committed, and a
--- timer whose rollback or terminal stop is uncertain must stay owned and block
--- every successor until that same capability is released.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================================
-- =====================================================
-- ======= 1/ Transactional Test Harness ===============
-- =====================================================
-- =====================================================

--- Loads HttpClient and the real TimerScheduler against one native timer stub.
--- @param timer_stub table Native timer API double.
--- @param http_stub table Native HTTP API double.
--- @return table client A fresh HttpClient instance.
--- @return table scheduler The freshly loaded TimerScheduler adapter.
local function load_client(timer_stub, http_stub)
	package.loaded["adapters.http_client"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	local HttpClient = helpers.load_with_stubs("adapters.http_client", {
		timer = timer_stub,
		http = http_stub,
	})
	return HttpClient.new(), package.loaded["adapters.timer_scheduler"]
end

--- Builds a native timer whose start behavior is selected by the test.
--- @param start_mode string One of success, nil, false, or throw.
--- @return table timer_stub Native timer API double.
--- @return table state Observable constructor and stop state.
local function make_single_timer(start_mode)
	local state = {
		construct_calls = 0,
		stop_calls = 0,
		native_callback = nil,
	}
	local timer_stub = {
		doAfter = function()
			error("HttpClient must not bypass TimerScheduler with a raw timeout")
		end,
		secondsSinceEpoch = function() return 0 end,
	}
	function timer_stub.new(_, callback)
		state.construct_calls = state.construct_calls + 1
		state.native_callback = callback
		local native = {}
		function native:start()
			if start_mode == "throw" then error("synthetic start failure") end
			if start_mode == "false" then return false end
			if start_mode == "nil" then return nil end
			return self
		end
		function native:stop()
			state.stop_calls = state.stop_calls + 1
			return self
		end
		state.native = native
		return native
	end
	return timer_stub, state
end

--- Builds an HTTP double that records dispatch without completing it.
--- @return table http_stub Native HTTP API double.
--- @return table state Observable request state.
local function make_http_stub()
	local state = { post_calls = 0, get_calls = 0, callbacks = {} }
	local http_stub = {}
	function http_stub.asyncPost(_url, _body, _headers, callback)
		state.post_calls = state.post_calls + 1
		state.callbacks[#state.callbacks + 1] = callback
		return nil
	end
	function http_stub.asyncGet(_url, _headers, callback)
		state.get_calls = state.get_calls + 1
		state.callbacks[#state.callbacks + 1] = callback
		return nil
	end
	return http_stub, state
end





-- =====================================================
-- =====================================================
-- ======= 2/ Acquisition Must Precede Dispatch ========
-- =====================================================
-- =====================================================

helpers.describe("HttpClient timeout ownership transaction", function()
	helpers.it("refuses dispatch for every native timer constructor and start failure", function()
		local cases = {
			{ name = "constructor nil", construct = "nil" },
			{ name = "constructor false", construct = "false" },
			{ name = "constructor throw", construct = "throw" },
			{ name = "start nil", start = "nil" },
			{ name = "start false", start = "false" },
			{ name = "start throw", start = "throw" },
		}

		for _, case in ipairs(cases) do
			local timer_stub, timer_state = make_single_timer(case.start or "success")
			if case.construct then
				timer_stub.new = function()
					timer_state.construct_calls = timer_state.construct_calls + 1
					if case.construct == "throw" then error("synthetic constructor failure") end
					if case.construct == "false" then return false end
					return nil
				end
			end
			local http_stub, http_state = make_http_stub()
			local client, scheduler = load_client(timer_stub, http_stub)
			local results = {}
			local ok, callback_count_or_err = pcall(function()
				client.post("http://localhost/failure", {}, "{}", function(result)
					results[#results + 1] = result
				end)
				return #results
			end)

			helpers.assert_true(ok,
				case.name .. " must be reported through the callback, not escape: "
					.. tostring(callback_count_or_err))
			helpers.assert_eq(callback_count_or_err, 1,
				case.name .. " must synchronously deliver one terminal callback")
			helpers.assert_eq(timer_state.construct_calls, 1,
				case.name .. " must attempt one exact timer candidate")
			helpers.assert_eq(http_state.post_calls, 0,
				case.name .. " must not dispatch an unbounded HTTP request")
			helpers.assert_eq(#results, 1,
				case.name .. " must produce one loud terminal result")
			helpers.assert_eq(results[1].ok, false)
			helpers.assert_eq(results[1].error, "timeout unavailable")
			helpers.assert_eq(client.isActive(), false,
				case.name .. " must not publish an active request")
			helpers.assert_eq(scheduler.activeCount(), 0,
				case.name .. " must leave no hidden timer when rollback succeeds")
		end
	end)

	helpers.it("applies the same pre-dispatch timeout gate to GET", function()
		local timer_stub = {
			doAfter = function() error("raw timeout bypass") end,
			new = function() return nil end,
			secondsSinceEpoch = function() return 0 end,
		}
		local http_stub, http_state = make_http_stub()
		local client = load_client(timer_stub, http_stub)
		local results = {}
		client.get("http://localhost/get", {}, function(result)
			results[#results + 1] = result
		end)

		helpers.assert_eq(http_state.get_calls, 0,
			"GET must not bypass the shared timeout acquisition transaction")
		helpers.assert_eq(#results, 1)
		helpers.assert_eq(results[1].error, "timeout unavailable")
		helpers.assert_eq(client.isActive(), false)
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 3/ Cleanup Debt Blocks Siblings =============
-- =====================================================
-- =====================================================

helpers.describe("HttpClient timeout cleanup debt", function()
	helpers.it("retries one failed acquisition candidate before creating a successor", function()
		local timer_state = {
			construct_calls = 0,
			stop_calls = 0,
			callbacks = {},
		}
		local timer_stub = {
			doAfter = function() error("raw timeout bypass") end,
			secondsSinceEpoch = function() return 0 end,
		}
		function timer_stub.new(_, callback)
			timer_state.construct_calls = timer_state.construct_calls + 1
			timer_state.callbacks[#timer_state.callbacks + 1] = callback
			local candidate_index = timer_state.construct_calls
			local native = {}
			function native:start()
				if candidate_index == 1 then error("activated then raised") end
				return self
			end
			function native:stop()
				timer_state.stop_calls = timer_state.stop_calls + 1
				if timer_state.stop_calls <= 2 then return false end
				return self
			end
			return native
		end
		local http_stub, http_state = make_http_stub()
		local client, scheduler = load_client(timer_stub, http_stub)
		local errors = {}

		client.post("http://localhost/first", {}, "{}", function(result)
			errors[#errors + 1] = result.error
		end)
		helpers.assert_eq(timer_state.construct_calls, 1)
		helpers.assert_eq(timer_state.stop_calls, 1,
			"failed start must attempt immediate rollback of its exact candidate")
		helpers.assert_eq(http_state.post_calls, 0)
		helpers.assert_eq(scheduler.activeCount(), 1,
			"a refused rollback must remain scheduler-owned and caller-owned")

		client.post("http://localhost/blocked", {}, "{}", function(result)
			errors[#errors + 1] = result.error
		end)
		helpers.assert_eq(timer_state.stop_calls, 2,
			"the next entry must retry the exact outstanding capability")
		helpers.assert_eq(timer_state.construct_calls, 1,
			"cleanup refusal must block creation of a sibling timer")
		helpers.assert_eq(http_state.post_calls, 0,
			"cleanup refusal must also block the sibling network request")
		helpers.assert_eq(errors[2], "timeout cleanup pending")

		client.post("http://localhost/recovered", {}, "{}", function(result)
			errors[#errors + 1] = result.error
		end)
		helpers.assert_eq(timer_state.stop_calls, 3,
			"recovery must settle the first exact candidate before replacement")
		helpers.assert_eq(timer_state.construct_calls, 2,
			"one successor may be created only after cleanup commits")
		helpers.assert_eq(http_state.post_calls, 1)
		helpers.assert_eq(client.isActive(), true,
			"activity must not depend on hs.http returning a task handle")
	end)

	helpers.it("retains a due timer whose terminal stop refuses and never fires twice", function()
		local timer_state = {
			construct_calls = 0,
			stop_calls = 0,
			callbacks = {},
		}
		local timer_stub = {
			doAfter = function() error("raw timeout bypass") end,
			secondsSinceEpoch = function() return 0 end,
		}
		function timer_stub.new(_, callback)
			timer_state.construct_calls = timer_state.construct_calls + 1
			timer_state.callbacks[#timer_state.callbacks + 1] = callback
			local native = {}
			function native:start() return self end
			function native:stop()
				timer_state.stop_calls = timer_state.stop_calls + 1
				if timer_state.stop_calls <= 3 then return false end
				return self
			end
			return native
		end

		local task = { cancel_calls = 0 }
		function task:cancel()
			self.cancel_calls = self.cancel_calls + 1
			return true
		end
		local http_state = { post_calls = 0 }
		local http_stub = {
			asyncPost = function()
				http_state.post_calls = http_state.post_calls + 1
				return task
			end,
		}
		local client, scheduler = load_client(timer_stub, http_stub)
		local results = {}
		client.post("http://localhost/slow", {}, "{}", function(result)
			results[#results + 1] = result
		end)

		timer_state.callbacks[1]()
		helpers.assert_eq(#results, 1)
		helpers.assert_eq(results[1].error, "timeout")
		helpers.assert_eq(task.cancel_calls, 1)
		helpers.assert_eq(client.isActive(), false)
		helpers.assert_eq(timer_state.stop_calls, 1,
			"the due scheduler wrapper must make one terminal stop attempt")
		helpers.assert_eq(scheduler.activeCount(), 1,
			"the exact due timer must remain owned after native stop refusal")

		timer_state.callbacks[1]()
		helpers.assert_eq(#results, 1,
			"a repeating native primitive must not deliver the timeout twice")
		helpers.assert_eq(timer_state.stop_calls, 2,
			"a repeated native delivery may retry only the same cleanup capability")

		client.post("http://localhost/blocked", {}, "{}", function(result)
			results[#results + 1] = result
		end)
		helpers.assert_eq(timer_state.stop_calls, 3,
			"the blocked sibling must make exactly one cleanup retry")
		helpers.assert_eq(timer_state.construct_calls, 1,
			"terminal cleanup debt must block every sibling timer")
		helpers.assert_eq(http_state.post_calls, 1,
			"terminal cleanup debt must block every sibling HTTP dispatch")
		helpers.assert_eq(results[2].error, "timeout cleanup pending")

		client.post("http://localhost/recovered", {}, "{}", function(result)
			results[#results + 1] = result
		end)
		helpers.assert_eq(timer_state.construct_calls, 2)
		helpers.assert_eq(http_state.post_calls, 2)
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 4/ Response Cleanup Is Fenced ===============
-- =====================================================
-- =====================================================

helpers.describe("HttpClient response timeout fencing", function()
	helpers.it("delivers one response while retaining a timer whose cancellation refuses", function()
		local timer_state = { stop_calls = 0, callbacks = {} }
		local timer_stub = {
			doAfter = function() error("raw timeout bypass") end,
			secondsSinceEpoch = function() return 0 end,
		}
		function timer_stub.new(_, callback)
			timer_state.callbacks[#timer_state.callbacks + 1] = callback
			local native = {}
			function native:start() return self end
			function native:stop()
				timer_state.stop_calls = timer_state.stop_calls + 1
				if timer_state.stop_calls == 1 then return false end
				return self
			end
			return native
		end
		local http_stub, http_state = make_http_stub()
		local client, scheduler = load_client(timer_stub, http_stub)
		local results = {}
		client.post("http://localhost/fast", {}, "{}", function(result)
			results[#results + 1] = result
		end)
		http_state.callbacks[1](200, "ok", {})

		helpers.assert_eq(#results, 1)
		helpers.assert_eq(results[1].status, 200)
		helpers.assert_eq(client.isActive(), false)
		helpers.assert_eq(scheduler.activeCount(), 1,
			"response completion must retain uncertain timeout cleanup")
		timer_state.callbacks[1]()
		helpers.assert_eq(#results, 1,
			"a timer queued before cancellation must be generation- and identity-fenced")
	end)

	helpers.it("does not deliver a dispatch error after synchronous completion already won", function()
		local timer_stub = make_single_timer("success")
		local http_stub = {
			asyncPost = function(_url, _body, _headers, callback)
				callback(200, "ok", {})
				error("synthetic throw after completion")
			end,
		}
		local client, scheduler = load_client(timer_stub, http_stub)
		local results = {}
		client.post("http://localhost/reentrant", {}, "{}", function(result)
			results[#results + 1] = result
		end)

		helpers.assert_eq(#results, 1,
			"one synchronous completion must remain the only terminal result")
		helpers.assert_eq(results[1].status, 200)
		helpers.assert_eq(client.isActive(), false)
		helpers.assert_eq(scheduler.activeCount(), 0)
	end)
end)
