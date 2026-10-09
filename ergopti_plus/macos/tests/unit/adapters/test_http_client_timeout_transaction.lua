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
--- @param options table|nil Optional constructor configuration.
--- @return table client A fresh HttpClient instance.
--- @return table scheduler The freshly loaded TimerScheduler adapter.
local function load_client(timer_stub, http_stub, options)
	package.loaded["adapters.http_client"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	local HttpClient = helpers.load_with_stubs("adapters.http_client", {
		timer = timer_stub,
		http = http_stub,
	})
	return HttpClient.new(options), package.loaded["adapters.timer_scheduler"]
end

--- Builds a native timer whose start behavior is selected by the test.
--- @param start_mode string One of success, nil, false, or throw.
--- @return table timer_stub Native timer API double.
--- @return table state Observable constructor and stop state.
local function make_single_timer(start_mode)
	local state = {
		construct_calls = 0,
		delays = {},
		stop_calls = 0,
		native_callback = nil,
	}
	local timer_stub = {
		doAfter = function()
			error("HttpClient must not bypass TimerScheduler with a raw timeout")
		end,
		secondsSinceEpoch = function() return 0 end,
	}
	function timer_stub.new(delay, callback)
		state.construct_calls = state.construct_calls + 1
		state.delays[#state.delays + 1] = delay
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

--- Builds a faithful native timer whose stop refusal leaves it running.
--- @param initial_stop_mode string One of success, false, nil, or throw.
--- @return table timer_stub Native timer API double.
--- @return table state Observable timer identities and lifecycle calls.
local function make_exact_stop_timer(initial_stop_mode)
	local state = {
		construct_calls = 0,
		stop_calls = 0,
		callbacks = {},
		natives = {},
		stop_handles = {},
		stop_mode = initial_stop_mode,
	}
	local timer_stub = {
		doAfter = function()
			error("HttpClient must not bypass TimerScheduler with a raw timeout")
		end,
		secondsSinceEpoch = function() return 0 end,
	}
	function timer_stub.new(_, callback)
		state.construct_calls = state.construct_calls + 1
		state.callbacks[#state.callbacks + 1] = callback
		local running = false
		local native = {}
		function native:start()
			running = true
			return self
		end
		function native:running()
			return running
		end
		function native:stop()
			state.stop_calls = state.stop_calls + 1
			state.stop_handles[#state.stop_handles + 1] = self
			if state.stop_mode == "throw" then error("synthetic stop failure") end
			if state.stop_mode == "false" then return false end
			if state.stop_mode == "nil" then return nil end
			running = false
			return self
		end
		state.natives[#state.natives + 1] = native
		return native
	end
	return timer_stub, state
end

--- Builds an HTTP double whose first task exposes exact cancellation outcomes.
--- @param initial_cancel_mode string One of success, false, nil, or throw.
--- @return table http_stub Native HTTP API double.
--- @return table state Observable dispatch, callback, and task identity state.
local function make_exact_task_http(initial_cancel_mode)
	local state = {
		post_calls = 0,
		callbacks = {},
		cancel_handles = {},
		cancel_mode = initial_cancel_mode,
	}
	local first_task = {}
	function first_task:cancel()
		state.cancel_handles[#state.cancel_handles + 1] = self
		if state.cancel_mode == "throw" then error("synthetic task cancel failure") end
		if state.cancel_mode == "false" then return false end
		if state.cancel_mode == "nil" then return nil end
		return true
	end
	state.first_task = first_task

	local http_stub = {}
	function http_stub.asyncPost(_url, _body, _headers, callback)
		state.post_calls = state.post_calls + 1
		state.callbacks[#state.callbacks + 1] = callback
		if state.post_calls == 1 then return first_task end
		return { cancel = function() return true end }
	end
	return http_stub, state
end





-- =====================================================
-- =====================================================
-- ======= 2/ Acquisition Must Precede Dispatch ========
-- =====================================================
-- =====================================================

helpers.describe("HttpClient timeout ownership transaction", function()
	helpers.it("rejects invalid per-instance timeout configuration", function()
		local timer_stub = make_single_timer("success")
		local http_stub = make_http_stub()
		package.loaded["adapters.http_client"] = nil
		package.loaded["adapters.timer_scheduler"] = nil
		local HttpClient = helpers.load_with_stubs("adapters.http_client", {
			timer = timer_stub,
			http = http_stub,
		})
		for _, case in ipairs({
			{ options = "invalid options", detail = "options must be a table" },
			{ options = { timeout_ms = 0 }, detail = "timeout_ms must be a finite positive number" },
			{ options = { timeout_ms = -1 }, detail = "timeout_ms must be a finite positive number" },
			{ options = { timeout_ms = "60000" }, detail = "timeout_ms must be a finite positive number" },
			{ options = { timeout_ms = math.huge }, detail = "timeout_ms must be a finite positive number" },
			{ options = { timeout_ms = 0 / 0 }, detail = "timeout_ms must be a finite positive number" },
		}) do
			local _, err = pcall(HttpClient.new, case.options)
			helpers.assert_contains(tostring(err), case.detail,
				"invalid timeout configuration must fail with its contract diagnostic")
		end
	end)

	helpers.it("uses the default timeout unless the instance supplies an override", function()
		for _, case in ipairs({
			{ label = "default", expected_seconds = 30 },
			{ label = "override", options = { timeout_ms = 60000 }, expected_seconds = 60 },
		}) do
			local timer_stub, timer_state = make_single_timer("success")
			local http_stub = make_http_stub()
			local client = load_client(timer_stub, http_stub, case.options)
			client.get("http://localhost/" .. case.label, {}, function() end)

			helpers.assert_eq(timer_state.delays[1], case.expected_seconds,
				case.label .. " client must arm its effective per-instance timeout")
		end
	end)

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





-- ======================================================
-- ======================================================
-- ======= 5/ Exact Cancellation Debt ===================
-- ======================================================
-- ======================================================

helpers.describe("HttpClient exact cancellation debt", function()
	helpers.it("notifies settlement when an ordinary timeout owns no native task", function()
		local timer_stub, timer_state = make_exact_stop_timer("success")
		local http_stub = make_http_stub()
		local client = load_client(timer_stub, http_stub)
		local observer_calls = 0
		local results = {}

		helpers.assert_true(client.post("http://localhost/ordinary-timeout", {}, "{}",
			function(result) results[#results + 1] = result end))
		helpers.assert_true(client.onSettled(function()
			observer_calls = observer_calls + 1
		end))
		timer_state.callbacks[1]()
		helpers.assert_eq(#results, 1)
		helpers.assert_eq(results[1].error, "timeout")
		helpers.assert_eq(observer_calls, 1,
			"normal timeout completion must wake composite lifecycle owners")
		timer_state.callbacks[1]()
		helpers.assert_eq(observer_calls, 1,
			"duplicate native timeout delivery may not repeat settlement")
	end)

	helpers.it("accepts a synchronous task terminal over false nil or throwing cancel results", function()
		for _, cancel_mode in ipairs({ "false", "nil", "throw" }) do
			local timer_stub = make_exact_stop_timer("success")
			local http_callback = nil
			local cancel_calls = 0
			local task = {}
			function task:cancel()
				cancel_calls = cancel_calls + 1
				http_callback(200, "terminal-during-cancel", {})
				if cancel_mode == "false" then return false end
				if cancel_mode == "nil" then return nil end
				error("synthetic cancel throw after terminal")
			end
			local client = load_client(timer_stub, {
				asyncPost = function(_, _, _, callback)
					http_callback = callback
					return task
				end,
			})
			local results = {}

			helpers.assert_true(client.post("http://localhost/reentrant-cancel", {}, "{}",
				function(result) results[#results + 1] = result end), cancel_mode)
			helpers.assert_true(client.cancel(),
				cancel_mode .. " must accept the exact synchronous terminal as settlement proof")
			helpers.assert_eq(cancel_calls, 1)
			helpers.assert_eq(#results, 0,
				"cancel-time terminal delivery must remain logically revoked")
			helpers.assert_eq(client.isActive(), false)
		end
	end)

	helpers.it("retains and retries the same timer after false, nil, and throwing stops", function()
		local cases = { "false", "nil", "throw" }

		for _, stop_mode in ipairs(cases) do
			local timer_stub, timer_state = make_exact_stop_timer(stop_mode)
			local http_stub, http_state = make_http_stub()
			local client, scheduler = load_client(timer_stub, http_stub)
			local results = {}

			helpers.assert_eq(client.post("http://localhost/timer-debt", {}, "{}", function(result)
				results[#results + 1] = result
			end), true, stop_mode .. " setup request must dispatch")
			helpers.assert_eq(client.cancel(), false,
				stop_mode .. " must expose unsettled timeout cleanup")
			helpers.assert_eq(timer_state.stop_calls, 2,
				stop_mode .. " must retry the retained timer once before cancel returns")
			helpers.assert_eq(timer_state.stop_handles[1], timer_state.natives[1],
				stop_mode .. " first stop must target the published timer")
			helpers.assert_eq(timer_state.stop_handles[2], timer_state.natives[1],
				stop_mode .. " retry must target the exact same timer")
			helpers.assert_eq(scheduler.activeCount(), 1,
				stop_mode .. " refusal must remain exact scheduler cleanup debt")
			helpers.assert_eq(client.isActive(), false,
				stop_mode .. " cancellation must fence logical activity first")

			http_state.callbacks[1](200, "late", {})
			timer_state.callbacks[1]()
			helpers.assert_eq(#results, 0,
				stop_mode .. " late native callbacks must stay inert while cleanup is pending")

			timer_state.stop_mode = "success"
			helpers.assert_eq(client.cancel(), true,
				stop_mode .. " retained timeout debt must be retryable to settlement")
			helpers.assert_eq(timer_state.stop_calls, 4,
				stop_mode .. " settlement must make one further exact stop attempt")
			helpers.assert_eq(timer_state.stop_handles[4], timer_state.natives[1],
				stop_mode .. " settlement must not substitute a sibling timer")
			helpers.assert_eq(scheduler.activeCount(), 0,
				stop_mode .. " settlement must consume the retained timer debt")

			helpers.assert_eq(client.post("http://localhost/timer-recovered", {}, "{}", function(result)
				results[#results + 1] = result
			end), true, stop_mode .. " settlement must unblock a successor")
			helpers.assert_eq(timer_state.construct_calls, 2,
				stop_mode .. " successor may allocate only after exact settlement")
			helpers.assert_eq(http_state.post_calls, 2,
				stop_mode .. " successor must dispatch exactly once after recovery")
			http_state.callbacks[2](200, "current", {})
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1].body, "current")
		end
	end)

	helpers.it("notifies autonomous timeout settlement without a lifecycle retry", function()
		for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
			local timer_stub, timer_state = make_exact_stop_timer(stop_mode)
			local http_stub, http_state = make_http_stub()
			local client = load_client(timer_stub, http_stub)
			local observer_calls = 0
			local results = {}

			helpers.assert_eq(client.post("http://localhost/timeout-observer", {}, "{}",
				function(result) results[#results + 1] = result end), true, stop_mode)
			helpers.assert_eq(client.onSettled(function()
				observer_calls = observer_calls + 1
			end), true, stop_mode)
			helpers.assert_eq(client.cancel(), false, stop_mode)
			helpers.assert_eq(observer_calls, 0,
				stop_mode .. " must retain the observer with the exact timer debt")
			timer_state.stop_mode = "success"
			timer_state.callbacks[1]()
			helpers.assert_eq(observer_calls, 1,
				stop_mode .. " native delivery must publish exact settlement once")
			helpers.assert_eq(#results, 0,
				stop_mode .. " cleanup delivery must not invoke the request callback")
			timer_state.callbacks[1]()
			helpers.assert_eq(observer_calls, 1,
				stop_mode .. " duplicate cleanup delivery must stay inert")
			helpers.assert_eq(client.post("http://localhost/timeout-successor", {}, "{}",
				function(result) results[#results + 1] = result end), true, stop_mode)
			helpers.assert_eq(http_state.post_calls, 2,
				stop_mode .. " exactly one successor may dispatch after settlement")
		end
	end)

	helpers.it("notifies autonomous task settlement from the same late callback", function()
		for _, cancel_mode in ipairs({ "false", "nil", "throw" }) do
			local timer_stub = make_exact_stop_timer("success")
			local http_stub, http_state = make_exact_task_http(cancel_mode)
			local client = load_client(timer_stub, http_stub)
			local observer_calls = 0
			local first_results = {}

			helpers.assert_eq(client.post("http://localhost/task-observer", {}, "{}",
				function(result) first_results[#first_results + 1] = result end), true, cancel_mode)
			helpers.assert_eq(client.onSettled(function()
				observer_calls = observer_calls + 1
			end), true, cancel_mode)
			helpers.assert_eq(client.cancel(), false, cancel_mode)
			helpers.assert_eq(observer_calls, 0,
				cancel_mode .. " must retain the observer with the exact task")
			http_state.callbacks[1](200, "late", {})
			helpers.assert_eq(#first_results, 0,
				cancel_mode .. " logically revoked task completion must stay inert")
			helpers.assert_eq(observer_calls, 1,
				cancel_mode .. " the same native callback must prove settlement once")
			http_state.callbacks[1](200, "duplicate", {})
			helpers.assert_eq(observer_calls, 1,
				cancel_mode .. " duplicate native completion must stay inert")
			helpers.assert_eq(client.post("http://localhost/task-successor", {}, "{}",
				function() end), true, cancel_mode)
			helpers.assert_eq(http_state.post_calls, 2,
				cancel_mode .. " exactly one successor may dispatch after settlement")
		end
	end)

	helpers.it("retains one task and blocks successors after false, nil, and throwing cancels", function()
		local cases = { "false", "nil", "throw" }

		for _, cancel_mode in ipairs(cases) do
			local timer_stub, timer_state = make_exact_stop_timer("success")
			local http_stub, http_state = make_exact_task_http(cancel_mode)
			local client = load_client(timer_stub, http_stub)
			local first_results = {}
			local blocked_results = {}
			local recovered_results = {}

			helpers.assert_eq(client.post("http://localhost/task-debt", {}, "{}", function(result)
				first_results[#first_results + 1] = result
			end), true, cancel_mode .. " setup request must dispatch")
			helpers.assert_eq(client.cancel(), false,
				cancel_mode .. " task refusal must make cancellation unsettled")
			helpers.assert_eq(#http_state.cancel_handles, 1)
			helpers.assert_eq(http_state.cancel_handles[1], http_state.first_task,
				cancel_mode .. " cancellation must target the first exact task")

			helpers.assert_eq(client.post("http://localhost/task-blocked", {}, "{}", function(result)
				blocked_results[#blocked_results + 1] = result
			end), false, cancel_mode .. " unsettled task must refuse a successor")
			helpers.assert_eq(http_state.post_calls, 1,
				cancel_mode .. " refusal must perform zero new HTTP dispatches")
			helpers.assert_eq(timer_state.construct_calls, 1,
				cancel_mode .. " refusal must perform zero new timeout acquisitions")
			helpers.assert_eq(#blocked_results, 1,
				cancel_mode .. " refused successor must receive one terminal result")
			helpers.assert_eq(blocked_results[1].error, "timeout cleanup pending")
			helpers.assert_eq(#http_state.cancel_handles, 2,
				cancel_mode .. " successor preparation must retry cancellation once")
			helpers.assert_eq(http_state.cancel_handles[2], http_state.first_task,
				cancel_mode .. " successor preparation must retain the exact task")

			http_state.cancel_mode = "success"
			helpers.assert_eq(client.cancel(), true,
				cancel_mode .. " exact task debt must be retryable to settlement")
			helpers.assert_eq(#http_state.cancel_handles, 3)
			helpers.assert_eq(http_state.cancel_handles[3], http_state.first_task,
				cancel_mode .. " settlement must not substitute a task handle")
			http_state.callbacks[1](200, "late-after-retry", {})
			helpers.assert_eq(#first_results, 0,
				cancel_mode .. " stale callback must remain inert after native settlement")

			helpers.assert_eq(client.post("http://localhost/task-recovered", {}, "{}", function(result)
				recovered_results[#recovered_results + 1] = result
			end), true, cancel_mode .. " settlement must unblock a successor")
			helpers.assert_eq(http_state.post_calls, 2,
				cancel_mode .. " only the recovered successor may add one dispatch")
			helpers.assert_eq(timer_state.construct_calls, 2,
				cancel_mode .. " only the recovered successor may add one timeout")
			http_state.callbacks[2](200, "current", {})
			helpers.assert_eq(#recovered_results, 1)
			helpers.assert_eq(recovered_results[1].body, "current")
		end
	end)
end)
